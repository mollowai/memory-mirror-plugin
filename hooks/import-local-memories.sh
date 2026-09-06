#!/usr/bin/env bash
# SessionStart: sync this project's local Claude Code memory files
# (~/.claude/projects/<slug>/memory/*.md + MEMORY.md) into Mollow.
#
# Two modes, picked by what's available — both fail-safe (always exit 0, never
# block a session):
#   * Keyed + python3  -> parse and POST to /api/memory/import silently.
#   * Otherwise        -> inject a prompt nudging Claude to run the
#                         /memory-mirror:import-local-memories skill over its
#                         OAuth MCP connection (works for every end user).
#
# Incremental: a content fingerprint per project is stored in
# ~/.mollow/memory-sync-state.json so an unchanged memory dir does nothing.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -z "$cwd" ] && exit 0

# Claude Code names a project dir by its abs path with / and . turned to -.
slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
mem_dir="${HOME}/.claude/projects/${slug}/memory"
[ -d "$mem_dir" ] || exit 0
ls "$mem_dir"/*.md >/dev/null 2>&1 || exit 0

# `repo` is the destination map's key; `project` beside it stays the directory
# slug. Derived with the same `mm_repo_of` the decision hooks use, so all three
# producers key off one rule (MOL-4740).
mm_repo="$(mm_repo_of "$cwd" 2>/dev/null || true)"

# Cheap content fingerprint (portable: shasum | sha256sum | cksum).
#
# The repo is folded in because it is part of what gets SENT, not just of what
# is read. Without it, every existing user's fingerprint still matches, the
# early exit below fires, and their memories are never re-posted with a `repo` —
# they stay in the private workspace until their content happens to change, so
# the routing change would be inert for exactly the people who already use it.
#
# Same self-heal the `${env}:${slug}` state key relies on: the value changes, the
# old entry stops matching, and each affected project re-syncs once. Folding it
# into the fingerprint rather than bumping a one-off version marker also keeps
# this correct later — repointing a remote changes the repo and re-syncs.
fingerprint="$(
  if command -v shasum >/dev/null 2>&1; then
    { printf '%s\n' "$mm_repo"; cat "$mem_dir"/*.md 2>/dev/null; } | shasum | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    { printf '%s\n' "$mm_repo"; cat "$mem_dir"/*.md 2>/dev/null; } | sha256sum | awk '{print $1}'
  else
    { printf '%s\n' "$mm_repo"; cat "$mem_dir"/*.md 2>/dev/null; } | cksum | awk '{print $1}'
  fi
)"

state_dir="${HOME}/.mollow"
state_file="${state_dir}/memory-sync-state.json"

# State keys are scoped by TARGET ENV, not just project: `${env}:${slug}`. A
# `synced` fingerprint recorded against one env must not suppress the push to a
# different env after a fleet-target switch. Without this, memories synced to
# staging looked "done" and never reached prod (observed 2026-07-01: 13/221
# absent from prod). A bare legacy `{slug: fp}` entry (no env prefix) no longer
# matches `${env}:${slug}`, so it is treated as not-yet-synced and re-syncs once
# per env — the intended self-heal.
state_key="$(mm_env_label):${slug}"

# State is namespaced so "we nudged the user" is never mistaken for "memories
# are in Mollow". `synced` is written ONLY after a successful import; `nudged`
# only throttles the OAuth-mode prompt.
read_state() { # $1 = namespace (synced|nudged)
  jq -r --arg ns "$1" --arg s "$state_key" '.[$ns][$s] // empty' "$state_file" 2>/dev/null || true
}

# Already imported this exact content to THIS env — nothing to do.
[ "$fingerprint" = "$(read_state synced)" ] && exit 0

remember_fingerprint() { # $1 = namespace (synced|nudged)
  local ns="$1"
  mkdir -p "$state_dir" 2>/dev/null || return 0
  [ -f "$state_file" ] || echo '{}' >"$state_file"
  local tmp
  tmp="$(mktemp 2>/dev/null)" || return 0
  if jq --arg ns "$ns" --arg s "$state_key" --arg f "$fingerprint" \
       '.[$ns][$s]=$f' "$state_file" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

python_bin="$(command -v python3 || true)"

# ── Keyed silent mode: parse + POST directly ────────────────────────────────
if mm_ready && [ -n "$python_bin" ]; then
  if [ -n "$mm_repo" ]; then
    entries="$("$python_bin" "$DIR/../scripts/extract-local-memories.py" --project "$cwd" --repo "$mm_repo" 2>/dev/null || true)"
  else
    entries="$("$python_bin" "$DIR/../scripts/extract-local-memories.py" --project "$cwd" 2>/dev/null || true)"
  fi
  if [ -n "$entries" ] && [ "$entries" != "[]" ]; then
    # Server caps a batch at 100 — chunk and POST each. Backgrounded so
    # SessionStart returns immediately; server dedup keeps it idempotent. The
    # fingerprint is recorded only if every chunk POSTs successfully, so a
    # transient outage re-syncs next session instead of being skipped forever.
    (
      all_ok=1
      while IFS= read -r chunk; do
        mm_post_ok "/api/memory/import" "{\"entries\":${chunk}}" 8 || all_ok=0
      done < <(
        printf '%s' "$entries" \
          | jq -c 'def chunks(n): [range(0; length; n) as $i | .[$i:$i+n]]; chunks(100)[]' 2>/dev/null
      )
      [ "$all_ok" -eq 1 ] && remember_fingerprint synced
    ) >/dev/null 2>&1 &
  else
    # Nothing to import — record as synced so we don't re-extract until change.
    remember_fingerprint synced
  fi
  exit 0
fi

# ── OAuth-only mode: nudge Claude to import via the MCP tool ─────────────────
# This path CANNOT import (no key), so it never writes `synced` — that would
# strand the memories (the I1 bug). It only throttles its own prompt: skip when
# we've already nudged for this exact content. A real import (the keyed path
# above, or the native app's `bridge/memory_sync`) is what marks `synced`.
[ "$fingerprint" = "$(read_state nudged)" ] && exit 0

count=""
if [ -n "$python_bin" ]; then
  count="$("$python_bin" "$DIR/../scripts/extract-local-memories.py" --project "$cwd" 2>/dev/null | jq 'length' 2>/dev/null || true)"
fi

if [ -n "$count" ] && [ "$count" != "0" ]; then
  msg="You have ${count} local Claude Code memories in this project that may not be synced to Mollow yet. Run the /memory-mirror:import-local-memories skill to import them."
else
  msg="This project has local Claude Code memory files that may not be synced to Mollow. Run the /memory-mirror:import-local-memories skill to import them."
fi

mm_emit_context "SessionStart" "$msg"
# Throttle: record under `nudged` (NOT `synced`) so we re-prompt when the
# content changes but never claim the memories reached Mollow.
remember_fingerprint nudged
exit 0
