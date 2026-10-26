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

echo "── a guard that cannot decide records, MARKED, and says so ──"
# The mark is the whole point of recording a non-answer. Without it the
# fail-open puts an answer nobody chose into the operator's decision history as
# a decision he made, where `recall_decision` returns it as a confident prior.
# `DecisionRecall` keeps a marked decision as context and never proposes it.
for case in "hooks/guard-3.sh:exit 3" "hooks/not-executable.sh:not executable" "hooks/absent.sh:missing"; do
  guard="${case%%:*}"; label="${case#*:}"
  run "$guard"
  if [ "$POSTS" = "1" ]; then pass "$label ⇒ posted"; else fail "$label ⇒ posted" "posts=$POSTS" "$ERR"; fi
  if grep -q "could not decide" <<<"$ERR"; then pass "$label ⇒ stderr says the guard could not decide"; else fail "$label ⇒ stderr says the guard could not decide" "$ERR"; fi
  if grep -q '"attendance_unverified":true' "$TMP/curl.log"; then pass "$label ⇒ body marked attendance_unverified"; else fail "$label ⇒ body marked attendance_unverified" "$(cat "$TMP/curl.log")"; fi
  if grep -q "marked attendance-unverified" <<<"$ERR"; then pass "$label ⇒ stderr names the mark"; else fail "$label ⇒ stderr names the mark" "$ERR"; fi
done

echo "── a guard that ANSWERS 'record' is not marked ──"
# The negative case is what makes the assertions above mean something: if every
# decision were marked, nothing would ever be proposed and the tests would still
# be green.
run "hooks/guard-1.sh"
if [ "$POSTS" = "1" ]; then pass "exit 1 ⇒ posted"; else fail "exit 1 ⇒ posted" "posts=$POSTS" "$ERR"; fi
if grep -q "attendance_unverified" "$TMP/curl.log"; then fail "exit 1 ⇒ NOT marked" "$(cat "$TMP/curl.log")"; else pass "exit 1 ⇒ NOT marked"; fi

echo "── no guard configured is not marked either ──"
# An absent guard is not an unverified answer: nobody asked for an attendance
# check, so treating it as unverified would stop proposing anything at all on
# every machine that has not configured one.
run ""
if [ "$POSTS" = "1" ]; then pass "no guard ⇒ posted"; else fail "no guard ⇒ posted" "posts=$POSTS" "$ERR"; fi
if grep -q "attendance_unverified" "$TMP/curl.log"; then fail "no guard ⇒ NOT marked" "$(cat "$TMP/curl.log")"; else pass "no guard ⇒ NOT marked"; fi

echo "── a guard that hangs is cut off, and the answer recorded ──"
started=$(date +%s)
run "hooks/hangs.sh"
elapsed=$(( $(date +%s) - started ))
if [ "$POSTS" = "1" ]; then pass "hung guard ⇒ posted"; else fail "hung guard ⇒ posted" "posts=$POSTS" "$ERR"; fi
if grep -q "could not decide (exit 124)" <<<"$ERR"; then pass "hung guard ⇒ reported as a timeout"; else fail "hung guard ⇒ reported as a timeout" "$ERR"; fi
if grep -q '"attendance_unverified":true' "$TMP/curl.log"; then pass "hung guard ⇒ body marked attendance_unverified"; else fail "hung guard ⇒ body marked attendance_unverified" "$(cat "$TMP/curl.log")"; fi
if [ "$elapsed" -le 4 ]; then pass "hung guard ⇒ hook returned in ${elapsed}s, inside the 6s budget"; else fail "hung guard ⇒ hook returned within budget" "took ${elapsed}s"; fi

echo "── a guard that answers in the last tick is obeyed ──"
rm -f "$TMP/ticks" "$TMP/release" "$TMP/done"
EXTRA_PATH="$TMP/late-bin" run "hooks/late-no.sh"
if [ "$POSTS" = "0" ]; then pass "late exit 0 ⇒ not posted"; else fail "late exit 0 ⇒ not posted" "posts=$POSTS" "$ERR"; fi

echo "── an ASKED question carries the sweep signal from the receipt ──"
# record-sweep-decisions.sh records the ASSUMED tier only, so one answer is not
# two votes in DecisionRecall.confidence/2's agreement fraction. That leaves
# this hook as the only writer for an asked question — and without reading the
# receipt, `axis` / `engram_confidence` / `agreed_with_model` were lost for
# exactly the questions the operator answered, which is where
# `agreed_with_model` matters most. Reviewed on PR #7496.
( cd "$TMP/project" && git init -q . ) >/dev/null 2>&1
mkdir -p "$TMP/project/tmp"
cat > "$TMP/project/tmp/.question-sweep-cap-sess.json" <<'RECEIPT'
{"questions":[{"question":"Ship it?","axis":"failure modes","tier":"asked",
  "engram_confidence":0.62,"model_recommendation":"Fail open","agreed_with_model":false,"round":1}],
 "axes":["failure modes"],"rounds":[{"round":1}]}
RECEIPT

: > "$TMP/curl.log"
ERR="$(
  printf '%s' "$(printf '%s' "$PAYLOAD" | jq -c --arg c "$TMP/project" '. + {session_id:"cap-sess", cwd:$c}')"     | env -i       PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"       HOME="$TMP" CURL_LOG="$TMP/curl.log"       MOLLOW_MEMORY_API_KEY="mol_test"       MOLLOW_MEMORY_URL="http://localhost:1/mcp/v2"       MOLLOW_MEMORY_CREDS_FROM_FILES=0       CLAUDE_PROJECT_DIR="$TMP/project"       bash "$HOOK" 2>&1 >/dev/null
)" || true
CAPLOG="$(cat "$TMP/curl.log")"
if grep -q '"sweep"' <<<"$CAPLOG"; then pass "the decision carries a sweep object"; else fail "the decision carries a sweep object" "$CAPLOG"; fi
if grep -q '"failure modes"' <<<"$CAPLOG"; then pass "carries the axis"; else fail "carries the axis" "$CAPLOG"; fi
if grep -q '"agreed_with_model":false' <<<"$CAPLOG"; then pass "a recorded FALSE survives (jq // would have dropped it)"; else fail "a recorded false survives" "$CAPLOG"; fi

echo "── with no receipt, no sweep key is attached ──"
rm -f "$TMP/project/tmp/.question-sweep-cap-sess.json"
: > "$TMP/curl.log"
printf '%s' "$(printf '%s' "$PAYLOAD" | jq -c --arg c "$TMP/project" '. + {session_id:"cap-sess", cwd:$c}')"   | env -i PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin" HOME="$TMP" CURL_LOG="$TMP/curl.log"     MOLLOW_MEMORY_API_KEY="mol_test" MOLLOW_MEMORY_URL="http://localhost:1/mcp/v2"     MOLLOW_MEMORY_CREDS_FROM_FILES=0 CLAUDE_PROJECT_DIR="$TMP/project" bash "$HOOK" >/dev/null 2>&1 || true
if grep -q '"sweep"' "$TMP/curl.log"; then fail "no receipt must mean no sweep key" "$(cat "$TMP/curl.log")"; else pass "no receipt ⇒ no sweep key"; fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
