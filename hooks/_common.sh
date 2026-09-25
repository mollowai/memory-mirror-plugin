#!/usr/bin/env bash
# Shared helpers for Memory Mirror hooks.
#
# Fail-safe contract: every hook sources this and MUST `exit 0` even on error so
# it can never block or break a Claude Code session. All network calls are time-
# boxed and swallow errors.
#
# Transport: the hooks call the webapp's single-request REST surface
# (/api/memory/*) with a `mol_*` key — NOT the MCP JSON-RPC endpoint, which would
# need an initialize→tools/call handshake per call (too slow for the per-prompt
# recall hook).
#
# Config (injected into the session env by the monorepo's session launchers):
#   MOLLOW_MEMORY_API_KEY  required — staging mol_* key. Absent => hooks no-op.
#   MOLLOW_MEMORY_URL      the MCP url (…/mcp/v2). The API base is derived by
#                          stripping the /mcp/v2 suffix. Public default = prod;
#                          the monorepo overrides it to staging.

set -uo pipefail

mm_api_base() {
  local url="${MOLLOW_MEMORY_URL:-https://mollow.ai/mcp/v2}"
  # Strip an optional trailing slash first so "…/mcp/v2/" still maps to the API
  # base. Otherwise the /mcp/v2 strip silently fails and every path double-prefixes.
  url="${url%/}"
  printf '%s' "${url%/mcp/v2}"
}

# Environment label for the CURRENT target (dev|staging|prod|custom), derived
# from the API base. Mirrors memory_sync.py `infer_env_from_url` and the
# fleet-target env→base map. Sync state must be keyed by this: a `synced`
# fingerprint recorded against one env would otherwise suppress the push to a
# different env after a fleet-target switch (the silent-drop bug — memories
# synced to staging never reached prod because the project looked "done").
mm_env_label() {
  local base
  base="$(mm_api_base)"
  case "$base" in
    https://mollow.ai) echo prod ;;
    https://staging.mollow.ai) echo staging ;;
    http://localhost:4000 | http://127.0.0.1:4000) echo dev ;;
    # A non-standard base (preview / self-hosted) gets a label derived from the
    # base itself, not a flat "custom" — otherwise two different custom targets
    # would share one `${label}:${slug}` sync-state key, and a switch between
    # them would suppress the required re-import (the very drop this keying
    # prevents for the standard envs). Short hash keeps the key readable.
    *)
      local h
      if command -v shasum >/dev/null 2>&1; then
        h="$(printf '%s' "$base" | shasum | awk '{print $1}')"
      elif command -v sha256sum >/dev/null 2>&1; then
        h="$(printf '%s' "$base" | sha256sum | awk '{print $1}')"
      else
        h="$(printf '%s' "$base" | cksum | awk '{print $1}')"
      fi
      printf 'custom-%s' "${h:0:8}"
      ;;
  esac
}

# Preconditions: a key, jq, and curl must be present, and MOLLOW_MEMORY_URL must
# end in /mcp/v2 — else the hook no-ops. The suffix check is a security guard: a
# misconfigured URL would otherwise send the mol_* key to `<full_url>/api/memory/*`
# on whatever host the URL resolves to.
mm_ready() {
  [ -n "${MOLLOW_MEMORY_API_KEY:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local url="${MOLLOW_MEMORY_URL:-https://mollow.ai/mcp/v2}"
  url="${url%/}"
  if [[ "$url" != */mcp/v2 ]]; then
    echo "memory-mirror: MOLLOW_MEMORY_URL ('${url}') is missing the /mcp/v2 suffix — refusing to send credentials" >&2
    return 1
  fi

  # Never send the bearer key over plaintext to a remote host. Allow http only
  # for local development — match the host boundary exactly (optional port) so a
  # prefix like http://localhost.evil.com can't slip through.
  if [[ "$url" == https://* ]]; then
    :
  elif [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/mcp/v2$ ]]; then
    :
  else
    echo "memory-mirror: MOLLOW_MEMORY_URL ('${url}') is not HTTPS — refusing to send credentials" >&2
    return 1
  fi
}

# Supply mode (MOL-5857) opt-in. Both supply hooks load into EVERY Claude Code
# session on this machine, so a call on every prompt in every session is the
# blast radius. The guard is therefore local and explicit: it must gate the call
# BEFORE the 2s budget is spent, independent of the server-side `supply_mode`
# flag (which 404s the endpoint but only after the request has already been
# made). Absent/anything-but-a-true-token => off. Kept here, not in each hook, so
# the two hooks cannot drift on what "on" means.
mm_supply_enabled() {
  local v
  v="$(printf '%s' "${MOLLOW_SUPPLY_MODE:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# True when pointer mode is opted in for this machine. A SECOND opt-in on top of
# mm_supply_enabled, mirroring the server's own split: `supply_mode` gates whether
# the endpoint answers at all, `pointer_mode` gates whether "pointer" is even in
# the mode vocabulary. Off here means the hooks keep asking for `facts` exactly as
# before, so turning pointer mode on server-side changes nothing on this machine
# until this is set too.
#
# Both guards are read before stdin and before any curl, for the same reason
# mm_supply_enabled is: the 2s budget is spent whether or not the server answers.
mm_supply_pointer_enabled() {
  local v
  v="$(printf '%s' "${MOLLOW_SUPPLY_POINTER_MODE:-}" | tr '[:upper:]' '[:lower:]')"
  case "$v" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# True when $1 is safe to use as a single filesystem path component: non-empty,
# only [A-Za-z0-9._-], and neither `.`/`..` nor containing a `..` sequence. The
# supply hooks build receipt paths from `session_id` and `grounding_id`; a bare
# charset check still admits `..`, which would resolve a receipt dir to its
# parent and (with a chmod) restrict the shared temp dir (Greptile, PR #6160).
mm_safe_component() {
  local v="${1:-}"
  [ -n "$v" ] || return 1
  case "$v" in
    . | ..) return 1 ;;
    *..*) return 1 ;;
    *[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

# POST JSON body ($2) to the supply seam path ($1) with timeout ($3, default 2s)
# and print the response body.
#
# NOT mm_post_read: the `/grounding/v1/*` endpoints authenticate the CALLER from
# `x-mollow-api-key` (the memory API's `Authorization: Bearer` header carries the
# PROVIDER credential on the relay routes and would be consumed by an auth plug),
# and resolve a workspace-scoped key from `x-mollow-workspace-id`. A space-scoped
# key names its own tenant and ignores the workspace header. Same base as the
# memory API — `mm_api_base` strips `/mcp/v2`, and `/grounding/v1/...` sits at the
# root — so this reuses the same MOLLOW_MEMORY_* config and the mm_ready guards.
# OUTPUT CONTRACT (changed by MOL-5978): the HTTP STATUS on the first line, then
# the response body. Use `mm_seam_split_status` / `mm_seam_split_body` to take
# them apart rather than re-deriving the parsing at each call site.
#
# Before this, the function could not fail visibly. `|| true`, stderr to
# /dev/null, no `-f` and no `%{http_code}` meant every HTTP error looked
# identical to "nothing to ground": the caller read an empty or unparseable body,
# exited 0, and the operator saw a turn that was not grounded. On the
# `curl` path an unset MOLLOW_SUPPLY_WORKSPACE_ID answers `400
# workspace_not_named`; on this path it answered nothing, every turn, forever —
# and `note-to-mariam-hash-pointer-2026-09-24.md` tells the reader an empty
# grounding means the wrong workspace, so the silence actively misdirects.
#
# The status rides the OUTPUT rather than a variable because every caller reads
# this through command substitution — `resp="$(mm_seam_post_read …)"` — which
# runs the function in a subshell. A global assigned inside would be discarded
# on return, so the status would have been silently absent at exactly the call
# site that needed it, while the source read correct.
#
# `000` is curl's own code for "no HTTP response happened" — timeout, DNS,
# connection refused. Callers must treat it differently from a real 4xx: one is
# transient, the other is configuration that will answer identically every turn.
#
# Fail-open is unchanged: this always returns 0 and never writes to stderr.
mm_seam_post_read() {
  local path="$1" body="$2" timeout="${3:-2}"
  local args=(-sS --max-time "$timeout" -X POST "$(mm_api_base)$path"
    -H "x-mollow-api-key: ${MOLLOW_MEMORY_API_KEY}"
    -H "Content-Type: application/json")
  [ -n "${MOLLOW_SUPPLY_WORKSPACE_ID:-}" ] &&
    args+=(-H "x-mollow-workspace-id: ${MOLLOW_SUPPLY_WORKSPACE_ID}")

  # `-w` appends the code on its own final line, so the body is everything
  # before it. No temp file, so there is nothing to clean up on a path that must
  # never abort.
  local raw
  raw="$(curl "${args[@]}" -w '\n%{http_code}' -d "$body" 2>/dev/null || true)"

  # Nothing at all: curl could not run. Not an HTTP outcome.
  if [ -z "$raw" ]; then
    printf '000\n'
    return 0
  fi

  local code="${raw##*$'\n'}" payload=""
  # No newline means an empty body — `${raw%$'\n'*}` would hand back the code as
  # the body.
  case "$raw" in
    *$'\n'*) payload="${raw%$'\n'*}" ;;
  esac
  printf '%s\n%s' "$code" "$payload"
}

# The status line from an `mm_seam_post_read` result.
mm_seam_split_status() { printf '%s' "${1%%$'\n'*}"; }

# The body from an `mm_seam_post_read` result, empty when there was none.
mm_seam_split_body() {
  case "${1:-}" in
    *$'\n'*) printf '%s' "${1#*$'\n'}" ;;
    *) printf '' ;;
  esac
}

# A one-line, operator-readable reason for a non-200 from the grounding
# endpoint, or empty when there is nothing worth saying (MOL-5978).
#
# Empty for `200` and for `000`. A `000` is a timeout or a network miss: it is
# transient, the hook is already time-boxed at 2s, and reporting it would put a
# line in front of the operator on every slow turn. A real HTTP code is
# different — it is the server answering, and it will answer the same way on
# every turn until something is changed.
# The `error.type` an error body names, or empty. `json_error/3` renders
# `{"error":{"type":"..."}}`, so a refusal says exactly which rule it broke —
# which is better evidence than the status for any code that covers more than
# one cause. Empty on a missing, malformed or typeless body, so a caller falls
# back to the status rather than asserting a cause it does not have.
mm_grounding_error_type() {
  [ -n "${1:-}" ] || return 0
  printf '%s' "$1" | jq -r '.error.type // empty' 2>/dev/null || true
}

# The codes are the ones `GroundController.refuse/2` can actually produce, plus
# 429 from the supply rate-limit pipeline. Deliberately NOT a generic
# authorization message: 400 and 403 are both about MOLLOW_SUPPLY_WORKSPACE_ID
# and 404 is about the flag, the key or the header, so a hint that says "check
# your credential" for all of them sends the operator to the wrong variable —
# which is the whole failure this function exists to end.
#
# There is no 401 clause because this endpoint never returns one: its scope pipes
# through `:api` ALONE, with no auth plug, and `GroundController` authenticates
# inside the action and answers 404 rather than 401 so an unauthenticated prober
# learns nothing. A 401 branch would be advice for a response that cannot arrive.
mm_grounding_status_hint() {
  case "${1:-}" in
    200 | 000 | "") printf '' ;;
    400)
      printf 'Mollow supply mode: the grounding request was refused (400 workspace_not_named). Your key is workspace-scoped and MOLLOW_SUPPLY_WORKSPACE_ID is unset, so the request named no workspace.'
      ;;
    403)
      printf 'Mollow supply mode: the grounding request was refused (403 workspace_not_yours). MOLLOW_SUPPLY_WORKSPACE_ID names a workspace this key does not own — check the workspace id, not the key.'
      ;;
    404)
      printf 'Mollow supply mode: the grounding endpoint answered 404. Either supply_mode is off for your actor, the key is not valid, or the credential is in the wrong header (it reads x-mollow-api-key, not Authorization).'
      ;;
    422)
      # 422 is the one status that covers several unrelated causes, so it reads
      # the body's own `error.type` rather than guessing. Guessing was wrong:
      # naming invalid_mode blamed pointer_mode for a blank query, and in FACTS
      # mode invalid_mode is not reachable at all, so the guess was wrong for
      # every 422 that path can produce (Greptile, #6251).
      case "$(mm_grounding_error_type "${2:-}")" in
        query_required)
          printf 'Mollow supply mode: the grounding request was rejected (422 query_required). The prompt was empty once trimmed, so there was nothing to ground. This is not a configuration problem.'
          ;;
        invalid_mode)
          printf 'Mollow supply mode: the grounding request was rejected (422 invalid_mode). pointer_mode is off for your actor, so "pointer" is not in the mode vocabulary. That is not a 404 and enabling supply_mode alone will not fix it.'
          ;;
        request_required)
          printf 'Mollow supply mode: the grounding request was rejected (422 request_required). prompt mode needs a model request body to ground.'
          ;;
        *)
          printf 'Mollow supply mode: the grounding request was rejected (422). Nothing was grounded this turn.'
          ;;
      esac
      ;;
    429)
      printf 'Mollow supply mode: rate limited (429). Nothing was grounded this turn.'
      ;;
    *)
      printf 'Mollow supply mode: the grounding request returned HTTP %s. Nothing was grounded this turn.' "$1"
      ;;
  esac
}

# POST JSON body ($2) to path ($1) with timeout ($3, default 3s). Fire-and-forget.
mm_post() {
  curl -sS --max-time "${3:-3}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null 2>&1 || true
}

# Like mm_post but returns curl's exit status (0 = delivered, non-zero on
# network error or HTTP >= 400 via --fail) so a caller can gate follow-up state
# (e.g. a sync fingerprint) on successful delivery. Still silent.
mm_post_ok() {
  curl -fsS --max-time "${3:-3}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null 2>&1
}

# GET path ($1) with timeout ($2, default 2s) and print the response body.
mm_get() {
  curl -sS --max-time "${2:-2}" \
    -X GET "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    2>/dev/null || true
}

# POST JSON body ($2) to path ($1) with timeout ($3, default 2s) and print the
# response body (for hooks that inject the result as context).
mm_post_read() {
  curl -sS --max-time "${3:-2}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    2>/dev/null || true
}

# Emit additionalContext for SessionStart / UserPromptSubmit. $1 = event name,
# $2 = context text. No-op when the text is empty.
mm_emit_context() {
  [ -z "${2:-}" ] && return 0
  jq -cn --arg ev "$1" --arg ctx "$2" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
}

# Merge a JSON array of strings into one key of a JSON object on disk, under a
# lock. $1 = file, $2 = key, $3 = JSON array. Returns non-zero without writing if
# another process holds the lock.
#
# The lock exists because the read-modify-write races. `recall-decisions.sh` fires
# on every UserPromptSubmit and this machine runs many sessions at once, so two
# hooks overlap in practice; each rewrites the file from its own snapshot and the
# later `mv` discards the earlier one's keys. A lost key means an already-shown
# contradiction is injected into context a second time.
#
# `mkdir` is the test-and-set, not `flock` — macOS ships no flock(1), and these
# hooks run on the developer's Mac.
#
# It RETRIES, briefly and boundedly. Taking the lock once and giving up looked
# defensible — a declined write is no worse than the unlocked behaviour — but it
# made an ordinary two-session overlap drop a key, which is the exact failure the
# lock was added to prevent. The retry is affordable because this runs AFTER the
# context has been emitted, so the injected advisory is already in hand and the
# only cost is hook teardown latency: ~$MM_SEEN_LOCK_ATTEMPTS × 20ms worst case.
#
# Past that budget it still gives up rather than blocking the turn. Under that
# much contention a dropped key re-shows one advisory once; the guarantee that
# holds unconditionally is that the file is never left corrupt.
mm_seen_add() {
  local file="$1" key="$2" additions="$3"
  local lock="${file}.lock" tmp="${file}.$$"
  local attempts="${MM_SEEN_LOCK_ATTEMPTS:-40}"
  local dir tries=0
  dir="$(dirname "$file")"
  mkdir -p "$dir" 2>/dev/null || return 1

  until mkdir "$lock" 2>/dev/null; do
    # A hook killed mid-write must not wedge seen-state forever, so a lock older
    # than a minute is treated as abandoned. No live holder can be that old: the
    # critical section is two jq calls and a rename.
    if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
      rmdir "$lock" 2>/dev/null || true
    else
      sleep 0.02
    fi

    tries=$((tries + 1))
    [ "$tries" -ge "$attempts" ] && return 1
  done

  # Second branch covers an absent or corrupt file: start the key fresh rather
  # than losing the write.
  if jq -c --arg k "$key" --argjson new "$additions" \
    '(. // {}) | .[$k] = (((.[$k] // []) + $new) | unique | .[-500:])' \
    "$file" 2>/dev/null >"$tmp" ||
    jq -nc --arg k "$key" --argjson new "$additions" '{($k): $new}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  else
    rm -f "$tmp" 2>/dev/null
  fi

  rmdir "$lock" 2>/dev/null || true
  return 0
}

# mm_repo_of <cwd>
#
# Echoes a stable identity for the repository containing <cwd>, or nothing when
# <cwd> is not in one. The identity is the same from a primary checkout, a
# linked worktree, and a separate clone — which is the whole point, because the
# label this replaces was `basename "$cwd"` and therefore recorded ONE
# repository under three different names depending on where the session sat.
#
# Preference order:
#
#   1. `remote.origin.url`, normalized to `host/owner/repo`. Stable by
#      definition: worktrees inherit it and clones carry it.
#   2. The MAIN repository's directory name, via `--git-common-dir`. From a
#      worktree that resolves to `<primary>/.git`, so the fallback names the
#      primary checkout rather than the worktree — using `--show-toplevel` here
#      would reintroduce the exact bug this replaces.
#
# Never errors: a missing git, a non-repo path and an empty argument all yield
# empty output, because every caller is a hook that must not break a session.
mm_repo_of() {
  local cwd="${1:-}"
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local url
  url="$(git -C "$cwd" config --get remote.origin.url 2>/dev/null || true)"

  # A local filesystem path is not a portable identity. Yolo agent clones point
  # origin at `/workspaces/monorepo`, and normalizing that as a URL yields
  # `workspaces/monorepo` — a fake identity that splits those clones off from the
  # repository they are copies of, which is the bug this function exists to fix.
  #
  # Follow it ONE hop to the real upstream when that path is reachable (it is
  # inside the container where such clones live). When it is not, fall back to
  # the path's basename: still stable, still the same for every clone sharing
  # that upstream, and the same shape as the no-remote fallback below.
  case "$url" in
    /* | ./* | ../* | ~*)
      local hop
      hop="$(git -C "$url" config --get remote.origin.url 2>/dev/null || true)"
      case "$hop" in
        # Unreachable, or the hop target is ITSELF a local path (a chain of local
        # clones). Either way there is no portable identity to be had, and
        # falling through to URL normalization would strip the leading slash and
        # emit `workspaces/repo` — the fake-identity shape this exists to remove.
        # Degrade to the basename of the deepest point actually resolved.
        "" | /* | ./* | ../* | ~*)
          basename "${hop:-$url}" | sed -E 's#\.git$##'
          return 0
          ;;
        *) url="$hop" ;;
      esac
      ;;
  esac

  if [ -n "$url" ]; then
    # scp-style `git@host:owner/repo`, `ssh://git@host/...`, and `https://...`
    # all reduce to `host/owner/repo`; a trailing `.git` is dropped.
    #
    # Order matters. The user@ prefix is removed WITHOUT substituting a slash —
    # an earlier version wrote `/` there, which then defeated the `^` anchor on
    # the colon rule and left scp-style URLs as `host:owner/repo`. A `:port` is
    # stripped before the scp colon rule so `ssh://git@host:22/o/r` does not
    # become `host/22/o/r`.
    printf '%s\n' "$url" \
      | sed -E 's#^[a-z+]+://##; s#^[^@/]+@##; s#:[0-9]+/#/#; s#:#/#; s#\.git$##; s#^/+##; s#/+$##'
    return 0
  fi

  local common
  common="$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$common" ] || return 0
  basename "$(dirname "$common")"
}

# mm_path_of <cwd>
#
# Echoes <cwd> relative to its repository root — empty at the root, `webapp` in
# a subdirectory — or nothing outside a repository. This is the finer-grained
# half of the scope: `repo` says which repository, `path` says which part of it.
mm_path_of() {
  local cwd="${1:-}"
  [ -n "$cwd" ] && [ -d "$cwd" ] || return 0
  command -v git >/dev/null 2>&1 || return 0
  git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

  local prefix
  prefix="$(git -C "$cwd" rev-parse --show-prefix 2>/dev/null || true)"
  printf '%s\n' "${prefix%/}"
}

# mm_project_of <cwd>
#
# The project label written onto memories and decisions. Now the repo identity
# rather than the directory name, so the same repository records under one value
# from every session shape.
#
# Outside a repository it degrades to the old basename: those directories have
# no better identity available, and returning nothing would silently drop the
# label entirely for non-repo work.
#
# The pre-normalization value is NOT discarded — callers send it as
# `source_project` so the change stays lossless and the memory-version supersede
# chain keeps a discriminator that did not collapse.
mm_project_of() {
  local cwd="${1:-}"
  [ -z "$cwd" ] && return 0

  local repo
  repo="$(mm_repo_of "$cwd")"
  if [ -n "$repo" ]; then
    printf '%s\n' "$repo"
  else
    basename "$cwd"
  fi
}

# mm_tdd_marker <cwd> <session_id>
#
# Echoes the path of the per-session TDD arming marker for the repository
# containing <cwd>, or nothing (return 1) when there is no repository or either
# path component is unsafe. arm-guardrails.sh writes it; guardrails-gate.sh
# tests for it. Both call this, so the two cannot disagree on the location.
#
# It lives under ~/.mollow, never in the repository: the plugin writes nothing
# into the customer's working tree (MOL-6090). The previous location,
# <repo>/tmp/.tdd-armed-<session>.json, created tmp/ in any repo without one and
# showed up in `git status` wherever tmp/ was not ignored.
#
# Keyed by mm_repo_of, so a primary checkout, its worktrees and its clones share
# one arming for a session; the repo identity's `/` become `_` so it is a single
# directory name.
mm_tdd_marker() {
  local cwd="${1:-}" sid="${2:-}" repo
  mm_safe_component "$sid" || return 1
  repo="$(mm_repo_of "$cwd" | sed 's#[^A-Za-z0-9._-]#_#g')"
  mm_safe_component "$repo" || return 1
  printf '%s\n' "${HOME}/.mollow/tdd-armed/${repo}/${sid}.json"
}
