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

# Cheap content fingerprint (portable: shasum | sha256sum | cksum).
fingerprint="$(
  if command -v shasum >/dev/null 2>&1; then
    cat "$mem_dir"/*.md 2>/dev/null | shasum | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    cat "$mem_dir"/*.md 2>/dev/null | sha256sum | awk '{print $1}'
  else
    cat "$mem_dir"/*.md 2>/dev/null | cksum | awk '{print $1}'
  fi
)"

state_dir="${HOME}/.mollow"
state_file="${state_dir}/memory-sync-state.json"
prev="$(jq -r --arg s "$slug" '.[$s] // empty' "$state_file" 2>/dev/null || true)"
[ "$fingerprint" = "$prev" ] && exit 0  # unchanged since last sync

remember_fingerprint() {
  mkdir -p "$state_dir" 2>/dev/null || return 0
  [ -f "$state_file" ] || echo '{}' >"$state_file"
  local tmp
  tmp="$(mktemp 2>/dev/null)" || return 0
  if jq --arg s "$slug" --arg f "$fingerprint" '.[$s]=$f' "$state_file" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$state_file" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

python_bin="$(command -v python3 || true)"

# ── Keyed silent mode: parse + POST directly ────────────────────────────────
if mm_ready && [ -n "$python_bin" ]; then
  entries="$("$python_bin" "$DIR/../scripts/extract-local-memories.py" --project "$cwd" 2>/dev/null || true)"
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
      [ "$all_ok" -eq 1 ] && remember_fingerprint
    ) >/dev/null 2>&1 &
  else
    # Nothing to import — record the fingerprint so we don't re-extract until change.
    remember_fingerprint
  fi
  exit 0
fi

# ── OAuth-only mode: nudge Claude to import via the MCP tool ─────────────────
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
# Nudge once per change-set so we don't nag every session if the user defers.
remember_fingerprint
exit 0
