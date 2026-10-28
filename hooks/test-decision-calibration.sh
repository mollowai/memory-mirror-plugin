#!/usr/bin/env bash
# Tests for the per-answer calibration signal capture-decision.sh attaches.
#
# ## What this signal is, and why it did not exist
#
# `DecisionRecall.confidence/2` weights relevance 0.6, agreement 0.3 and corpus
# count 0.1, and `/ask-first` auto-assumes an answer above a threshold. Those
# four numbers were chosen by hand and could never move on evidence, because the
# one fact that would validate them was computed and thrown away on every single
# prompt: Engram proposed option X at confidence C, and then the operator picked
# something — and nobody recorded whether it was X.
#
# `recall-decisions.sh` fetches that proposal on every UserPromptSubmit. It now
# stashes it; this hook reads it back at answer time and records the pair. With
# enough pairs the threshold becomes measurable instead of asserted: the rate at
# which a 0.85 proposal was actually chosen IS the thing 0.85 is guessing at.
#
# ## The false-attribution rule these tests mostly exist to pin
#
# The stash is PROMPT-scoped. `recall-decisions.sh` calls recall with the whole
# user prompt as the question, so the proposal answers "what would this operator
# pick, in a situation like this prompt" — not "what would they pick for
# question 3 of this 4-question card".
#
# So on a multi-question card the proposal is NOT that question's proposal, and
# attaching it to each question as though it were would fabricate up to N-1
# agreement facts from one prompt-level guess. That is the same error as reading
# `unmapped_top_choice` as an answer, one layer out, and it would poison the
# exact dataset this signal exists to produce — the calibration would be
# measured against questions Engram was never asked.
#
# Hence: `agreed_with_engram` is recorded ONLY for a single-question card, where
# the prompt-level proposal is a fair proxy for the one question asked, and the
# recorded data carries `engram_scope: "prompt"` so no later reader can mistake
# it for per-question calibration.
#
# Posts go through a fake `curl` on PATH, so what is asserted is the real request
# body rather than a reimplementation of the hook's jq.
#
# Run: bash plugins/memory-mirror/hooks/test-decision-calibration.sh

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

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-calib-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
( cd "$TMP/repo" && git init -q . ) >/dev/null 2>&1

cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
EOF
chmod +x "$TMP/bin/curl"

SID="s-1"
STASH="$TMP/repo/tmp/.engram-proposal-${SID}.json"
RECEIPT="$TMP/repo/tmp/.question-sweep-${SID}.json"

stash() {
  mkdir -p "$TMP/repo/tmp"
  if [ -z "$1" ]; then rm -f "$STASH"; else printf '%s' "$1" > "$STASH"; fi
}

# run <payload> → POSTS (count), LOG (raw), BODIES (one json per line).
# The session id travels inside the payload, which is how the traversing-id case
# is exercised.
run() {
  : > "$TMP/curl.log"
  ERR="$(
    printf '%s' "$1" | env -i \
      PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
      HOME="$TMP" \
      CURL_LOG="$TMP/curl.log" \
      MOLLOW_MEMORY_API_KEY="mol_test" \
      MOLLOW_MEMORY_URL="http://localhost:1/mcp/v2" \
      MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
      bash "$HOOK" 2>&1 >/dev/null
  )" || true
  POSTS="$(grep -c '/api/memory/decisions' "$TMP/curl.log" || true)"
  LOG="$(cat "$TMP/curl.log")"
  # The fake logs the whole argv; the body is the -d argument. Pull every
  # JSON object out so each post can be asserted on independently.
  BODIES="$(grep -oE '\{.*\}' "$TMP/curl.log" || true)"
}

# body_for <question> — the posted body whose .question matches, or empty.
body_for() {
  printf '%s\n' "$BODIES" | while IFS= read -r b; do
    [ -z "$b" ] && continue
    if [ "$(printf '%s' "$b" | jq -r '.question // empty' 2>/dev/null)" = "$1" ]; then
      printf '%s' "$b"
      return 0
    fi
  done
}

one_question() {
  jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" --arg chosen "$1" '{
    cwd: $cwd,
    session_id: $sid,
    tool_input: {questions: [
      {question: "Where should the work happen?",
       options: [{label: "Isolated worktree"}, {label: "Inline on main"}]}
    ]},
    tool_response: ("Your questions have been answered: \"Where should the work happen?\"=\"" + $chosen + "\". You can now continue.")
  }'
}

TWO_QUESTIONS="$(jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" '{
  cwd: $cwd,
  session_id: $sid,
  tool_input: {questions: [
    {question: "Where should the work happen?",
     options: [{label: "Isolated worktree"}, {label: "Inline on main"}]},
    {question: "Which lane first?",
     options: [{label: "Signal fix"}, {label: "Release"}]}
  ]},
  tool_response: "Your questions have been answered: \"Where should the work happen?\"=\"Isolated worktree\", \"Which lane first?\"=\"Signal fix\". You can now continue."
}')"

PROPOSAL='{"option":"Isolated worktree","confidence":0.774,"count":5}'

echo "── fixture: a post happens at all ──"
# If this fails every "field absent" assertion below passes vacuously.
stash ""
rm -f "$RECEIPT"
run "$(one_question 'Isolated worktree')"
if [ "$POSTS" = "1" ]; then pass "one question ⇒ one post"; else fail "one question ⇒ one post" "posts=$POSTS" "$ERR"; fi
if [ -n "$BODIES" ]; then pass "the body is observable"; else fail "the body is observable" "$LOG"; fi

echo "── with no stash, no calibration fields are invented ──"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // "ABSENT"')" = "ABSENT" ]; then
  pass "no stash ⇒ engram_proposed absent"
else
  fail "no stash ⇒ engram_proposed absent" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // "ABSENT"')" = "ABSENT" ]; then
  pass "no stash ⇒ agreed_with_engram absent (absent must not read as disagreement)"
else
  fail "no stash ⇒ agreed_with_engram absent" "$B"
fi

echo "── the operator PICKED what Engram proposed ──"
stash "$PROPOSAL"
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Isolated worktree" ]; then
  pass "records what Engram proposed"
else
  fail "records what Engram proposed" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed_confidence // ""')" = "0.774" ]; then
  pass "records the confidence it was proposed AT — the number being calibrated"
else
  fail "records the confidence" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // "ABSENT"')" = "true" ]; then
  pass "agreement recorded as true"
else
  fail "agreement recorded as true" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_scope // ""')" = "prompt" ]; then
  pass "carries engram_scope=prompt, so nobody reads it as per-question calibration"
else
  fail "carries engram_scope=prompt" "$B"
fi

echo "── the operator went AGAINST Engram ──"
# The high-value row. `jq`'s `//` treats false exactly like absent, so a
# disagreement is the value most easily lost on the way out — and it is the only
# one that can ever lower a confidence weight. Asserted with has(), not `//`.
stash "$PROPOSAL"
run "$(one_question 'Inline on main')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "a disagreement is recorded as false, not dropped"
else
  fail "a disagreement is recorded as false, not dropped" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Isolated worktree" ]; then
  pass "still records what was proposed, so the miss is attributable"
else
  fail "still records what was proposed" "$B"
fi

echo "── a MULTI-question card records NO agreement ──"
# The false-attribution rule. The stash is prompt-scoped; attaching it to each
# of two questions would manufacture a second agreement fact from one guess.
stash "$PROPOSAL"
run "$TWO_QUESTIONS"
if [ "$POSTS" = "2" ]; then pass "two questions ⇒ two posts"; else fail "two questions ⇒ two posts" "posts=$POSTS" "$LOG"; fi
multi_clean=true
for q in "Where should the work happen?" "Which lane first?"; do
  B="$(body_for "$q")"
  for f in engram_proposed engram_proposed_confidence agreed_with_engram engram_scope; do
    if [ "$(printf '%s' "$B" | jq -r "if (.sweep // {} | has(\"$f\")) then \"PRESENT\" else \"ABSENT\" end" 2>/dev/null)" = "PRESENT" ]; then
      fail "multi-question card must not carry $f (on \"$q\")" "$B"
      multi_clean=false
    fi
  done
done
[ "$multi_clean" = true ] && pass "no calibration field is attached to either question of a 2-question card"

echo "── a SECOND card in the same turn gets nothing ──"
# The single-question guard is INTRA-card and bounds nothing across cards.
# AskUserQuestion is a tool, so the model can raise several cards inside ONE
# turn with no UserPromptSubmit between them — and the stash is cleared per
# PROMPT, not per card. Without consuming it on read, every later card in the
# turn reads the same prompt-level proposal and records a verdict on a question
# the proposal never addressed. That is the exact error the single-question
# guard exists to prevent, redistributed across cards instead of within one.
stash "$PROPOSAL"
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "setup: the first card records the agreement"
else
  fail "setup: the first card records the agreement" "$B"
fi
# Same turn, second card. Its options DO contain the proposal's label, so the
# membership test below cannot be what saves this case — only consumption can.
run "$(one_question 'Inline on main')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "the second card in one turn records no verdict (the stash is consumed)"
else
  fail "the second card in one turn records no verdict" "$B"
fi

echo "── a card whose options do not contain the proposal gets nothing ──"
# Re-manufacturing `unmapped_top_choice`. recall-decisions.sh deliberately
# refuses to stash a nearest-neighbour that maps onto none of the options,
# because that is "Engram has no usable view". If the reader attaches a proposal
# to a card whose options do not include it, the chosen answer can never equal
# it, so it is recorded as a DISAGREEMENT — fabricating the very "no view"
# case the writer was careful to exclude, with the opposite sign.
stash "$PROPOSAL"
UNRELATED="$(jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" '{
  cwd: $cwd, session_id: $sid,
  tool_input: {questions: [
    {question: "Which region for the new bucket?",
     options: [{label: "europe-west4"}, {label: "us-central1"}]}
  ]},
  tool_response: "Your questions have been answered: \"Which region for the new bucket?\"=\"europe-west4\". You can now continue."
}')"
run "$UNRELATED"
B="$(body_for 'Which region for the new bucket?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "a proposal absent from the card's own options records nothing"
else
  fail "a proposal absent from the card's options must record nothing, not a disagreement" "$B"
fi
# And it must NOT have consumed the stash: an unrelated card appearing first in
# the turn would otherwise swallow the proposal that belongs to a later one.
if [ -f "$STASH" ]; then
  pass "a non-matching card leaves the stash for the card it belongs to"
else
  fail "a non-matching card must not consume the stash" "stash gone"
fi
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "the card the proposal fits still gets it, whatever the card order"
else
  fail "the card the proposal fits still gets it" "$B"
fi

echo "── the receipt's own sweep fields survive alongside ──"
# `sweep` already carries axis/tier/model_recommendation from the question-sweep
# receipt. The calibration fields are merged into the same object, and merging
# must not drop what was there — these are different signals (one is about the
# MODEL's recommendation, one about ENGRAM's).
stash "$PROPOSAL"
cat > "$RECEIPT" <<'EOF'
{"questions":[{"question":"Where should the work happen?","axis":"execution shape","tier":"asked","engram_confidence":0.42,"model_recommendation":"Inline on main","agreed_with_model":false,"round":1}],
 "axes":["execution shape"],"rounds":[{"round":1}]}
EOF
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.axis // ""')" = "execution shape" ]; then
  pass "the receipt's axis survives the merge"
else
  fail "the receipt's axis survives the merge" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep|has("agreed_with_model")) then (.sweep.agreed_with_model|tostring) else "ABSENT" end')" = "false" ]; then
  pass "the receipt's agreed_with_model survives (and stays false)"
else
  fail "the receipt's agreed_with_model survives" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "both signals coexist — the model was disagreed with, Engram was agreed with"
else
  fail "both signals coexist" "$B"
fi
# The name collision, asserted. The receipt's `engram_confidence` is Engram's
# confidence for THIS QUESTION, measured by /ask-first's own batch recall — the
# better of the two numbers, because it is per-question rather than per-prompt.
# Writing the stash's prompt-level confidence under that same key would
# overwrite it with the weaker one, silently, and every later reader would
# believe it had per-question data. Hence two distinct keys.
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_confidence // ""')" = "0.42" ]; then
  pass "the receipt's per-question engram_confidence is NOT overwritten by the prompt-level one"
else
  fail "the receipt's per-question engram_confidence survives" "$B"
fi
rm -f "$RECEIPT"

echo "── PER-QUESTION calibration: a multi-question card DOES get verdicts ──"
# The prompt-scoped rail above is a fallback, and a weak one: it covers only
# single-question cards, which is the minority of what /ask-first raises. The
# receipt is the strong rail. Phase 3 already runs a batch recall PER QUESTION,
# so it holds a proposal for each one — it just never recorded which option that
# proposal named, only its confidence. With `engram_proposed` in the entry,
# agreement is computable for a card of any size, and the attribution is exact
# rather than a proxy: `engram_scope` says "question", not "prompt".
#
# One true and one false in the same card, because a rail that can only express
# agreement is not calibration.
stash ""
cat > "$RECEIPT" <<'EOF'
{"questions":[
  {"question":"Where should the work happen?","axis":"execution shape","tier":"asked",
   "engram_proposed":"Isolated worktree","engram_confidence":0.81,"round":1},
  {"question":"Which lane first?","axis":"sequencing","tier":"asked",
   "engram_proposed":"Release","engram_confidence":0.64,"round":1}
],"axes":["execution shape","sequencing"],"rounds":[{"round":1}]}
EOF
run "$TWO_QUESTIONS"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_scope // ""')" = "question" ]; then
  pass "a multi-question card is scoped per QUESTION, not per prompt"
else
  fail "a multi-question card is scoped per question" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "Q1 agreement (chose the proposed option)"
else
  fail "Q1 agreement" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed_confidence // ""')" = "0.81" ]; then
  pass "Q1 carries ITS OWN confidence, from the receipt"
else
  fail "Q1 carries its own confidence" "$B"
fi
B2="$(body_for 'Which lane first?')"
if [ "$(printf '%s' "$B2" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "Q2 DISAGREEMENT recorded in the same card — proposed Release, chose Signal fix"
else
  fail "Q2 disagreement recorded in the same card" "$B2"
fi
if [ "$(printf '%s' "$B2" | jq -r '.sweep.engram_proposed_confidence // ""')" = "0.64" ]; then
  pass "Q2 carries its own distinct confidence, not Q1's"
else
  fail "Q2 carries its own distinct confidence" "$B2"
fi

echo "── an ASSUMED question's verdict stays distinguishable from a blind choice ──"
# The one case that could silently inflate the agreement rate beyond repair.
# /ask-first AUTO-ASSUMES an answer above the threshold, taking Engram's own
# proposal as the answer — so for an assumed question `chosen == engram_proposed`
# by construction. If a Phase 6 confirm card then re-asks it, the resulting
# `agreed_with_engram: true` is a CONFIRMATION of something the operator was
# shown, not an independent choice, and the two are worth very different
# amounts: one is corroboration under anchoring, the other is evidence.
#
# Pooled, they would drive the measured rate up and the threshold with it —
# auto-assuming more on the strength of having auto-assumed. `tier` travels on
# the same row so a reader can separate them; this asserts it survives, because
# nothing else would notice if it stopped.
stash ""
cat > "$RECEIPT" <<'EOF'
{"questions":[{"question":"Where should the work happen?","tier":"assumed",
  "engram_proposed":"Isolated worktree","engram_confidence":0.93,"round":1}],
 "axes":["execution shape"],"rounds":[{"round":1}]}
EOF
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "setup: an assumed-then-confirmed question records agreement"
else
  fail "setup: assumed-then-confirmed records agreement" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.tier // ""')" = "assumed" ]; then
  pass "tier=assumed travels on the row, so a confirmation is not pooled with a blind choice"
else
  fail "tier must travel with the calibration row" "$B"
fi

echo "── the receipt's per-question proposal BEATS the prompt stash ──"
# When both rails have something to say, the per-question one is strictly better
# evidence and must win. Otherwise the weaker proxy silently overwrites the
# stronger measurement on exactly the cards /ask-first raises.
stash "$PROPOSAL"
cat > "$RECEIPT" <<'EOF'
{"questions":[{"question":"Where should the work happen?","tier":"asked",
  "engram_proposed":"Inline on main","engram_confidence":0.55,"round":1}],
 "axes":["execution shape"],"rounds":[{"round":1}]}
EOF
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_scope // ""')" = "question" ]; then
  pass "the per-question rail wins"
else
  fail "the per-question rail wins over the prompt stash" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Inline on main" ]; then
  pass "the recorded proposal is the receipt's, not the stash's"
else
  fail "the recorded proposal is the receipt's" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "agreement is computed against the receipt's proposal"
else
  fail "agreement is computed against the receipt's proposal" "$B"
fi
if [ -f "$STASH" ]; then
  pass "the unused stash is left for a card the receipt does not cover"
else
  fail "an unused stash must not be consumed" "stash gone"
fi

echo "── a receipt entry with no proposal falls back, and never invents one ──"
stash "$PROPOSAL"
cat > "$RECEIPT" <<'EOF'
{"questions":[{"question":"Where should the work happen?","axis":"execution shape",
  "tier":"asked","engram_confidence":0.42,"round":1}],
 "axes":["execution shape"],"rounds":[{"round":1}]}
EOF
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_scope // ""')" = "prompt" ]; then
  pass "a confidence with no named option falls back to the prompt rail"
else
  fail "falls back to the prompt rail" "$B"
fi
# The receipt's own per-question confidence must survive that fallback — it is a
# different number from the stash's, and the better one.
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_confidence // ""')" = "0.42" ]; then
  pass "the receipt's per-question confidence is still carried"
else
  fail "the receipt's per-question confidence is still carried" "$B"
fi

echo "── a per-question proposal absent from that question's options yields no verdict ──"
# The `unmapped_top_choice` case again, now at question granularity: a receipt
# entry can name an option the card no longer offers. No verdict for that
# question; its SIBLING is unaffected, so one stale entry cannot silence a card.
stash ""
cat > "$RECEIPT" <<'EOF'
{"questions":[
  {"question":"Where should the work happen?","tier":"asked",
   "engram_proposed":"A third option nobody offered","engram_confidence":0.7,"round":1},
  {"question":"Which lane first?","tier":"asked",
   "engram_proposed":"Signal fix","engram_confidence":0.77,"round":1}
],"axes":["x"],"rounds":[{"round":1}]}
EOF
run "$TWO_QUESTIONS"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "an unofferable proposal records no verdict"
else
  fail "an unofferable proposal must record no verdict, not a disagreement" "$B"
fi
B2="$(body_for 'Which lane first?')"
if [ "$(printf '%s' "$B2" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "the sibling question still gets its verdict"
else
  fail "one stale entry must not silence the whole card" "$B2"
fi
rm -f "$RECEIPT"

echo "── a multiSelect card records NO verdict ──"
# Greptile P1 on PR #7522, CONFIRMED against real transcripts: a multiSelect
# answer renders as a COMMA-JOINED list of labels —
#   "…which blind spots matter most…"="Verification + dispatch health, Infra drift, Work drain, Capacity truth"
# so comparing a single proposed option to `chosen` yields a guaranteed `false`
# even when the proposal was among the things selected. The option-membership
# guard cannot catch it either: that tests the PROPOSAL's membership, not the
# answer's, and the proposal is a real label.
#
# Skipped rather than scored, because agreement has no defined meaning here:
# "selected alongside three others" is neither the agreement nor the
# disagreement this dataset is counting. Both rails are checked, since the
# receipt rail would otherwise walk straight into the same comparison.
stash "$PROPOSAL"
cat > "$RECEIPT" <<'EOF'
{"questions":[{"question":"Which surfaces?","tier":"asked",
  "engram_proposed":"Isolated worktree","engram_confidence":0.8,"round":1}],
 "axes":["x"],"rounds":[{"round":1}]}
EOF
MULTI="$(jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" '{
  cwd: $cwd, session_id: $sid,
  tool_input: {questions: [
    {question: "Which surfaces?", multiSelect: true,
     options: [{label: "Isolated worktree"}, {label: "Inline on main"}]}
  ]},
  tool_response: "Your questions have been answered: \"Which surfaces?\"=\"Isolated worktree, Inline on main\". You can now continue."
}')"
run "$MULTI"
B="$(body_for 'Which surfaces?')"
if [ "$POSTS" = "1" ]; then pass "the decision itself is still recorded"; else fail "the decision itself is still recorded" "posts=$POSTS" "$ERR"; fi
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "multiSelect ⇒ no verdict on either rail"
else
  fail "a multiSelect card must record no verdict" "$B"
fi
if [ -f "$STASH" ]; then
  pass "multiSelect ⇒ the stash is not consumed either"
else
  fail "multiSelect must not consume the stash" "stash gone"
fi
rm -f "$RECEIPT"

echo "── the (Recommended) suffix does not read as a disagreement ──"
# Also from the real transcripts: a rendered answer carries the suffix the model
# wrote into the label — ="Regression detector (Recommended)" — while a stored
# decision from an occasion when that option was NOT recommended carries the
# bare text. Exact equality then reports a disagreement for the same choice, and
# the bias runs the same way as the dedup bug: spurious disagreements, rate too
# low, threshold driven down.
#
# Resolved with the repo's OWN rule rather than a second one invented here:
# `DecisionRecall.map_to_candidate_option/2` maps a historical label into the
# caller's option space by case-insensitive containment in either direction, and
# its docstring names this exact pair. The proposal is mapped into the card's
# options first, then compared there — so both sides are in the card's own
# vocabulary and the suffix cannot matter.
stash '{"option":"Isolated worktree (Recommended)","confidence":0.74}'
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "a suffixed proposal against a bare label is agreement, not disagreement"
else
  fail "a suffixed proposal must resolve to the bare label" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Isolated worktree" ]; then
  pass "the recorded proposal is in the CARD's vocabulary, so the dedup key is stable"
else
  fail "the recorded proposal is normalised into the card's vocabulary" "$B"
fi

# And the mirror case: the CARD carries the suffix, the stored decision does not.
stash '{"option":"Inline on main","confidence":0.66}'
SUFFIXED="$(jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" '{
  cwd: $cwd, session_id: $sid,
  tool_input: {questions: [
    {question: "Where should the work happen?",
     options: [{label: "Inline on main (Recommended)"}, {label: "Isolated worktree"}]}
  ]},
  tool_response: "Your questions have been answered: \"Where should the work happen?\"=\"Inline on main (Recommended)\". You can now continue."
}')"
run "$SUFFIXED"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "a bare proposal against a suffixed label is agreement too"
else
  fail "a bare proposal must resolve to the suffixed label" "$B"
fi

echo "── a proposal that resolves to a DIFFERENT option is still a disagreement ──"
# The normalisation must not become a rule that matches everything. If it did,
# every row would read `true` and the rate would be 100% by construction —
# which is the one failure mode worse than the false disagreements above,
# because it is invisible.
stash '{"option":"Inline on main","confidence":0.66}'
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "a genuine disagreement is still recorded as false"
else
  fail "normalisation must not turn every row into agreement" "$B"
fi

echo "── an EXACT label match wins over an earlier containment match ──"
# Greptile on PR #7522. `resolve` took the first containment match in label
# order, not the best one. With labels ["Plan", "Plan mode"] and a proposal of
# "Plan mode": "plan mode" contains "plan", so the EARLIER, shorter label wins
# and the proposal is recorded as "Plan".
#
# That is wrong in both directions at once, which is why it matters more than a
# near miss: choosing "Plan mode" records a false DISAGREEMENT (the resolved
# "Plan" differs from the answer), and choosing "Plan" records a false
# AGREEMENT. One ambiguous label pair corrupts the row whichever way the
# operator answers.
AMBIG_CARD() {
  jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" --arg chosen "$1" '{
    cwd: $cwd, session_id: $sid,
    tool_input: {questions: [
      {question: "Which mode?", options: [{label: "Plan"}, {label: "Plan mode"}]}
    ]},
    tool_response: ("Your questions have been answered: \"Which mode?\"=\"" + $chosen + "\". You can now continue.")
  }'
}
stash '{"option":"Plan mode","confidence":0.8}'
run "$(AMBIG_CARD 'Plan mode')"
B="$(body_for 'Which mode?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Plan mode" ]; then
  pass "an exact match beats an earlier containment match"
else
  fail "an exact match must beat an earlier containment match" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "choosing the exactly-proposed option is agreement"
else
  fail "choosing the exactly-proposed option must be agreement" "$B"
fi
stash '{"option":"Plan mode","confidence":0.8}'
run "$(AMBIG_CARD 'Plan')"
B="$(body_for 'Which mode?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "choosing the OTHER option is a disagreement, not a false agreement"
else
  fail "choosing the other option must be a disagreement" "$B"
fi

echo "── an ambiguous proposal with no exact match records nothing ──"
# A proposal that contains-matches two labels and equals neither is not
# resolvable. Guessing the first is how the bug above was introduced; recording
# nothing is the only honest option.
stash '{"option":"Plan","confidence":0.8}'
run "$(jq -cn --arg cwd "$TMP/repo" --arg sid "$SID" '{
  cwd: $cwd, session_id: $sid,
  tool_input: {questions: [
    {question: "Which mode?", options: [{label: "Plan A"}, {label: "Plan B"}]}
  ]},
  tool_response: "Your questions have been answered: \"Which mode?\"=\"Plan A\". You can now continue."
}')"
B="$(body_for 'Which mode?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "an ambiguous proposal records no verdict"
else
  fail "an ambiguous proposal must record no verdict" "$B"
fi

echo "── the receipt is read in the order /ask-first actually writes it ──"
# Greptile on PR #7522, and the more serious of the two. Every receipt fixture
# above is a COMPLETED one — questions carrying both their proposal and their
# `chosen`. That is not the order the real thing happens in:
# `capture-decision.sh` fires on PostToolUse(AskUserQuestion), so it reads the
# receipt at the moment a card is answered, mid-sweep. If the proposals are
# only written at the end, the file holds nothing for this question yet and
# every multi-question card silently falls through to the prompt rail, which
# covers single-question cards only — so the per-question rail would never fire
# on a real sweep at all.
#
# The fixture here is a PENDING receipt: proposals present, `chosen` absent,
# which is what must exist before the card is raised. `record-sweep-decisions.sh`
# correctly skips such an entry (no answer yet), so nothing else is disturbed.
stash ""
cat > "$RECEIPT" <<'EOF'
{"questions":[
  {"question":"Where should the work happen?","axis":"execution shape","tier":"asked",
   "engram_proposed":"Isolated worktree","engram_confidence":0.81,"round":1},
  {"question":"Which lane first?","axis":"sequencing","tier":"asked",
   "engram_proposed":"Release","engram_confidence":0.64,"round":1}
],"axes":["execution shape","sequencing"],"rounds":[{"round":1}]}
EOF
run "$TWO_QUESTIONS"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_scope // ""')" = "question" ]; then
  pass "a PENDING receipt (no chosen yet) still yields per-question verdicts"
else
  fail "a pending receipt must yield per-question verdicts — this is the real write order" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.agreed_with_engram // ""')" = "true" ]; then
  pass "Q1 verdict from a pending receipt"
else
  fail "Q1 verdict from a pending receipt" "$B"
fi
B2="$(body_for 'Which lane first?')"
if [ "$(printf '%s' "$B2" | jq -r 'if (.sweep|has("agreed_with_engram")) then (.sweep.agreed_with_engram|tostring) else "ABSENT" end')" = "false" ]; then
  pass "Q2 disagreement from a pending receipt"
else
  fail "Q2 disagreement from a pending receipt" "$B2"
fi
rm -f "$RECEIPT"

echo "── a SECOND sweep's entry wins over the first for the same question ──"
# Greptile on PR #7522. The receipt is keyed by SESSION, and a session can run
# /ask-first more than once. A second sweep APPENDS its pending entries, so a
# repeated question such as "Where should the work happen?" now appears twice.
# `sweep_for` took `.[0]` — the FIRST match — so the OLD sweep's proposal and
# confidence were recorded against the NEW answer.
#
# That is the first-match-wins defect one layer out from the `resolve` one, and
# it is worse here: it attributes a prediction made in a different round, at a
# different confidence, to an answer that was never given against it. Newest
# wins, because entries are appended in order and the last one is the sweep
# currently asking.
stash ""
cat > "$RECEIPT" <<'EOF'
{"questions":[
  {"question":"Where should the work happen?","axis":"execution shape","tier":"asked",
   "engram_proposed":"Inline on main","engram_confidence":0.93,"chosen":"Inline on main","round":1},
  {"question":"Where should the work happen?","axis":"execution shape","tier":"asked",
   "engram_proposed":"Isolated worktree","engram_confidence":0.31,"round":2}
],"axes":["execution shape"],"rounds":[{"round":1},{"round":2}]}
EOF
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed // ""')" = "Isolated worktree" ]; then
  pass "the SECOND sweep's proposal is used"
else
  fail "the second sweep's proposal must win — the first is a stale prediction" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.engram_proposed_confidence // ""')" = "0.31" ]; then
  pass "and its confidence, not the earlier 0.93"
else
  fail "the second sweep's confidence must win" "$B"
fi
if [ "$(printf '%s' "$B" | jq -r '.sweep.round // ""')" = "2" ]; then
  pass "the whole entry comes from the later sweep, not a mix"
else
  fail "the entry must come wholly from the later sweep" "$B"
fi
rm -f "$RECEIPT"

echo "── a traversing session id reads no stash ──"
stash "$PROPOSAL"
BAD="$(jq -cn --arg cwd "$TMP/repo" '{
  cwd: $cwd, session_id: "../../etc/passwd",
  tool_input: {questions: [{question: "Where should the work happen?", options: [{label: "Isolated worktree"}]}]},
  tool_response: "Your questions have been answered: \"Where should the work happen?\"=\"Isolated worktree\". You can now continue."
}')"
run "$BAD"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("engram_proposed")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "a traversing session id attaches nothing"
else
  fail "a traversing session id attaches nothing" "$B"
fi

echo "── a malformed stash is ignored, not posted as junk ──"
stash '{"option":'
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$POSTS" = "1" ]; then pass "malformed stash ⇒ still posts the decision"; else fail "malformed stash ⇒ still posts the decision" "posts=$POSTS" "$ERR"; fi
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("engram_proposed")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "malformed stash ⇒ no calibration fields"
else
  fail "malformed stash ⇒ no calibration fields" "$B"
fi

echo "── a stash with no option is ignored ──"
stash '{"confidence":0.9}'
run "$(one_question 'Isolated worktree')"
B="$(body_for 'Where should the work happen?')"
if [ "$(printf '%s' "$B" | jq -r 'if (.sweep // {} | has("agreed_with_engram")) then "PRESENT" else "ABSENT" end')" = "ABSENT" ]; then
  pass "a stash with no option proposes nothing, so nothing is compared"
else
  fail "a stash with no option proposes nothing" "$B"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
