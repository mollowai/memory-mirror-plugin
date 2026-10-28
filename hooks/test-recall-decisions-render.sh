#!/usr/bin/env bash
# Tests for what recall-decisions.sh actually SHOWS the model.
#
# This hook fires on every UserPromptSubmit — the highest-volume rail in the
# product — and the server computes a full proposal for it: `proposed_answer`
# with a `confidence`, plus `unmapped_top_choice` for the case where the nearest
# past decision maps onto none of the offered options.
#
# All of that was discarded. The hook rendered `past_decisions` and
# `contradictions` only, under the instruction "propose answers consistent with
# these unless the user signals otherwise". So on the one rail that runs every
# turn, the model received a bare list of past choices with no confidence and no
# proposal — relocating the very failure `DecisionRecall`'s moduledoc was written
# to prevent (a nearest neighbour read as an answer) from the server into this
# hook's jq.
#
# Three properties are tested:
#
#   1. A proposal is shown WITH its confidence, attributed to Engram, so the
#      model can tell "I have seen you decide this" from "I found something
#      nearby".
#   2. `unmapped_top_choice` is shown as explicitly NOT an answer. The server
#      went to deliberate trouble to distinguish it; rendering it as a
#      recommendation here would undo that.
#   3. The blanket "propose answers consistent with these" instruction no longer
#      stands alone, because it is what collapses a model/Engram disagreement
#      into one recommendation — the disagreement being the highest-value thing
#      a sweep can surface.
#
# The response is stubbed through a fake `curl` on PATH, so what is asserted is
# the hook's real output rather than a reimplementation of its jq.
#
# Run: bash plugins/memory-mirror/hooks/test-recall-decisions-render.sh

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-recall-render-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
# A real repo, so the proposal stash has a root to resolve (it is written beside
# the sweep receipt, at <repo root>/tmp/).
( cd "$TMP/repo" && git init -q . ) >/dev/null 2>&1

# run <response-json> — stub the server reply, return the emitted context in CTX.
run() {
  printf '%s' "$1" > "$TMP/response.json"
  cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
# MM_FAIL_RECALL stands in for a recall that never answered (timeout, server
# down) — the hook sees empty output and a nonzero status, exactly as it would
# from the real `mm_post_read` budget expiring.
[ -n "${MM_FAIL_RECALL:-}" ] && exit 7
cat "$MM_FAKE_RESPONSE"
EOF
  chmod +x "$TMP/bin/curl"

  local out
  out="$(
    printf '%s' "{\"hook_event_name\":\"UserPromptSubmit\",\"prompt\":\"where should this work happen?\",\"cwd\":\"$TMP/repo\",\"session_id\":\"s1\"}" \
      | env -i \
        PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$TMP" \
        MM_FAKE_RESPONSE="$TMP/response.json" \
        MOLLOW_MEMORY_API_KEY="mol_test" \
        MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2" \
        MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
        ${MM_FAIL_RECALL:+MM_FAIL_RECALL=1} \
        bash "$HOOK" 2>/dev/null
  )" || true

  CTX="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")"
}

PROPOSED='{"proposed_answer":{"option":"Isolated worktree","confidence":0.774},"unmapped_top_choice":null,"count":5,"reasoning":"5 similar past decisions","past_decisions":[{"question":"worktree or inline?","chosen":"Isolated worktree","rationale":"branch isolation"}],"contradictions":[]}'

UNMAPPED='{"proposed_answer":null,"unmapped_top_choice":"Just implement now","count":3,"reasoning":"3 nearby","past_decisions":[{"question":"which lane first?","chosen":"Just implement now","rationale":null}],"contradictions":[]}'

NO_VIEW='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"reasoning":"no decisions","past_decisions":[],"contradictions":[]}'

echo "── a proposal is shown with its confidence ──"
run "$PROPOSED"
if grep -q "Isolated worktree" <<<"$CTX"; then pass "names the proposed option"; else fail "names the proposed option" "$CTX"; fi
if grep -q "0.774" <<<"$CTX"; then pass "carries the confidence"; else fail "carries the confidence — a proposal without one cannot be weighed" "$CTX"; fi
if grep -qi "engram" <<<"$CTX"; then pass "attributes the proposal to Engram"; else fail "attributes the proposal to Engram" "$CTX"; fi
# `count` lives on the ROOT of the recall response, not inside
# `proposed_answer` — `build_response/2` returns
# %{proposed_answer:, unmapped_top_choice:, past_decisions:, count:, reasoning:}
# and `proposed_answer` is %{option, confidence} only. So `.count` is right and
# `$p.count` would always be null, which would silently drop this clause for
# every proposal. Reviewed as CR-A-r1-001 on PR #7496 and declined on this
# evidence; asserted here so the decline cannot rot into a real bug.
if grep -q "from 5 similar past decisions" <<<"$CTX"; then pass "renders the supporting count from the response root"; else fail "renders the supporting count from the response root" "$CTX"; fi

echo "── an unmapped top choice is shown as NOT an answer ──"
run "$UNMAPPED"
if grep -q "Just implement now" <<<"$CTX"; then pass "names the nearest prior"; else fail "names the nearest prior" "$CTX"; fi
if grep -qiE "not an answer|different question|no usable view" <<<"$CTX"; then pass "says it is not an answer"; else fail "says it is not an answer — otherwise it reads as a recommendation" "$CTX"; fi
if grep -qiE "engram (proposes|recommends|suggests)" <<<"$CTX"; then fail "must NOT present an unmapped choice as a proposal" "$CTX"; else pass "does not present it as a proposal"; fi

echo "── the blanket consistency instruction no longer stands alone ──"
run "$PROPOSED"
if grep -q "propose answers consistent with these unless the user signals otherwise" <<<"$CTX"; then
  fail "the unqualified instruction is gone" "it collapses a model/Engram disagreement into one recommendation" "$CTX"
else
  pass "the unqualified instruction is gone"
fi
if grep -qiE "disagree" <<<"$CTX"; then pass "tells the reader what to do when the two voices disagree"; else fail "tells the reader what to do when the two voices disagree" "$CTX"; fi

echo "── past decisions are still shown ──"
run "$PROPOSED"
if grep -q "worktree or inline?" <<<"$CTX"; then pass "past decisions still rendered"; else fail "past decisions still rendered" "$CTX"; fi

echo "── no view emits nothing ──"
run "$NO_VIEW"
if [ -z "$CTX" ]; then pass "an empty corpus injects no context"; else fail "an empty corpus injects no context" "$CTX"; fi

echo "── the proposal is STASHED for the answer-time capture ──"
# capture-decision.sh cannot call recall itself: it runs on PostToolUse with a
# 6s budget and the recall already happened this turn. So the proposal we
# already fetched is stashed here and read there. Without this, the only
# calibration signal we have — did the operator pick what Engram proposed, at
# what confidence — is discarded on every prompt.
rm -f "$TMP/repo/tmp/.engram-proposal-s1.json"
run "$PROPOSED"
STASH="$TMP/repo/tmp/.engram-proposal-s1.json"
if [ -f "$STASH" ]; then pass "a proposal writes the stash"; else fail "a proposal writes the stash" "$(ls -la "$TMP/repo/tmp" 2>&1)"; fi
if [ -f "$STASH" ] && [ "$(jq -r '.option' "$STASH" 2>/dev/null)" = "Isolated worktree" ]; then pass "stash carries the option"; else fail "stash carries the option" "$(cat "$STASH" 2>/dev/null)"; fi
if [ -f "$STASH" ] && [ "$(jq -r '.confidence' "$STASH" 2>/dev/null)" = "0.774" ]; then pass "stash carries the confidence"; else fail "stash carries the confidence" "$(cat "$STASH" 2>/dev/null)"; fi

echo "── no proposal writes NO stash (absent must not read as agreement) ──"
rm -f "$STASH"
run "$UNMAPPED"
if [ -f "$STASH" ]; then fail "an unmapped choice must not be stashed as a proposal" "$(cat "$STASH")"; else pass "unmapped ⇒ no stash"; fi
rm -f "$STASH"
run "$NO_VIEW"
if [ -f "$STASH" ]; then fail "no view must not be stashed" "$(cat "$STASH")"; else pass "no view ⇒ no stash"; fi

echo "── a later prompt with no proposal CLEARS the previous one's stash ──"
# The staleness case, and the reason the stash is cleared before the recall
# rather than written after it. Every early exit in this hook — an empty prompt,
# a malformed body, a recall that times out — is upstream of the write. So
# without an up-front clear, turn 2's card reads turn 1's proposal as a proposal
# about its own question: a well-formed, fresh-looking file about a different
# prompt. That is the exact false attribution the per-question scoping rule
# exists to prevent, arriving through the filesystem instead.
run "$PROPOSED"
[ -f "$STASH" ] || fail "setup: turn 1 must leave a stash"
run "$NO_VIEW"
if [ -f "$STASH" ]; then
  fail "a no-proposal turn must clear the stale stash" "$(cat "$STASH")"
else
  pass "no-proposal turn ⇒ stale stash cleared"
fi

run "$PROPOSED"
[ -f "$STASH" ] || fail "setup: turn 1 must leave a stash (timeout case)"
MM_FAIL_RECALL=1
run "$PROPOSED"
unset MM_FAIL_RECALL
if [ -f "$STASH" ]; then
  fail "a turn whose recall never answered must not leave the previous proposal" "$(cat "$STASH")"
else
  pass "unreachable recall ⇒ stale stash cleared (the write is never reached)"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
