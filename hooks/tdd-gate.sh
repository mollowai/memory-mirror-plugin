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

# Classify + derive the expected test path candidates. Only implementation logic
# is gated; tests, configs, .heex, migrations, docs, and vendored deps fall
# through to allow. Each arm sets PRIMARY (named in the block message) and
# CANDIDATES (newline-separated acceptable test paths) — the edit is allowed if
# ANY candidate appears in this session's working-tree changes. When the file
# doesn't clearly map to a separate test, fall through to allow (fail-safe).
name="$(basename "$REL")"
dir="$(dirname "$REL")"
stem="${name%.*}" # basename without its final extension

PRIMARY=""
CANDIDATES=""

case "$REL" in
  # Vendored / generated trees are never first-party logic.
  */deps/* | */node_modules/* | */_build/* | */out/* | */dist/*)
    exit 0
    ;;

  # Elixir.
  */lib/*.ex | lib/*.ex)
    if [[ "$REL" == lib/* ]]; then
      PRIMARY="test/${REL#lib/}"
    else
      PRIMARY="${REL/\/lib\//\/test\/}"
    fi
    PRIMARY="${PRIMARY%.ex}_test.exs"
    CANDIDATES="$PRIMARY"
    ;;

  # Python (webapp ML).
  webapp/priv/python/*.py)
    case "$name" in test_*.py | *_test.py) exit 0 ;; esac
    PRIMARY="${dir}/test_${stem}.py"
    CANDIDATES="$PRIMARY"
    ;;

  # VS Code extensions (Mocha; tests under <ext>/src/test/suite).
  extensions/*/src/*.ts | extensions/*/src/*.tsx)
    case "$REL" in
      *.d.ts | *.test.ts | *.test.tsx | *.spec.ts | *.spec.tsx | */src/test/*) exit 0 ;;
    esac
    ext_root="${REL%%/src/*}"
    sub="${REL#"${ext_root}"/src/}"
    PRIMARY="${ext_root}/src/test/suite/${stem}.test.ts"
    CANDIDATES="${PRIMARY}
${ext_root}/src/test/suite/${sub%.*}.test.ts"
    ;;

  # webapp/assets/js (Jest; co-located __tests__).
  webapp/assets/js/*.ts | webapp/assets/js/*.tsx)
    case "$REL" in
      *.d.ts | *.test.ts | *.test.tsx | *.spec.ts | *.spec.tsx) exit 0 ;;
      */__tests__/* | */__mocks__/* | webapp/assets/js/types/*) exit 0 ;;
    esac
    PRIMARY="${dir}/__tests__/${stem}.test.ts"
    CANDIDATES="${PRIMARY}
${dir}/__tests__/${stem}.test.tsx"
    ;;

  # browser-extension (Vitest; flat test/).
  browser-extension/src/*.js | browser-extension/src/*.ts)
    case "$REL" in
      *.d.ts | *.test.js | *.test.ts | *.spec.js | *.spec.ts) exit 0 ;;
    esac
    PRIMARY="browser-extension/test/${stem}.test.js"
    CANDIDATES="$PRIMARY"
    ;;

  # iOS Swift (XCTest target).
  ios/MollowWorkstation/MollowWorkstation/*.swift)
    case "$REL" in
      */MollowWorkstationTests/* | *Tests.swift) exit 0 ;;
    esac
    PRIMARY="ios/MollowWorkstation/MollowWorkstationTests/${stem}Tests.swift"
    CANDIDATES="$PRIMARY"
    ;;

  # Rust (bridge). Tests live in an external module file (idiomatic
  # `#[cfg(test)] mod tests;` -> <name>/tests.rs) or a tests/ integration file.
  bridge/tauri-app/src-tauri/src/*.rs)
    case "$REL" in
      *_test.rs | *_tests.rs | */tests.rs | */tests/* | */build.rs) exit 0 ;;
    esac
    # Transitional: existing files still using inline #[cfg(test)] blocks count
    # as tested, so ongoing bridge work isn't blocked before migration.
    if [ -f "${REPO_ROOT}/${REL}" ] && grep -q '#\[cfg(test)\]' "${REPO_ROOT}/${REL}" 2>/dev/null; then
      exit 0
    fi
    PRIMARY="${dir}/${stem}/tests.rs"
    CANDIDATES="${PRIMARY}
bridge/tauri-app/src-tauri/tests/${stem}.rs"
    ;;

  # Shell (scripts/; test-<name>.sh convention). Noisiest tier — bypass per the
  # block message when a script genuinely has no unit test to write.
  scripts/*.sh)
    case "$name" in test-*.sh) exit 0 ;; esac
    case "$REL" in scripts/tests/*) exit 0 ;; esac
    PRIMARY="${dir}/test-${stem}.sh"
    CANDIDATES="${PRIMARY}
scripts/test-${stem}.sh
scripts/tests/test-${stem}.sh"
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
while IFS= read -r cand; do
  [ -z "$cand" ] && continue
  if printf '%s\n' "$CHANGED" | grep -Fxq "$cand"; then
    exit 0
  fi
done <<EOF
$CANDIDATES
EOF

reason="TDD is on (your Engram preference). No test changes detected for this implementation file.

Write or extend the failing test first:
  ${PRIMARY}
then implement:
  ${REL}

Refactor-only change already covered by existing tests? Bypass this edit with:
  touch tmp/.skip-tdd"

jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 2
