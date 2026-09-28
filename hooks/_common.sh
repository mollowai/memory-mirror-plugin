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
# Config. Each value is read from the session environment FIRST and, when the
# environment does not carry it, resolved from a file (MOL-6221) — because a
# worktree pane loses these to direnv, and because the environment of an
# already-running session cannot be changed at all:
#
#   MOLLOW_MEMORY_API_KEY       required. Absent => hooks no-op, silently.
#                               Falls back to the session root's `.session-config`,
#                               then the `mollow-memory` Authorization header in
#                               that same directory's `.mcp.json`.
#   MOLLOW_MEMORY_URL           the MCP url (…/mcp/v2). The API base is derived
#                               by stripping the /mcp/v2 suffix. Same two
#                               fallbacks, in the same order.
#   MOLLOW_SUPPLY_MODE          supply-mode opt-in. Falls back to
#                               `~/.mollow/supply-mode` (one word, absent ⇒ off).
#   MOLLOW_SUPPLY_WORKSPACE_ID  which workspace a workspace-scoped key may read.
#                               Falls back to `~/.mollow/supply-workspace-id`,
#                               then `.session-config`. Without it a resolved key
#                               still earns `400 workspace_not_named`.
#   MOLLOW_MEMORY_CREDS_FROM_FILES=0  disables every file fallback above. Test
#                               suites that buy "no key ⇒ no network" by unsetting
#                               the key need this, or the purchase stops working.
#
# NOTE ON TARGET: this used to say the monorepo overrides the URL to staging. It
# does not. `.mcp.json` in a host session points at https://mollow.ai/mcp/v2, so
# `mm_env_label` resolves to **prod** and supply mode grounds against production.
# Measured 2026-09-28 and confirmed as intended — the corpus worth grounding
# against is prod's. Do not "restore" a staging default on the strength of the
# old comment.

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

# True when $1 is one of the tokens that mean "on". Leading/trailing whitespace
# is trimmed first, because these values now also arrive from a hand-written
# file where a stray space or a missing trailing newline is normal.
mm_truthy() {
  local v="${1:-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  case "$(printf '%s' "$v" | tr '[:upper:]' '[:lower:]')" in
    1 | true | yes | on) return 0 ;;
    *) return 1 ;;
  esac
}

# First line of $1, whitespace-trimmed. Absent, unreadable, or a DIRECTORY at
# that path all print nothing rather than failing — these run inside hooks that
# must never break a session.
#
# `read` returns non-zero on a final line with no trailing newline while still
# HAVING SET the variable, so the `|| true` is load-bearing: `|| line=""` would
# discard the very content read on that same call, and a one-word file with no
# trailing newline is the common case here.
mm_first_line_trimmed() {
  local f="${1:-}" line=""
  [ -n "$f" ] || return 0
  [ -f "$f" ] || return 0
  [ -r "$f" ] || return 0
  IFS= read -r line < "$f" 2>/dev/null || true
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

# Where the machine-wide supply-mode declaration lives. Mirrors
# ~/.mollow/gate-mode, ~/.mollow/forge-mode and ~/.mollow/speak-level — one word,
# absent ⇒ off.
mm_supply_mode_file() {
  printf '%s' "${MOLLOW_SUPPLY_MODE_FILE:-${HOME:-}/.mollow/supply-mode}"
}

# Whether credentials may be read from this session's own files. Default ON;
# only an explicit false token disables it.
#
# The switch exists because several suites buy "nothing in this test reaches the
# network" by unsetting MOLLOW_MEMORY_API_KEY (test-repo-identity.sh:26 says so
# by name). File resolution voids that guarantee silently, which is the worst
# possible way to lose it — so the guarantee stays purchasable.
mm_creds_from_files_enabled() {
  case "$(printf '%s' "${MOLLOW_MEMORY_CREDS_FROM_FILES:-1}" | tr '[:upper:]' '[:lower:]')" in
    0 | false | no | off) return 1 ;;
    *) return 0 ;;
  esac
}

# The directory whose .session-config / .mcp.json describe THIS session.
mm_session_root() {
  if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ -d "${CLAUDE_PROJECT_DIR}" ]; then
    printf '%s' "${CLAUDE_PROJECT_DIR}"
    return 0
  fi
  local top
  top="$(git rev-parse --show-toplevel 2>/dev/null)" || top=""
  printf '%s' "${top:-$PWD}"
}

# Fill MOLLOW_MEMORY_API_KEY / MOLLOW_MEMORY_URL from this session's own files
# when the environment does not carry them (MOL-6221).
#
# ## Why a file path exists at all
#
# `host-session-start.sh` writes both into `.session-config` because direnv
# reverts the monorepo's `.envrc` the moment a worktree pane's login zsh reaches
# a prompt. When that write does not happen — an adopted worktree, a session
# launched before persist_memory_env existed — `mm_ready` returns 1 with no
# message and both supply hooks are silently inert. Measured on the `shop-watch`
# session: its process environ held neither variable while `.mcp.json` carried
# the credential the whole time. Two rails reading one secret from two places,
# and only one of them got it.
#
# It is also the ONLY reachable switch for a session already running: the hooks
# are children of a process whose environ was fixed at launch, so no amount of
# exporting reaches them.
#
# ## Order, and why
#
# `.session-config` first: the launcher writes it for exactly this purpose and
# chmods it 0600. `.mcp.json` second and opportunistically — it is MCP transport
# config, not a credential store, and we are reading it because it happens to
# hold the same key.
#
# Never echo a resolved value. A hook that leaks a bearer token into a
# transcript is strictly worse than a hook that does nothing.
mm_resolve_memory_creds() {
  mm_creds_from_files_enabled || return 0
  # Nothing to do only when ALL THREE inputs are already set. Short-circuiting on
  # the key and url alone skips the workspace-id lookup below, and the request
  # then goes out with no `x-mollow-workspace-id` and earns `400
  # workspace_not_named` — the hook reaches the network and injects a refusal
  # instead of facts, which is this file's own documented failure arriving from
  # the other side. Found by Greptile on #6406; none of the workspace-id tests
  # reached this branch, because each of them unset the key and url.
  if [ -n "${MOLLOW_MEMORY_API_KEY:-}" ] && [ -n "${MOLLOW_MEMORY_URL:-}" ] &&
    [ -n "${MOLLOW_SUPPLY_WORKSPACE_ID:-}" ]; then
    return 0
  fi

  local root
  root="$(mm_session_root)"
  [ -n "$root" ] || return 0

  local cfg="$root/.session-config"
  if [ -f "$cfg" ] && [ -r "$cfg" ]; then
    local v
    if [ -z "${MOLLOW_MEMORY_API_KEY:-}" ]; then
      # tail -1: a later line wins, matching how sourcing the file would behave.
      v="$(sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}MOLLOW_MEMORY_API_KEY=//p' "$cfg" 2>/dev/null | tail -1)"
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      if [ -n "$v" ]; then MOLLOW_MEMORY_API_KEY="$v"; export MOLLOW_MEMORY_API_KEY; fi
    fi
    if [ -z "${MOLLOW_MEMORY_URL:-}" ]; then
      v="$(sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}MOLLOW_MEMORY_URL=//p' "$cfg" 2>/dev/null | tail -1)"
      v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
      if [ -n "$v" ]; then MOLLOW_MEMORY_URL="$v"; export MOLLOW_MEMORY_URL; fi
    fi
  fi

  # MOLLOW_SUPPLY_WORKSPACE_ID is the THIRD input with the same problem, and
  # without it a resolved key still gets `400 workspace_not_named` — the hook
  # runs, reaches the server, and injects a refusal instead of facts. Measured on
  # `shop-watch` immediately after the key started resolving. A one-value file
  # beside supply-mode, then .session-config.
  if [ -z "${MOLLOW_SUPPLY_WORKSPACE_ID:-}" ]; then
    local ws
    ws="$(mm_first_line_trimmed "${MOLLOW_SUPPLY_WORKSPACE_ID_FILE:-${HOME:-}/.mollow/supply-workspace-id}")"
    if [ -z "$ws" ] && [ -f "$cfg" ] && [ -r "$cfg" ]; then
      ws="$(sed -n 's/^[[:space:]]*export[[:space:]]\{1,\}MOLLOW_SUPPLY_WORKSPACE_ID=//p' "$cfg" 2>/dev/null | tail -1)"
      ws="${ws%\"}"; ws="${ws#\"}"; ws="${ws%\'}"; ws="${ws#\'}"
    fi
    if [ -n "$ws" ]; then MOLLOW_SUPPLY_WORKSPACE_ID="$ws"; export MOLLOW_SUPPLY_WORKSPACE_ID; fi
  fi

  local mcp="$root/.mcp.json"
  if [ -f "$mcp" ] && [ -r "$mcp" ] && command -v jq >/dev/null 2>&1; then
    local auth url
    if [ -z "${MOLLOW_MEMORY_API_KEY:-}" ]; then
      auth="$(jq -r '.mcpServers["mollow-memory"].headers.Authorization // empty' "$mcp" 2>/dev/null)" || auth=""
      # The header may or may not carry the scheme; a bare key is still a key.
      auth="${auth#Bearer }"
      auth="${auth#bearer }"
      if [ -n "$auth" ]; then MOLLOW_MEMORY_API_KEY="$auth"; export MOLLOW_MEMORY_API_KEY; fi
    fi
    if [ -z "${MOLLOW_MEMORY_URL:-}" ]; then
      url="$(jq -r '.mcpServers["mollow-memory"].url // empty' "$mcp" 2>/dev/null)" || url=""
      if [ -n "$url" ]; then MOLLOW_MEMORY_URL="$url"; export MOLLOW_MEMORY_URL; fi
    fi
  fi
  return 0
}

# Preconditions: a key, jq, and curl must be present, and MOLLOW_MEMORY_URL must
# end in /mcp/v2 — else the hook no-ops. The suffix check is a security guard: a
# misconfigured URL would otherwise send the mol_* key to `<full_url>/api/memory/*`
# on whatever host the URL resolves to.
#
# Resolution runs FIRST and the guards run after it, never instead of it: a URL
# arriving from `.mcp.json` is validated exactly like one from the environment.
# Putting resolution after the checks would validate the default and then send to
# whatever the file said.
mm_ready() {
  mm_resolve_memory_creds
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
# Falls back to ~/.mollow/supply-mode when MOLLOW_SUPPLY_MODE is unset or EMPTY
# (MOL-6221). Env wins in both directions when it says something: the launchers
# and test-supply-hooks.sh set it, so a file that overrode them would break both,
# and an explicit `off` in the environment must be able to hold a machine-wide
# `on` down for one session.
#
# An empty-but-exported variable is not a decision — that is what a launcher
# exporting a blank value looks like — so it falls through to the file rather
# than silently disabling a declared machine mode.
mm_supply_enabled() {
  local v="${MOLLOW_SUPPLY_MODE:-}"
  if [ -z "$v" ]; then
    v="$(mm_first_line_trimmed "$(mm_supply_mode_file)")"
  fi
  mm_truthy "$v"
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
      # TWO different refusals share this status and need OPPOSITE actions, so this
      # reads the body rather than asserting one — the same correction the 422
      # branch already took (Greptile, #6251).
      #
      #   JSON error.type=workspace_not_yours -> the APP. `tenant.ex:115`
      #     `verify_workspace/2` refuses a workspace id that is malformed, absent,
      #     or someone else's, and `ground_controller.ex:206` renders it 403.
      #   no error.type (an HTML page) -> the EDGE. The request never reached
      #     Phoenix, so no Mollow variable is implicated.
      #
      # Asserting workspace_not_yours for both sent the operator to edit a variable
      # that was already correct, on the one failure where the path or the edge rule
      # is what is actually wrong.
      case "$(mm_grounding_error_type "${2:-}")" in
        workspace_not_yours)
          printf 'Mollow supply mode: the grounding request was refused (403 workspace_not_yours). MOLLOW_SUPPLY_WORKSPACE_ID names a workspace this key does not own, or is not a valid uuid — check the workspace id, not the key.'
          ;;
        "")
          # Deliberately does not echo the body: it is an upstream error page, and
          # pasting HTML in front of the operator every turn is its own defect.
          printf 'Mollow supply mode: the grounding request was refused with a 403 carrying no Mollow error body, so it was blocked at the edge and never reached Mollow. This is not a workspace or credential problem — check that the request path is on the Cloudflare skip list (EDGE_SKIP_EXACT_PATHS in pulumi/dns_infrastructure.py).'
          ;;
        *)
          printf 'Mollow supply mode: the grounding request was refused (403 %s).' \
            "$(mm_grounding_error_type "${2:-}")"
          ;;
      esac
      ;;
    404)
      # The PATH is named because it is the one candidate the operator cannot rule
      # out from the message otherwise. The hooks hardcode the wire path and no env
      # var repoints them, so a half-landed path rename 404s identically to a flag
      # being off — and an operator told "flag, key, or header" checks all three,
      # finds them correct, and has nowhere left to look.
      printf 'Mollow supply mode: the grounding endpoint answered 404 for POST %s/grounding/v1/ground. Either supply_mode is off for your actor, the key is not valid, the credential is in the wrong header (it reads x-mollow-api-key, not Authorization), or that path is not what the router serves — compare it against the scope in webapp/lib/mollow_web/router.ex.' \
        "$(mm_api_base)"
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

  # Eviction is LEAST-RECENTLY-SEEN, and the shape of the filter is what makes it
  # so. `(existing - $new) + $new` moves a re-seen id from wherever it was to the
  # end, so the array reads oldest-first and `.[-500:]` drops the oldest.
  #
  # It used to be `(existing + $new) | unique | .[-500:]`, and **`unique` sorts**.
  # So eviction kept the 500 lexicographically-highest ids and dropped the rest,
  # with no relation to when anything was seen. Because these ids are content
  # digests, that is arbitrary per fact and permanent: an id beginning `z` was
  # retained forever, and one beginning `0` was evicted the instant the set passed
  # 500 — so the same fact was re-injected every single turn while another stayed
  # suppressed indefinitely. Measured directly: seed 500 ids sorting high, then add
  # one sorting low, and the just-seen id is **absent from the result**.
  #
  # `- $new` also does the dedupe `unique` was there for, against the additions.
  # `$new | unique` dedupes within one batch; that reorders ids inside a single
  # turn, which carries no recency meaning, and never across turns, which does.
  #
  # NOT a TTL. A fact stays suppressed until 500 further ids are seen (~100 turns
  # at 5 facts a turn), which is bounded but not time-based. A real TTL needs a
  # timestamp per id, and that changes the on-disk shape both readers parse as a
  # flat id array — a separate change with a migration, deliberately not bundled
  # here.
  #
  # Second branch covers an absent or corrupt file: start the key fresh rather
  # than losing the write. It dedupes too, and that is not symmetry for its own
  # sake: the first branch's dedupe comes from `- $new`, which has nothing to
  # subtract from when the file is absent. Without `unique` here a FIRST write
  # carrying a repeated id stored it twice, consuming two cap slots — measured
  # `["dup","dup","other"]` on a fresh file. Greptile caught this on #6360; the
  # test that was supposed to cover it passed only because its SECOND write
  # cleaned up after the first.
  if jq -c --arg k "$key" --argjson new "$additions" \
    '(. // {}) | .[$k] = ((((.[$k] // []) - $new) + ($new | unique)) | .[-500:])' \
    "$file" 2>/dev/null >"$tmp" ||
    jq -nc --arg k "$key" --argjson new "$additions" '{($k): ($new | unique)}' >"$tmp" 2>/dev/null; then
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
