#!/usr/bin/env bash
set -euo pipefail
# Tests for capture-decision.sh's MOLLOW_MEMORY_CAPTURE_GUARD contract.
#
# ## The failure these exist for
#
# capture-decision.sh records every AskUserQuestion answer as "a decision the
# user just made". In a session with nobody at its pane, a menu that rendered
# anyway still comes back with an answer, and nothing established that a person
# chose it. The ruling on that case is "do not record it". The plugin cannot
# tell an unattended session from an attended one, so a host names a guard
# command and the plugin obeys its exit status.
#
# ## What must hold
#
#   * guard exits 0  ⇒ nothing is posted, and stderr says why
#   * guard exits 1  ⇒ the decision is posted
#   * guard missing, not executable, or exiting anything else ⇒ the decision is
#     posted AND stderr says the guard could not decide. A broken guard that
#     dropped every decision silently would look exactly like a quiet session.
#   * a relative guard path resolves against CLAUDE_PROJECT_DIR
#   * no guard configured ⇒ posted, as before the contract existed
#
# The fixture posts through a fake `curl` on PATH that records its arguments, so
# "posted" is observed rather than inferred — a hook that exits early and a hook
# whose request failed would otherwise read the same.
#
# Run: bash plugins/memory-mirror/hooks/test-capture-guard.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/capture-decision.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-capguard-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/project/hooks" "$TMP/cwd"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$TMP/bin/curl"

# Guards with known answers.
for rc in 0 1 3; do
  printf '#!/usr/bin/env bash\necho "$1" > "%s/guard-%s.arg"\nexit %s\n' "$TMP" "$rc" "$rc" \
    > "$TMP/project/hooks/guard-$rc.sh"
  chmod +x "$TMP/project/hooks/guard-$rc.sh"
done
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP/project/hooks/not-executable.sh"
# A guard that never answers. `exec sleep` so the kill reaches the sleeping
# process itself rather than leaving an orphan holding the test open.
printf '#!/usr/bin/env bash\nexec /bin/sleep 30\n' > "$TMP/project/hooks/hangs.sh"
chmod +x "$TMP/project/hooks/hangs.sh"
# A guard that says "do not record" during the hook's LAST polling tick. Real
# timing cannot place an exit there reliably, so the hook's own `sleep` is
# replaced for that one run: on the tick that reaches the limit it releases the
# guard and waits for it to exit. The loop then ends because the guard is gone,
# with the tick count at the limit — the state that used to be misread as a
# timeout. The guard polls with /bin/sleep so the fake does not reach it.
mkdir -p "$TMP/late-bin"
cat > "$TMP/late-bin/sleep" <<'FAKE'
#!/usr/bin/env bash
n=$(( $(cat "$LATE_DIR/ticks" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$LATE_DIR/ticks"
if [ "$n" -ge "$LATE_LIMIT_TICKS" ]; then
  : > "$LATE_DIR/release"
  while [ ! -e "$LATE_DIR/done" ]; do /bin/sleep 0.01; done
  /bin/sleep 0.2
fi
FAKE
chmod +x "$TMP/late-bin/sleep"
printf '#!/usr/bin/env bash\nwhile [ ! -e "%s/release" ]; do /bin/sleep 0.01; done\n: > "%s/done"\nexit 0\n' "$TMP" "$TMP" \
  > "$TMP/project/hooks/late-no.sh"
chmod +x "$TMP/project/hooks/late-no.sh"

PAYLOAD="$(jq -cn --arg cwd "$TMP/cwd" '{
  cwd: $cwd,
  session_id: "s-1",
  tool_input: {questions: [{question: "Ship it?", options: [{label: "Yes"}, {label: "No"}]}]},
  tool_response: "Your questions have been answered: \"Ship it?\"=\"Yes\". You can now continue."
}')"

# run <guard-or-empty> → sets POSTS (count) and ERR (stderr)
run() {
  local guard="$1"
  : > "$TMP/curl.log"
  ERR="$(
    printf '%s' "$PAYLOAD" | env -i \
      PATH="${EXTRA_PATH:+$EXTRA_PATH:}$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
      LATE_DIR="$TMP" LATE_LIMIT_TICKS=10 \
      HOME="$TMP" \
      CURL_LOG="$TMP/curl.log" \
      MOLLOW_MEMORY_API_KEY="mol_test" \
      MOLLOW_MEMORY_URL="http://localhost:1/mcp/v2" \
      MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
      MOLLOW_MEMORY_CAPTURE_GUARD_TIMEOUT=1 \
      CLAUDE_PROJECT_DIR="$TMP/project" \
      ${guard:+MOLLOW_MEMORY_CAPTURE_GUARD="$guard"} \
      bash "$HOOK" 2>&1 >/dev/null
  )" || true
  POSTS="$(grep -c '/api/memory/decisions' "$TMP/curl.log" || true)"
}

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

echo "── fixture: with no guard the decision is posted ──"
# If this fails the fake curl is not on the hook's path, and every "not posted"
# below would pass vacuously.
run ""
if [ "$POSTS" = "1" ]; then pass "no guard ⇒ posted once"; else fail "no guard ⇒ posted once" "posts=$POSTS" "$ERR"; fi

echo "── a guard that says nobody chose ──"
run "$TMP/project/hooks/guard-0.sh"
if [ "$POSTS" = "0" ]; then pass "exit 0 ⇒ not posted"; else fail "exit 0 ⇒ not posted" "posts=$POSTS"; fi
if grep -q "not recording this answer" <<<"$ERR"; then pass "exit 0 ⇒ stderr says why"; else fail "exit 0 ⇒ stderr says why" "$ERR"; fi
if [ "$(cat "$TMP/guard-0.arg" 2>/dev/null)" = "$TMP/cwd" ]; then
  pass "the guard is handed the session's cwd"
else
  fail "the guard is handed the session's cwd" "got: $(cat "$TMP/guard-0.arg" 2>/dev/null)"
fi

echo "── a guard that says the session is attended ──"
run "$TMP/project/hooks/guard-1.sh"
if [ "$POSTS" = "1" ]; then pass "exit 1 ⇒ posted"; else fail "exit 1 ⇒ posted" "posts=$POSTS" "$ERR"; fi
if [ -z "$ERR" ]; then pass "exit 1 ⇒ nothing on stderr"; else fail "exit 1 ⇒ nothing on stderr" "$ERR"; fi

echo "── a relative guard resolves against CLAUDE_PROJECT_DIR ──"
run "hooks/guard-0.sh"
if [ "$POSTS" = "0" ]; then pass "relative path found under the project"; else fail "relative path found under the project" "posts=$POSTS" "$ERR"; fi

echo "── a guard that cannot decide records, and says so ──"
for case in "hooks/guard-3.sh:exit 3" "hooks/not-executable.sh:not executable" "hooks/absent.sh:missing"; do
  guard="${case%%:*}"; label="${case#*:}"
  run "$guard"
  if [ "$POSTS" = "1" ]; then pass "$label ⇒ posted"; else fail "$label ⇒ posted" "posts=$POSTS" "$ERR"; fi
  if grep -q "could not decide" <<<"$ERR"; then pass "$label ⇒ stderr says the guard could not decide"; else fail "$label ⇒ stderr says the guard could not decide" "$ERR"; fi
done

echo "── a guard that hangs is cut off, and the answer recorded ──"
started=$(date +%s)
run "hooks/hangs.sh"
elapsed=$(( $(date +%s) - started ))
if [ "$POSTS" = "1" ]; then pass "hung guard ⇒ posted"; else fail "hung guard ⇒ posted" "posts=$POSTS" "$ERR"; fi
if grep -q "could not decide (exit 124)" <<<"$ERR"; then pass "hung guard ⇒ reported as a timeout"; else fail "hung guard ⇒ reported as a timeout" "$ERR"; fi
if [ "$elapsed" -le 4 ]; then pass "hung guard ⇒ hook returned in ${elapsed}s, inside the 6s budget"; else fail "hung guard ⇒ hook returned within budget" "took ${elapsed}s"; fi

echo "── a guard that answers in the last tick is obeyed ──"
rm -f "$TMP/ticks" "$TMP/release" "$TMP/done"
EXTRA_PATH="$TMP/late-bin" run "hooks/late-no.sh"
if [ "$POSTS" = "0" ]; then pass "late exit 0 ⇒ not posted"; else fail "late exit 0 ⇒ not posted" "posts=$POSTS" "$ERR"; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
