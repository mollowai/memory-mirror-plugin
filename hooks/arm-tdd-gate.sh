#!/usr/bin/env bash
set -euo pipefail
# SessionStart: arm the TDD gate IFF Engram says this user wants TDD.
#
# Asks the memory search endpoint for TDD-related memories; if any match, writes a
# per-session marker that tdd-gate.sh (PreToolUse) checks before allowing edits to
# implementation files. The gate stays disarmed unless the preference is found, so
# nothing is enforced for users who haven't expressed a TDD preference.
#
# Fail-safe (per _common.sh): no key / no jq / no match / any error => no marker,
# exit 0. Never blocks or breaks a session.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

mm_ready || exit 0

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
[ -z "$session_id" ] && exit 0
# Reject session ids that could escape the marker filename layout (path traversal).
[[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]] || exit 0

cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
repo_root="$(cd "${cwd:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$repo_root" ] && exit 0

resp="$(mm_get "/api/memory/search?query=TDD&limit=5" 3)"
[ -z "$resp" ] && exit 0

# Arm only when a returned memory actually expresses a TDD preference, not just any
# match on the query token.
match="$(printf '%s' "$resp" | jq -r '
  [ (.memories // [])[].content
    | select(test("tdd|test-driven|test first|failing test"; "i")) ]
  | length' 2>/dev/null || echo 0)"
[ "${match:-0}" -lt 1 ] && exit 0

marker="${repo_root}/tmp/.tdd-armed-${session_id}.json"
mkdir -p "${repo_root}/tmp" 2>/dev/null || exit 0
now="$(date +%s)"
jq -cn --arg sid "$session_id" --argjson at "$now" \
  '{session_id: $sid, armed: true, at_epoch: $at}' >"$marker" 2>/dev/null || exit 0

mm_emit_context "SessionStart" "TDD enforcement is ON for this session (your Engram preference). Write the failing test before implementation code, or the edit will be blocked. Bypass a specific edit with: touch tmp/.skip-tdd"
exit 0
