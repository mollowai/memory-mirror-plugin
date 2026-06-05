#!/usr/bin/env bash
# PreToolUse(Write|Edit|MultiEdit): enforce test-first when TDD is armed.
#
# Blocks an edit to an implementation file unless the corresponding test file has
# been created or modified this session (test-first / "red" step). Detection is
# git-based: the expected test path must appear in the working tree's changes vs
# HEAD (tracked diff or untracked file).
#
# Armed by arm-tdd-gate.sh (SessionStart) only when Engram reports a TDD
# preference. If not armed, this is a no-op.
#
# Bypass: `touch tmp/.skip-tdd` (per-decision) or SKIP_TDD=1 in the session env.
#
# Block contract mirrors scripts/forge/hooks/require-quality-gates.sh: print
# {decision:"block", reason} to stdout and exit 2.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty')"
case "$TOOL_NAME" in
  Write | Edit | MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty')"
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty')"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty')"
[ -z "$FILE_PATH" ] && exit 0

REPO_ROOT="$(cd "${CWD:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"
[ -z "$REPO_ROOT" ] && exit 0

# Armed? No marker for this session => gate is off.
[ -z "$SESSION_ID" ] && exit 0
[ -f "${REPO_ROOT}/tmp/.tdd-armed-${SESSION_ID}.json" ] || exit 0

# Bypass.
[ "${SKIP_TDD:-0}" = "1" ] && exit 0
[ -f "${REPO_ROOT}/tmp/.skip-tdd" ] && exit 0

# Make the target repo-relative; ignore files outside the repo.
case "$FILE_PATH" in
  /*)
    REL="${FILE_PATH#"$REPO_ROOT"/}"
    case "$REL" in /*) exit 0 ;; esac
    ;;
  *) REL="$FILE_PATH" ;;
esac

# Classify + derive the expected test path. Only implementation logic is gated;
# everything else (tests, configs, .heex, migrations, docs) falls through to allow.
case "$REL" in
  */lib/*.ex | lib/*.ex)
    if [[ "$REL" == lib/* ]]; then
      EXPECTED="test/${REL#lib/}"
    else
      EXPECTED="${REL/\/lib\//\/test\/}"
    fi
    EXPECTED="${EXPECTED%.ex}_test.exs"
    ;;
  webapp/priv/python/*.py)
    case "$(basename "$REL")" in
      test_*.py | *_test.py) exit 0 ;;
    esac
    EXPECTED="$(dirname "$REL")/test_$(basename "${REL%.py}").py"
    ;;
  *) exit 0 ;;
esac

# Test written this session? Tracked changes vs HEAD plus untracked files.
CHANGED="$(
  cd "$REPO_ROOT" 2>/dev/null && {
    git diff --name-only HEAD 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  }
)"
if printf '%s\n' "$CHANGED" | grep -Fxq "$EXPECTED"; then
  exit 0
fi

reason="TDD is on (your Engram preference). No test changes detected for this implementation file.

Write or extend the failing test first:
  ${EXPECTED}
then implement:
  ${REL}

Refactor-only change already covered by existing tests? Bypass this edit with:
  touch tmp/.skip-tdd"

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 2
