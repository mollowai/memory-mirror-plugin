#!/usr/bin/env bash
set -euo pipefail
# Tests for tdd-gate.sh — the PreToolUse TDD enforcement gate.
#
# Each case builds a throwaway git repo, arms the gate with a fake session marker,
# pipes a Write/Edit tool-call JSON into the gate, and asserts the exit code +
# block payload. exit 2 + {"decision":"block"} == gated; exit 0 == allowed.
#
# Run: bash plugins/memory-mirror/hooks/test-tdd-gate.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/tdd-gate.sh"
SID="test-session-0001"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() {
  echo -e "${RED}FAIL${NC}: $1"
  shift
  for line in "$@"; do echo "  $line"; done
  FAIL=$((FAIL + 1))
}

# Fresh isolated repo with an initial commit and (by default) the gate armed.
mk_repo() {
  local repo
  repo="$(cd "$(mktemp -d)" && pwd -P)"
  git -C "$repo" init -q
  git -C "$repo" config user.email t@t.t
  git -C "$repo" config user.name t
  : >"$repo/.gitkeep"
  git -C "$repo" add .gitkeep
  git -C "$repo" commit -qm init
  mkdir -p "$repo/tmp"
  printf '{"armed":true}' >"$repo/tmp/.tdd-armed-${SID}.json"
  printf '%s' "$repo"
}

# Write a file (and parents) inside a repo, relative path.
put() { mkdir -p "$(dirname "$1/$2")"; printf '%s' "${3:-x}" >"$1/$2"; }

# Run the gate. Args: repo, rel-path, [tool]. Sets globals: RC, OUT.
run_gate() {
  local repo="$1" rel="$2" tool="${3:-Edit}" input
  input="$(jq -cn --arg t "$tool" --arg f "$repo/$rel" --arg s "$SID" --arg c "$repo" \
    '{tool_name:$t, tool_input:{file_path:$f}, session_id:$s, cwd:$c}')"
  OUT="$(printf '%s' "$input" | bash "$GATE" 2>/dev/null)" && RC=0 || RC=$?
}

# assert the gate BLOCKED, and the block message names the expected test path.
assert_block() {
  local name="$1" repo="$2" rel="$3" want="$4"
  run_gate "$repo" "$rel"
  if [[ "$RC" == 2 ]] && grep -q '"block"' <<<"$OUT" && grep -qF "$want" <<<"$OUT"; then
    pass "$name"
  else
    fail "$name" "expected rc=2 + block naming '$want'" "got rc=$RC, out=$OUT"
  fi
}

# assert the gate ALLOWED (exit 0, no output).
assert_allow() {
  local name="$1" repo="$2" rel="$3" tool="${4:-Edit}"
  run_gate "$repo" "$rel" "$tool"
  if [[ "$RC" == 0 ]]; then pass "$name"; else fail "$name" "expected rc=0" "got rc=$RC, out=$OUT"; fi
}

# ── Elixir (existing behavior — regression) ───────────────────────────────────
r="$(mk_repo)"
assert_block "elixir: lib edit w/o test blocks" "$r" "webapp/lib/mollow/foo.ex" "webapp/test/mollow/foo_test.exs"
put "$r" "webapp/test/mollow/foo_test.exs"
assert_allow "elixir: lib edit w/ test allows" "$r" "webapp/lib/mollow/foo.ex"

# ── Python (existing) ─────────────────────────────────────────────────────────
r="$(mk_repo)"
assert_block "python: edit w/o test blocks" "$r" "webapp/priv/python/bar.py" "webapp/priv/python/test_bar.py"
assert_allow "python: test file itself allowed" "$r" "webapp/priv/python/test_bar.py"
put "$r" "webapp/priv/python/test_bar.py"
assert_allow "python: edit w/ test allows" "$r" "webapp/priv/python/bar.py"

# ── VS Code extension TypeScript ──────────────────────────────────────────────
r="$(mk_repo)"
assert_block "ext: ts edit w/o test blocks" "$r" \
  "extensions/mollow-workspace/src/connection.ts" \
  "extensions/mollow-workspace/src/test/suite/connection.test.ts"
assert_allow "ext: .d.ts skipped" "$r" "extensions/mollow-workspace/src/api.d.ts"
assert_allow "ext: test file itself allowed" "$r" "extensions/mollow-workspace/src/test/suite/connection.test.ts"
put "$r" "extensions/mollow-workspace/src/test/suite/connection.test.ts"
assert_allow "ext: ts edit w/ test allows" "$r" "extensions/mollow-workspace/src/connection.ts"

# ── webapp/assets/js (Jest, co-located __tests__) ─────────────────────────────
r="$(mk_repo)"
assert_block "webapp-js: hook edit w/o test blocks" "$r" \
  "webapp/assets/js/hooks/Foo.ts" "webapp/assets/js/hooks/__tests__/Foo.test.ts"
assert_allow "webapp-js: __tests__ file allowed" "$r" "webapp/assets/js/hooks/__tests__/Foo.test.ts"
put "$r" "webapp/assets/js/hooks/__tests__/Foo.test.tsx"
assert_allow "webapp-js: .test.tsx satisfies .ts source" "$r" "webapp/assets/js/hooks/Foo.ts"

# ── browser-extension (Vitest, flat test/) ────────────────────────────────────
r="$(mk_repo)"
assert_block "browser-ext: nested src edit w/o test blocks" "$r" \
  "browser-extension/src/sync/mirror.js" "browser-extension/test/mirror.test.js"
put "$r" "browser-extension/test/mirror.test.js"
assert_allow "browser-ext: edit w/ flat test allows" "$r" "browser-extension/src/sync/mirror.js"

# ── iOS Swift (XCTest target) ─────────────────────────────────────────────────
r="$(mk_repo)"
assert_block "swift: source edit w/o test blocks" "$r" \
  "ios/MollowWorkstation/MollowWorkstation/Services/DocumentEngine.swift" \
  "ios/MollowWorkstation/MollowWorkstationTests/DocumentEngineTests.swift"
assert_allow "swift: test target file allowed" "$r" \
  "ios/MollowWorkstation/MollowWorkstationTests/DocumentEngineTests.swift"
put "$r" "ios/MollowWorkstation/MollowWorkstationTests/DocumentEngineTests.swift"
assert_allow "swift: edit w/ test allows" "$r" \
  "ios/MollowWorkstation/MollowWorkstation/Services/DocumentEngine.swift"

# ── Rust (external test module + inline transitional escape) ───────────────────
r="$(mk_repo)"
put "$r" "bridge/tauri-app/src-tauri/src/newmod.rs" "pub fn f() {}"
assert_block "rust: new file w/o tests blocks" "$r" \
  "bridge/tauri-app/src-tauri/src/newmod.rs" "bridge/tauri-app/src-tauri/src/newmod/tests.rs"
put "$r" "bridge/tauri-app/src-tauri/src/newmod/tests.rs"
assert_allow "rust: edit w/ external tests module allows" "$r" \
  "bridge/tauri-app/src-tauri/src/newmod.rs"

r="$(mk_repo)"
put "$r" "bridge/tauri-app/src-tauri/src/middleware.rs" $'pub fn f() {}\n#[cfg(test)]\nmod tests {}\n'
assert_allow "rust: legacy inline #[cfg(test)] escapes" "$r" \
  "bridge/tauri-app/src-tauri/src/middleware.rs"
assert_allow "rust: tests module file itself allowed" "$r" \
  "bridge/tauri-app/src-tauri/src/newmod/tests.rs"

# ── Shell (scripts/, test-*.sh convention) ────────────────────────────────────
r="$(mk_repo)"
assert_block "shell: script edit w/o test blocks" "$r" "scripts/foo.sh" "scripts/test-foo.sh"
assert_allow "shell: test-*.sh itself allowed" "$r" "scripts/test-foo.sh"
put "$r" "scripts/test-foo.sh"
assert_allow "shell: edit w/ sibling test allows" "$r" "scripts/foo.sh"

# ── Non-gated paths fall through to allow ─────────────────────────────────────
r="$(mk_repo)"
assert_allow "non-gated: heex allowed" "$r" "webapp/lib/mollow_web/live/foo.html.heex"
assert_allow "non-gated: package.json allowed" "$r" "extensions/mollow-workspace/package.json"
assert_allow "non-gated: migration allowed" "$r" "webapp/priv/repo/migrations/001_x.exs"
assert_allow "non-gated: vendored dep .rs allowed" "$r" "webapp/deps/lumis/native/lumis_nif/src/lib.rs"

# ── Bypass + arming ───────────────────────────────────────────────────────────
r="$(mk_repo)"
SKIP_TDD=1 run_gate "$r" "webapp/lib/mollow/foo.ex"
if [[ "$RC" == 0 ]]; then pass "bypass: SKIP_TDD=1 allows"; else fail "bypass: SKIP_TDD=1 allows" "rc=$RC"; fi
touch "$r/tmp/.skip-tdd"
assert_allow "bypass: tmp/.skip-tdd allows" "$r" "webapp/lib/mollow/foo.ex"

r="$(mk_repo)"
rm -f "$r/tmp/.tdd-armed-${SID}.json"
assert_allow "disarmed: no marker => allow" "$r" "webapp/lib/mollow/foo.ex"

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
