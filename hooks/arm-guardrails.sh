#!/usr/bin/env bash
set -uo pipefail
# SessionStart: arm the Engram guardrail gate (MOL-2336).
#
# Two jobs, both fail-safe (no key / no jq / any error => exit 0, never block):
#
#   1. Self-check checklist — fetch the workspace's active ways-of-working
#      (GET /api/memory/guardrails, distilled by MOL-2335) and inject them as a
#      pre-action checklist via additionalContext. Empty for most users today;
#      no rules => no checklist.
#   2. TDD arming — if Engram carries a TDD preference, write a per-session marker
#      that guardrails-gate.sh (PreToolUse) checks before its :block test-first
#      rule. No preference => no marker => TDD stays off.
#
# The seeded :warn predicates in guardrails-gate.sh need no arming — they run
# locally on every gated call.

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
# repo_root may be empty when the session isn't inside a git worktree. Only the
# TDD marker write needs it; the checklist fetch below does not.
repo_root="$(cd "${cwd:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"

# ── 1. Active ways-of-working → self-check checklist ──────────────────────────
# Render at most a handful, :block first, each as one bullet. Empty list => "".
checklist="$(
  mm_get "/api/memory/guardrails" 3 | jq -r '
    (.ways_of_working // [])
    | sort_by(if .severity == "block" then 0 else 1 end)
    | map("  • [" + (.severity // "warn") + "] " + (.statement // ""))
    | .[0:8]
    | if length > 0
      then "Active ways-of-working for this workspace (self-check before acting):\n" + join("\n")
      else "" end
  ' 2>/dev/null || true
)"

# ── 2. TDD arming (the :block rule) ───────────────────────────────────────────
# Needs repo_root to write the per-session marker under the repo's tmp/. Arm only
# when a returned memory actually expresses a TDD preference, not just any match
# on the query token.
tdd_notice=""
if [ -n "$repo_root" ]; then
  resp="$(mm_get "/api/memory/search?query=TDD&limit=5" 3)"
  if [ -n "$resp" ]; then
    match="$(printf '%s' "$resp" | jq -r '
      [ (.memories // [])[].content
        | select(test("tdd|test-driven|test first|failing test"; "i")) ]
      | length' 2>/dev/null || echo 0)"
    if [ "${match:-0}" -ge 1 ]; then
      marker="${repo_root}/tmp/.tdd-armed-${session_id}.json"
      if mkdir -p "${repo_root}/tmp" 2>/dev/null; then
        now="$(date +%s)"
        if jq -cn --arg sid "$session_id" --argjson at "$now" \
          '{session_id: $sid, armed: true, at_epoch: $at}' >"$marker" 2>/dev/null; then
          tdd_notice="TDD enforcement is ON for this session (your Engram preference). Write the failing test before implementation code, or the edit will be blocked. Bypass a specific edit with: touch tmp/.skip-tdd"
        fi
      fi
    fi
  fi
fi

# ── Emit a single combined SessionStart context (checklist + TDD notice) ──────
context=""
[ -n "$checklist" ] && context="$checklist"
if [ -n "$tdd_notice" ]; then
  [ -n "$context" ] && context="${context}

${tdd_notice}" || context="$tdd_notice"
fi

mm_emit_context "SessionStart" "$context"
exit 0
