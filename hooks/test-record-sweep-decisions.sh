#!/usr/bin/env bash
# Tests for record-sweep-decisions.sh — the mechanical half of the question
# sweep's learning loop.
#
# `/ask-first` Phase 7 used to ask the MODEL to call `record_decision` for every
# assumption the operator confirmed or corrected. That step is what the whole
# loop depends on and it was the one most likely to be skipped, silently: a
# sweep that recorded nothing looks exactly like a sweep with nothing to record.
# This hook reads the receipt Phase 7 already writes, so the capture happens
# whether or not the model remembers.
#
# Four properties are pinned:
#
#   1. One POST per recordable entry, carrying the sweep signal.
#   2. An entry missing a question or an answer is SKIPPED, not posted with a
#      null — a decision row is consumed as a settled answer, so a half-entry
#      would teach the corpus something nobody said.
#   3. It runs at most once. `Stop` can fire more than once per session, and the
#      Space write path has no dedup (MOL-4692), so a second run would duplicate
#      the decision — and duplicates inflate confidence, because the same
#      decision agrees with itself.
#   4. It fails open and silent: no receipt, no credentials, malformed JSON.
#
# Posts go through a fake `curl` on PATH, so what is asserted is the real
# request rather than a reimplementation of the hook's jq.
#
# Run: bash plugins/memory-mirror/hooks/test-record-sweep-decisions.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/record-sweep-decisions.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-sweep-rec-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo/tmp"

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$TMP/bin/curl"

# A real repo, so the hook's git-root resolution has something to find.
( cd "$TMP/repo" && git init -q . && git remote add origin https://github.com/mollowai/monorepo.git ) >/dev/null 2>&1

SID="sess-sweep-1"

write_receipt() {
  printf '%s' "$1" > "$TMP/repo/tmp/.question-sweep-${SID}.json"
  rm -f "$TMP/repo/tmp/.question-sweep-${SID}.json.recorded"
}

run() {
  : > "$TMP/curl.log"
  ERR="$(
    printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"${SID}\",\"cwd\":\"$TMP/repo\"}" \
      | env -i \
        PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$TMP" \
        CURL_LOG="$TMP/curl.log" \
        MOLLOW_MEMORY_API_KEY="mol_test" \
        MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2" \
        MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
        ${MM_SWEEP_RECORD_BUDGET_S:+MM_SWEEP_RECORD_BUDGET_S="$MM_SWEEP_RECORD_BUDGET_S"} \
        bash "$HOOK" 2>&1 >/dev/null
  )" || true
  POSTS="$(grep -c '/api/memory/decisions' "$TMP/curl.log" || true)"
  LOG="$(cat "$TMP/curl.log")"
}

# Both ASSUMED, because only that tier is recorded here.
TWO_ENTRIES='{
  "questions": [
    {"question":"Where does this state live?","chosen":"Shared store","axis":"node-local state",
     "tier":"assumed","engram_confidence":0.91,"model_recommendation":"Shared store",
     "agreed_with_model":true,"round":1},
    {"question":"Worktree or inline?","chosen":"Isolated worktree","axis":"execution shape",
     "tier":"assumed","engram_confidence":0.71,"model_recommendation":"Inline",
     "agreed_with_model":false,"round":2}
  ],
  "axes": ["node-local state","execution shape"],
  "rounds": [{"round":1},{"round":2}]
}'

echo "── one POST per recordable entry, carrying the signal ──"
write_receipt "$TWO_ENTRIES"
run
if [ "$POSTS" = "2" ]; then pass "2 entries ⇒ 2 posts"; else fail "2 entries ⇒ 2 posts" "posts=$POSTS" "$ERR"; fi
if grep -q "node-local state" <<<"$LOG"; then pass "carries the axis"; else fail "carries the axis" "$LOG"; fi
if grep -q "0.91" <<<"$LOG"; then pass "carries engram_confidence"; else fail "carries engram_confidence" "$LOG"; fi
if grep -q '"agreed_with_model":false' <<<"$LOG"; then pass "carries a DISAGREEMENT, the case worth ranking"; else fail "carries a disagreement" "$LOG"; fi
if grep -q "github.com/mollowai/monorepo" <<<"$LOG"; then pass "carries the repo identity for scoping"; else fail "carries the repo identity" "$LOG"; fi

echo "── a half-entry is skipped, not posted with a null ──"
write_receipt '{"questions":[{"question":"No answer given?","axis":"scope","tier":"assumed"},{"chosen":"orphan","tier":"assumed"},{"question":"Real?","chosen":"Yes","tier":"assumed"}],"axes":["scope"],"rounds":[{"round":1}]}'
run
if [ "$POSTS" = "1" ]; then pass "only the complete entry posts"; else fail "only the complete entry posts" "posts=$POSTS" "$LOG"; fi
if grep -q "No answer given?" <<<"$LOG"; then fail "an answerless entry must not post" "$LOG"; else pass "an answerless entry does not post"; fi

echo "── an entry is posted once, and only once ──"
write_receipt "$TWO_ENTRIES"
run
first="$POSTS"
run
if [ "$first" = "2" ] && [ "$POSTS" = "0" ]; then
  pass "second run posts nothing (Stop can fire twice; the Space path has no dedup)"
else
  fail "second run posts nothing" "first=$first second=$POSTS" "$LOG"
fi

echo "── the ASKED tier is not recorded here ──"
# An asked question already reached Engram through AskUserQuestion ->
# capture-decision.sh. Recording it again makes one answer two votes in
# DecisionRecall.confidence/2's agreement fraction, and it would not dedup
# (this recorder writes its own rationale, so the content hash differs).
write_receipt '{"questions":[{"question":"Asked one?","chosen":"A","tier":"asked"},{"question":"Assumed one?","chosen":"B","tier":"assumed"}],"axes":["scope"],"rounds":[{"round":1}]}'
run
if [ "$POSTS" = "1" ]; then pass "only the assumed entry posts"; else fail "only the assumed entry posts" "posts=$POSTS" "$LOG"; fi
if grep -q "Asked one?" <<<"$LOG"; then fail "an asked entry must not be posted" "$LOG"; else pass "the asked entry is not posted"; fi
if grep -q "Assumed one?" <<<"$LOG"; then pass "the assumed entry is posted"; else fail "the assumed entry is posted" "$LOG"; fi

echo "── an entry with no tier is not recorded ──"
write_receipt '{"questions":[{"question":"Untiered?","chosen":"A"}],"axes":["scope"],"rounds":[{"round":1}]}'
run
if [ "$POSTS" = "0" ]; then pass "an untiered entry is not posted"; else fail "an untiered entry is not posted" "posts=$POSTS" "$LOG"; fi

echo "── a partial run RESUMES rather than losing the remainder ──"
# The old marker was claimed before the loop, so a run that ran out of budget
# marked everything done and every later Stop skipped the rest forever. This is
# that data loss, asserted: budget 0 posts nothing and leaves both pending.
write_receipt "$TWO_ENTRIES"
MM_SWEEP_RECORD_BUDGET_S=0 run
starved="$POSTS"
run
if [ "$starved" = "0" ] && [ "$POSTS" = "2" ]; then
  pass "an out-of-budget run leaves both entries pending; the next run finishes them"
else
  fail "a starved run must not consume the entries" "starved=$starved next=$POSTS" "$LOG"
fi

echo "── a ledger naming one entry leaves the other pending ──"
write_receipt "$TWO_ENTRIES"
run
if [ "$POSTS" = "2" ]; then
  # Drop one key; exactly one entry must be re-posted.
  sed -i.bak '1d' "$TMP/repo/tmp/.question-sweep-${SID}.json.recorded" 2>/dev/null
  run
  if [ "$POSTS" = "1" ]; then pass "only the un-ledgered entry is re-posted"; else fail "only the un-ledgered entry is re-posted" "posts=$POSTS" "$LOG"; fi
else
  fail "setup for the partial-ledger case" "posts=$POSTS"
fi

echo "── fail-open and silent ──"
rm -f "$TMP/repo/tmp/.question-sweep-${SID}.json" "$TMP/repo/tmp/.question-sweep-${SID}.json.recorded"
run
if [ "$POSTS" = "0" ]; then pass "no receipt ⇒ no posts"; else fail "no receipt ⇒ no posts" "posts=$POSTS"; fi

write_receipt '{"questions":['
run
if [ "$POSTS" = "0" ]; then pass "malformed receipt ⇒ no posts"; else fail "malformed receipt ⇒ no posts" "posts=$POSTS"; fi

write_receipt '{"axes":["scope"],"rounds":[{"round":1}]}'
run
if [ "$POSTS" = "0" ]; then pass "a receipt with no questions ⇒ no posts"; else fail "a receipt with no questions ⇒ no posts" "posts=$POSTS"; fi

echo "── a traversing session id is refused ──"
: > "$TMP/curl.log"
printf '%s' "{\"hook_event_name\":\"Stop\",\"session_id\":\"../../etc/passwd\",\"cwd\":\"$TMP/repo\"}" \
  | env -i PATH="$TMP/bin:/usr/bin:/bin:/opt/homebrew/bin" HOME="$TMP" CURL_LOG="$TMP/curl.log" \
    MOLLOW_MEMORY_API_KEY="mol_test" MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2" \
    MOLLOW_MEMORY_CREDS_FROM_FILES=0 bash "$HOOK" >/dev/null 2>&1 || true
if [ "$(grep -c '/api/memory/decisions' "$TMP/curl.log" || true)" = "0" ]; then
  pass "traversing session id ⇒ no posts"
else
  fail "traversing session id ⇒ no posts" "$(cat "$TMP/curl.log")"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
