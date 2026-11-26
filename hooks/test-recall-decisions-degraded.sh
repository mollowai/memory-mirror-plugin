#!/usr/bin/env bash
# Tests for what recall-decisions.sh does with a DEGRADED recall response.
#
# MOL-9707. `POST /api/memory/decisions/recall` runs its `:contradictions`
# lookup as a separate leg under its own deadline. When that deadline expires
# the server answers 200 with
#
#     {"contradictions": [], "degraded": ["contradictions"]}
#
# — `[]` because nothing was computed, `degraded` because the server is saying
# so out loud (`memory_hook_controller.ex` merge_contradictions/3). Measured at
# ~249 breaches a day in production, every one of them on the hook that fires on
# every prompt of every session.
#
# The hook read only `contradictions`. An empty list rendered as nothing, so the
# turn was told there were no contradictions when in fact none had been looked
# for, and the call was written to the supply ledger as a clean `recall_ok` —
# inside the ledger MOL-9571 built specifically to count memory-rail misses.
#
# Why the fixture is shaped the way it is (boundary-test-preconditions.md): a
# response with no `degraded` key passes whether or not the bug is present, and
# so does a response carrying `degraded` with a non-empty `contradictions`
# list. The only shape that separates the bug from correct behaviour is
# `degraded: ["contradictions"]` TOGETHER WITH `contradictions: []`, which is
# exactly what the server sends. The negative cases — no `degraded` key, `null`,
# `[]` — are asserted too, because "always print the skipped line" would also
# make the positive assertions pass.
#
# The response is stubbed through a fake `curl` on PATH, so what is asserted is
# the hook's real output and the hook's real ledger writes rather than a
# reimplementation of its jq.
#
# Run: bash plugins/mollow-claude/hooks/test-recall-decisions-degraded.sh

# `-u` and `pipefail`, but NOT `-e`: this suite tallies failures and prints all
# of them, which an erroring exit on the first failed assertion would cut off.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/recall-decisions.sh"

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-recall-degraded-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
( cd "$TMP/repo" && git init -q . ) >/dev/null 2>&1

REASONS="$TMP/.mollow/supply-stop-reasons.log"
LATENCY="$TMP/.mollow/rail-latency.log"

# run <response-json> — stub the server reply, return the emitted context in CTX.
# Both ledgers are cleared first, so every assertion reads one call's writes.
run() {
  printf '%s' "$1" > "$TMP/response.json"
  rm -f "$REASONS" "$LATENCY" 2>/dev/null || true
  # Streak counters live under the same HOME; a stale one would change whether
  # the outage line is emitted.
  rm -rf "$TMP/.mollow/rail-streak" 2>/dev/null || true
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
cat "$MM_FAKE_RESPONSE"
# `-w '\n%{http_code}\t%{time_total}'` appends the trailer on its own final
# line. The hook splits the status off it, so the stub has to behave like the
# real thing or the assertions would be asserting the stub.
for a in "$@"; do
  case "$a" in
    *http_code*) printf '\n%s\t%s' "${MM_FAKE_STATUS:-200}" "0.311" ;;
  esac
done
EOF
  chmod +x "$TMP/bin/curl"

  local out
  out="$(
    printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"where should this work happen?\",\"cwd\":\"$TMP/repo\",\"session_id\":\"s1\"}" \
      | env -i \
        PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$TMP" \
        MM_FAKE_RESPONSE="$TMP/response.json" \
        MM_FAKE_STATUS="${MM_FAKE_STATUS:-200}" \
        MOLLOW_MEMORY_API_KEY="mol_test" \
        MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2" \
        MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
        bash "$HOOK" 2>/dev/null
  )" || true

  CTX="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")"
}

reasons() { cat "$REASONS" 2>/dev/null || true; }
latency() { cat "$LATENCY" 2>/dev/null || true; }

# The header the hook prints when contradictions were actually FOUND. Asserted
# as an absence on the degraded path: printing it over an empty list is the
# false negative itself.
FOUND_HEADER='Possible contradiction in the memory this touches'

# THE LOAD-BEARING FIXTURE: the leg timed out, so `contradictions` is empty
# because nothing ran — not because nothing was found.
DEGRADED='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[],"degraded":["contradictions"]}'

# Same degradation, with past decisions present: the skipped line must be added
# to the other blocks, not substituted for them.
DEGRADED_WITH_DECISIONS='{"proposed_answer":null,"unmapped_top_choice":null,"count":1,"reasoning":"1 similar","past_decisions":[{"question":"worktree or inline?","chosen":"Isolated worktree","rationale":"branch isolation"}],"contradictions":[],"degraded":["contradictions"]}'

# A healthy 200 that matched nothing. No `degraded` key at all — the older
# server, and every non-degraded response today.
NO_VIEW='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[]}'

# The two shapes that are present-but-not-degraded.
DEGRADED_EMPTY='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[],"degraded":[]}'
DEGRADED_NULL='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[],"degraded":null}'

# A real contradiction, undegraded: the existing render must not change.
REAL_CONTRADICTION='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[{"key":"a|b","rationale":"you chose X on Monday and not-X on Friday"}]}'

# Degraded AND carrying findings. The server cannot send this today — a
# timed-out leg returns `[]` — so it is asserted precisely because it is the
# shape where the two branches could fight: a skip notice printed INSTEAD of
# real findings would drop the findings, which is worse than the defect being
# fixed here.
DEGRADED_WITH_FINDINGS='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[{"key":"c|d","rationale":"you chose Y in June and not-Y in July"}],"degraded":["contradictions"]}'

echo "── a skipped contradictions leg is SAID, never rendered as empty ──"
run "$DEGRADED"
if [ -n "$CTX" ]; then
  pass "a degraded response injects context at all"
else
  fail "a degraded response must not inject nothing — nothing reads as 'no contradictions'" "ctx='$CTX'"
fi
if grep -qiE "skipped|did not run|never ran" <<<"$CTX"; then
  pass "says the lookup was skipped"
else
  fail "must say the contradiction lookup was SKIPPED" "ctx='$CTX'"
fi
if grep -qi "contradiction" <<<"$CTX"; then
  pass "names which lookup was skipped"
else
  fail "must name the contradiction lookup" "ctx='$CTX'"
fi
# The cause is NOT asserted, and that is the assertion. `ConcurrentLegs` reports
# a leg as degraded when it misses its deadline and when it RAISES — a failed
# database query arrives identically — and the response body does not say which.
# A notice naming a timeout points the reader's diagnosis at one of two causes
# on evidence that cannot tell them apart (Greptile P2 on #8788).
if grep -qiE "timed out|timeout|deadline|exceeded" <<<"$CTX"; then
  fail "must not name a cause the response does not supply" "ctx='$CTX'"
else
  pass "asserts no cause — degraded covers a timeout and a raised failure alike"
fi
if grep -qiE "missing result|no usable result" <<<"$CTX"; then
  pass "says the result is missing rather than empty"
else
  fail "must distinguish a missing result from an empty one" "ctx='$CTX'"
fi
if grep -qF "$FOUND_HEADER" <<<"$CTX"; then
  fail "must NOT print the contradictions-found header over an empty list" "ctx='$CTX'"
else
  pass "does not print the found-header over an empty list"
fi

echo
echo "── a degraded response is NOT logged as a clean success ──"
run "$DEGRADED"
if grep -q 'recall_degraded' <<<"$(reasons)"; then
  pass "recorded as recall_degraded in the supply ledger"
else
  fail "a degraded call must be counted as a miss (MOL-9571's ledger)" \
    "reasons='$(reasons)'" "latency='$(latency)'"
fi
if grep -q 'recall_ok' <<<"$(latency)"; then
  fail "a degraded call must NOT be written as recall_ok" "latency='$(latency)'"
else
  pass "not written as recall_ok"
fi
# It answered. Reporting it as unreachable would say the rail was down, which is
# a different fault with a different fix.
if grep -q 'recall_unreachable' <<<"$(reasons)"; then
  fail "a degraded 200 must not be recorded as unreachable — the rail answered" \
    "reasons='$(reasons)'"
else
  pass "not recorded as unreachable"
fi

echo
echo "── the skipped line is ADDED to the other blocks, not substituted ──"
run "$DEGRADED_WITH_DECISIONS"
if grep -q "worktree or inline?" <<<"$CTX"; then
  pass "past decisions still rendered beside the skipped line"
else
  fail "past decisions must still render on a degraded turn" "ctx='$CTX'"
fi
if grep -qiE "skipped|did not run|never ran" <<<"$CTX"; then
  pass "skipped line present alongside them"
else
  fail "skipped line must still be present" "ctx='$CTX'"
fi

echo
echo "── an undegraded response behaves exactly as it does today ──"
run "$NO_VIEW"
if [ -z "$CTX" ]; then
  pass "no degraded key ⇒ an empty corpus still injects nothing"
else
  fail "a response with no degraded key must render as it does today" "ctx='$CTX'"
fi
if grep -q 'recall_ok' <<<"$(latency)"; then
  pass "no degraded key ⇒ still logged recall_ok"
else
  fail "an undegraded 200 must still be logged as a success" "latency='$(latency)'"
fi
if grep -q 'recall_degraded' <<<"$(reasons)"; then
  fail "an undegraded 200 must NOT be counted as degraded" "reasons='$(reasons)'"
else
  pass "no degraded key ⇒ not counted as degraded"
fi

run "$DEGRADED_EMPTY"
if [ -z "$CTX" ] && ! grep -q 'recall_degraded' <<<"$(reasons)"; then
  pass "degraded: [] ⇒ unchanged behaviour"
else
  fail "an empty degraded list means nothing was degraded" "ctx='$CTX'" "reasons='$(reasons)'"
fi

run "$DEGRADED_NULL"
if [ -z "$CTX" ] && ! grep -q 'recall_degraded' <<<"$(reasons)"; then
  pass "degraded: null ⇒ unchanged behaviour"
else
  fail "a null degraded field means nothing was degraded" "ctx='$CTX'" "reasons='$(reasons)'"
fi

echo
echo "── a real contradiction still renders as it does today ──"
run "$REAL_CONTRADICTION"
if grep -qF "$FOUND_HEADER" <<<"$CTX"; then
  pass "found-header still printed for a real contradiction"
else
  fail "an undegraded contradiction must still render" "ctx='$CTX'"
fi
if grep -q "you chose X on Monday" <<<"$CTX"; then
  pass "the contradiction's rationale is still shown"
else
  fail "the rationale must still be shown" "ctx='$CTX'"
fi
if grep -qiE "skipped|did not run" <<<"$CTX"; then
  fail "must not claim a skip when the leg ran" "ctx='$CTX'"
else
  pass "no skipped line when the leg ran"
fi

echo
echo "── a degraded field of an unreadable SHAPE is counted, not ignored ──"
# A server that shipped `degraded` as a map of leg → reason would restore the
# original defect silently: a half-answer recorded as `recall_ok` again. So a
# present-but-unreadable field is counted as a miss with unknown legs. No notice
# is rendered — which lookup is missing cannot be read from it.
for shape in '"contradictions"' '{"contradictions":"timeout"}' '[null]' '[7]'; do
  run "{\"proposed_answer\":null,\"unmapped_top_choice\":null,\"count\":0,\"reasoning\":\"x\",\"past_decisions\":[],\"contradictions\":[],\"degraded\":${shape}}"
  if grep -q 'recall_degraded:unknown_shape' <<<"$(reasons)"; then
    pass "degraded: ${shape} ⇒ counted as unknown_shape"
  else
    fail "an unreadable degraded field must still be counted" "shape=${shape}" "reasons='$(reasons)'"
  fi
  if grep -q 'recall_ok' <<<"$(latency)"; then
    fail "an unreadable degraded field must not be logged as a clean success" "shape=${shape}" "latency='$(latency)'"
  else
    pass "degraded: ${shape} ⇒ not logged recall_ok"
  fi
  if [ -z "$CTX" ]; then
    pass "degraded: ${shape} ⇒ no notice claimed about an unknown leg"
  else
    fail "must not name a skipped lookup it cannot identify" "shape=${shape}" "ctx='$CTX'"
  fi
done

echo
echo "── findings outrank the skip notice if both ever arrive together ──"
run "$DEGRADED_WITH_FINDINGS"
if grep -q "you chose Y in June" <<<"$CTX"; then
  pass "real findings are still shown on a degraded response"
else
  fail "a skip notice must never be printed INSTEAD of findings" "ctx='$CTX'"
fi
# Still counted as degraded: the server said a leg was missing, and that is a
# fact about the call rather than about what came back.
if grep -q 'recall_degraded' <<<"$(reasons)"; then
  pass "still counted as degraded in the ledger"
else
  fail "a degraded response must be counted even when it carries findings" "reasons='$(reasons)'"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
