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
#      under ~/.mollow (mm_tdd_marker) that guardrails-gate.sh (PreToolUse) checks
#      before its :block test-first rule. No preference => no marker => TDD stays
#      off. Nothing is written into the repository (MOL-6090).
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
# repo_root may be empty when the session isn't inside a git worktree. Only TDD
# arming needs a repository; the checklist fetch below does not.
repo_root="$(cd "${cwd:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"

# ── 0. Remove markers an older plugin version left in the repository ──────────
# Before MOL-6090 the marker was written to <repo>/tmp/.tdd-armed-<session>.json,
# creating tmp/ when the repo had none. Remove only files the plugin provably
# wrote: a regular file (not a symlink), not tracked by git, whose content is
# exactly the marker shape for the session its name carries. A symlinked tmp/
# is never followed, so nothing outside the checkout is touched. tmp/ itself is
# removed only if we deleted a marker and that left it empty (rmdir refuses
# otherwise). Anything else in it, including the customer's own .skip-tdd, is
# theirs. Runs whether or not this session arms, so an install whose TDD
# preference has gone still cleans up.
is_legacy_marker() {
  local f="$1" sid
  [ -f "$f" ] && [ ! -L "$f" ] || return 1
  sid="$(basename "$f" .json)"
  sid="${sid#.tdd-armed-}"
  git -C "$repo_root" ls-files --error-unmatch -- "$f" >/dev/null 2>&1 && return 1
  jq -e --arg s "$sid" '
    type == "object" and (keys == ["armed", "at_epoch", "session_id"])
    and .session_id == $s and .armed == true and (.at_epoch | type) == "number"
  ' "$f" >/dev/null 2>&1
}
if [ -n "$repo_root" ] && [ -d "${repo_root}/tmp" ] && [ ! -L "${repo_root}/tmp" ]; then
  removed=0
  for legacy in "${repo_root}"/tmp/.tdd-armed-*.json; do
    is_legacy_marker "$legacy" || continue
    rm -f "$legacy" 2>/dev/null && removed=1
  done
  [ "$removed" = 1 ] && { rmdir "${repo_root}/tmp" 2>/dev/null || true; }
fi

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
# Writes the per-session marker under ~/.mollow (mm_tdd_marker), never into the
# repository. Arm only when a returned memory actually expresses a TDD
# preference, not just any match on the query token.
tdd_notice=""
marker="$(mm_tdd_marker "${cwd:-$PWD}" "$session_id" || true)"
if [ -n "$repo_root" ] && [ -n "$marker" ]; then
  resp="$(mm_get "/api/memory/search?query=TDD&limit=5" 3)"
  if [ -n "$resp" ]; then
    match="$(printf '%s' "$resp" | jq -r '
      [ (.memories // [])[].content
        | select(test("tdd|test-driven|test first|failing test"; "i")) ]
      | length' 2>/dev/null || echo 0)"
    if [ "${match:-0}" -ge 1 ]; then
      if mkdir -p "$(dirname "$marker")" 2>/dev/null; then
        now="$(date +%s)"
        if jq -cn --arg sid "$session_id" --argjson at "$now" \
          '{session_id: $sid, armed: true, at_epoch: $at}' >"$marker" 2>/dev/null; then
          # One marker per session accumulates. guardrails-gate.sh refreshes a
          # marker's mtime each time it reads it, so these are markers no
          # session has used in 14 days; a resumed session re-arms here.
          find "${HOME}/.mollow/tdd-armed" -type f -name '*.json' -mtime +14 -delete 2>/dev/null || true
          find "${HOME}/.mollow/tdd-armed" -mindepth 1 -type d -empty -delete 2>/dev/null || true
          tdd_notice="TDD enforcement is ON for this session (your Engram preference). Write the failing test before implementation code, or the edit will be blocked. Bypass a specific edit with: mkdir -p $(printf '%q' "${repo_root}/tmp") && touch $(printf '%q' "${repo_root}/tmp/.skip-tdd")"
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
