#!/usr/bin/env bash
set -euo pipefail
# Tests for guardrails-gate.sh — the PreToolUse Engram guardrail gate (MOL-2336).
#
# Two contracts under test:
#   * TDD :block (regression) — armed session, implementation edit with no test
#     change ⇒ exit 2 + {"decision":"block"} naming the expected test path.
#   * Seeded :warn predicates — a flagged Bash command / migration content ⇒
#     exit 0 + {"hookSpecificOutput":{...,"additionalContext":...}}; the call
#     proceeds. A clean call ⇒ exit 0 + no output.
#
# Each case builds a throwaway git repo and pipes a tool-call JSON into the gate.
#
# Run: bash plugins/memory-mirror/hooks/test-guardrails-gate.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$DIR/guardrails-gate.sh"
SID="test-session-0001"

# Network must never fire in tests: with no key, mm_ready() short-circuits the
# override POST and the checklist fetch.
unset MOLLOW_MEMORY_API_KEY

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

# Run the gate on a Write/Edit. Args: repo, rel-path, [tool]. Sets RC, OUT.
run_gate() {
  local repo="$1" rel="$2" tool="${3:-Edit}" input
  input="$(jq -cn --arg t "$tool" --arg f "$repo/$rel" --arg s "$SID" --arg c "$repo" \
    '{tool_name:$t, tool_input:{file_path:$f}, session_id:$s, cwd:$c}')"
  OUT="$(printf '%s' "$input" | bash "$GATE" 2>/dev/null)" && RC=0 || RC=$?
}

# Run the gate on a Bash call. Args: repo, command, [cwd-override]. Sets RC, OUT.
run_bash() {
  local repo="$1" cmd="$2" input
  local cwd="${3:-$repo}"
  input="$(jq -cn --arg cmd "$cmd" --arg s "$SID" --arg c "$cwd" \
    '{tool_name:"Bash", tool_input:{command:$cmd}, session_id:$s, cwd:$c}')"
  OUT="$(printf '%s' "$input" | bash "$GATE" 2>/dev/null)" && RC=0 || RC=$?
}

# Run the gate on a Write with content. Args: repo, rel-path, content. Sets RC, OUT.
run_write() {
  local repo="$1" rel="$2" content="$3" input
  input="$(jq -cn --arg f "$repo/$rel" --arg ct "$content" --arg s "$SID" --arg c "$repo" \
    '{tool_name:"Write", tool_input:{file_path:$f, content:$ct}, session_id:$s, cwd:$c}')"
  OUT="$(printf '%s' "$input" | bash "$GATE" 2>/dev/null)" && RC=0 || RC=$?
}

# Run the gate on an Edit. Args: repo, rel-path, old_string, new_string. Sets RC, OUT.
run_edit() {
  local repo="$1" rel="$2" old="$3" new="$4" input
  input="$(jq -cn --arg f "$repo/$rel" --arg o "$old" --arg n "$new" --arg s "$SID" --arg c "$repo" \
    '{tool_name:"Edit", tool_input:{file_path:$f, old_string:$o, new_string:$n}, session_id:$s, cwd:$c}')"
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

# assert the gate ALLOWED (exit 0). Output (advisory warnings) is permitted.
assert_allow() {
  local name="$1" repo="$2" rel="$3" tool="${4:-Edit}"
  run_gate "$repo" "$rel" "$tool"
  if [[ "$RC" == 0 ]]; then pass "$name"; else fail "$name" "expected rc=0" "got rc=$RC, out=$OUT"; fi
}

# assert a :warn fired: exit 0, additionalContext present, message names $needle.
assert_warn() {
  local name="$1" needle="$2"
  if [[ "$RC" == 0 ]] && grep -q 'additionalContext' <<<"$OUT" && grep -qF "$needle" <<<"$OUT"; then
    pass "$name"
  else
    fail "$name" "expected rc=0 + additionalContext naming '$needle'" "got rc=$RC, out=$OUT"
  fi
}

# assert NO warning: exit 0 and no additionalContext emitted.
assert_clean() {
  local name="$1"
  if [[ "$RC" == 0 ]] && ! grep -q 'additionalContext' <<<"$OUT"; then
    pass "$name"
  else
    fail "$name" "expected rc=0 + no additionalContext" "got rc=$RC, out=$OUT"
  fi
}

# ══ TDD :block (regression — unchanged behavior) ══════════════════════════════

# ── Elixir ────────────────────────────────────────────────────────────────────
r="$(mk_repo)"
assert_block "elixir: lib edit w/o test blocks" "$r" "webapp/lib/mollow/foo.ex" "webapp/test/mollow/foo_test.exs"
put "$r" "webapp/test/mollow/foo_test.exs"
assert_allow "elixir: lib edit w/ test allows" "$r" "webapp/lib/mollow/foo.ex"

# ── Python ────────────────────────────────────────────────────────────────────
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
# Root-level generated/vendored dirs must skip too (would otherwise match */lib/*.ex).
assert_allow "non-gated: root-level deps/ .ex allowed" "$r" "deps/lumis/lib/lumis.ex"
assert_allow "non-gated: root-level _build/ .ex allowed" "$r" "_build/dev/lib/app/foo.ex"

# ── Bypass + arming ───────────────────────────────────────────────────────────
r="$(mk_repo)"
SKIP_TDD=1 run_gate "$r" "webapp/lib/mollow/foo.ex"
if [[ "$RC" == 0 ]]; then pass "bypass: SKIP_TDD=1 allows"; else fail "bypass: SKIP_TDD=1 allows" "rc=$RC"; fi
touch "$r/tmp/.skip-tdd"
assert_allow "bypass: tmp/.skip-tdd allows" "$r" "webapp/lib/mollow/foo.ex"

r="$(mk_repo)"
rm -f "$r/tmp/.tdd-armed-${SID}.json"
assert_allow "disarmed: no marker => allow" "$r" "webapp/lib/mollow/foo.ex"

# ══ Seeded :warn predicates (MOL-2336) ════════════════════════════════════════
r="$(mk_repo)"

# ── Bash command conventions ──────────────────────────────────────────────────
run_bash "$r" "git push --force origin main"
assert_warn "warn: force-push without lease" "force-push"
run_bash "$r" "git push --force-with-lease origin main"
assert_clean "clean: force-with-lease is fine"

run_bash "$r" "git commit --no-verify -m wip"
assert_warn "warn: git --no-verify" "no-verify"
run_bash "$r" "npm publish --no-verify"
assert_clean "clean: non-git --no-verify not flagged"

run_bash "$r" "docker build --no-cache -t app ."
assert_warn "warn: docker --no-cache" "no-cache"

run_bash "$r" "git worktree remove ../wt"
assert_warn "warn: raw worktree remove" "worktree remove"

run_bash "$r" "mix test test/foo_test.exs"
assert_warn "warn: mix test without quiet formatter" "TEST_FORMATTER=quiet"
run_bash "$r" "TEST_FORMATTER=quiet mix test test/foo_test.exs"
assert_clean "clean: quiet formatter present"

run_bash "$r" "git commit --amend --no-edit"
assert_warn "warn: commit --amend" "amend"

# native mix only warns inside a yolo (/workspaces/) session.
run_bash "$r" "mix deps.get" "/workspaces/mol-9999"
assert_warn "warn: native mix in yolo session" "docker compose exec"
run_bash "$r" "mix deps.get" "$r"
assert_clean "clean: native mix outside yolo is fine"

run_bash "$r" "ls -la && cat README.md"
assert_clean "clean: benign command no warning"

# ── Migration content conventions (Write) ─────────────────────────────────────
mig="webapp/priv/repo/migrations/20260628000000_add_thing.exs"
run_write "$r" "$mig" "add :name, :string"
assert_warn "warn: migration :string" ":string"
run_write "$r" "$mig" $'def up do\n  :ok\nend'
assert_warn "warn: migration up/down" "up/down"
run_write "$r" "$mig" "inserted_at = 2026-06-28T12:00:00Z"
assert_warn "warn: migration ISO8601 literal" "ISO8601"
run_write "$r" "$mig" $'def change do\n  add :name, :text\nend'
assert_clean "clean: migration with change/0 + :text"

# Edit scans only new_string: replacing :string with :text must NOT warn on the
# removed :string (Greptile P2 false-positive fix).
run_edit "$r" "$mig" "add :name, :string" "add :name, :text"
assert_clean "clean: Edit :string→:text scans new text only"
run_edit "$r" "$mig" "add :name, :text" "add :name, :string"
assert_warn "warn: Edit introducing :string still flags" ":string"

# ── Skip-marker bypasses the :block path (Write/Edit) ─────────────────────────
# Exercise the block leg explicitly, then prove the skip marker turns the same
# would-block edit into an allow — so a regression in the bypass can't slip through.
r="$(mk_repo)"
assert_block "skip-path: gated impl blocks without marker" "$r" \
  "webapp/lib/mollow/svc.ex" "webapp/test/mollow/svc_test.exs"
touch "$r/tmp/.skip-tdd"
assert_allow "skip-path: .skip-tdd bypasses the :block" "$r" "webapp/lib/mollow/svc.ex"

# ── Warn still surfaces under the skip marker (Bash advisory path) ────────────
r="$(mk_repo)"
touch "$r/tmp/.skip-tdd"
run_bash "$r" "git push --force origin main"
assert_warn "compose: warn surfaces under skip marker" "force-push"

echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[[ "$FAIL" -eq 0 ]]
