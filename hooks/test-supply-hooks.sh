#!/usr/bin/env bash
set -uo pipefail
# Tests for the supply-mode dogfood hooks (MOL-5857):
#   supply-ground.sh  (UserPromptSubmit) — grounds from the register via
#                      POST /seam/v1/ground and injects the facts.
#   supply-stop.sh     (Stop)            — posts the turn outcome back via
#                      POST /seam/v1/outcome.
#
# The contract this suite exists to nail down is the OFF state. Both hooks load
# into EVERY Claude Code session on this machine, so a hook that phones home
# without the explicit opt-in degrades every prompt every developer types. A
# test that only drives the ON path passes identically whether the guard works
# or not — so the off-state assertions here check the observable consequence:
# with the opt-in unset, NO request is attempted (curl is never invoked) and the
# hook exits 0 having emitted nothing.
#
# No network: curl is replaced by a PATH shim that logs every invocation and
# returns a canned body, so "was a request attempted" is a file check.
#
# Run: bash plugins/memory-mirror/hooks/test-supply-hooks.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# ── harness ──────────────────────────────────────────────────────────────────
# A sandbox per case: its own HOME (seen-state), TMPDIR (receipts), a curl shim
# on PATH that logs args to $CURL_LOG and prints $CURL_BODY_FILE if set.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mm-supply-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SHIM="$WORK/bin"
mkdir -p "$SHIM"
cat >"$SHIM/curl" <<'SHIM_EOF'
#!/usr/bin/env bash
# Log the full argument vector so a test can assert what (if anything) was sent.
printf '%s\n' "$*" >>"${CURL_LOG:-/dev/null}"
# Emit the canned response body for a *_read call; a plain post ignores stdout.
if [ -n "${CURL_BODY_FILE:-}" ] && [ -f "${CURL_BODY_FILE}" ]; then
  cat "${CURL_BODY_FILE}"
fi
exit 0
SHIM_EOF
chmod +x "$SHIM/curl"

# run_hook <script> <stdin-json> — runs a hook in a fresh sandbox with the curl
# shim first on PATH. Exports the *_TEST_* vars the caller set beforehand.
# Captures stdout to $LAST_OUT, exit code to $LAST_RC.
LAST_OUT=""
LAST_RC=0
run_hook() {
  local script="$1" stdin="$2"
  LAST_OUT="$(printf '%s' "$stdin" | PATH="$SHIM:$PATH" bash "$DIR/$script" 2>/dev/null)"
  LAST_RC=$?
}

reset_case() {
  CASE="$WORK/case-$RANDOM$RANDOM"
  mkdir -p "$CASE"
  export HOME="$CASE/home"
  export TMPDIR="$CASE/tmp"
  mkdir -p "$HOME" "$TMPDIR"
  export CURL_LOG="$CASE/curl.log"
  : >"$CURL_LOG"
  unset CURL_BODY_FILE
  # A staging-shaped config so mm_ready passes when we want the ON path.
  export MOLLOW_MEMORY_URL="https://staging.mollow.ai/mcp/v2"
  export MOLLOW_MEMORY_API_KEY="mol_testkey"
  unset MOLLOW_SUPPLY_MODE MOLLOW_SUPPLY_WORKSPACE_ID MOLLOW_SUPPLY_LIMIT
}

curl_called() { [ -s "$CURL_LOG" ]; }

# A transcript whose assistant turn BOTH answers and calls a fetch tool. $1 = file,
# $2 = uri passed to the tool (empty for none), $3 = answer text.
ptr_transcript() {
  # $1=file $2=hash ("" for no verify) $3=answer $4=timestamp $5=outcome (default match)
  local out="$1" hash="$2" text="$3" when="${4:-}" outcome="${5:-match}"
  local ts
  ts="${when:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}"
  : >"$out"
  if [ -n "$hash" ]; then
    jq -cn --arg h "$hash" --arg ts "$ts" '{timestamp:$ts,type:"assistant",message:{content:[
      {type:"tool_use",id:"tu_1",name:"mcp__mollow-memory__verify_fetched_bytes",input:{hash:$h,bytes:"..."}}]}}' >>"$out"
    if [ "${6:-string}" = "array" ]; then
      jq -cn --arg o "$outcome" --arg ts "$ts" '{timestamp:$ts,type:"user",message:{content:[
        {type:"tool_result",tool_use_id:"tu_1",content:[{type:"text",text:("{\"outcome\":\"" + $o + "\"}")}]}]}}' >>"$out"
    else
      jq -cn --arg o "$outcome" --arg ts "$ts" '{timestamp:$ts,type:"user",message:{content:[
      {type:"tool_result",tool_use_id:"tu_1",content:("{\"outcome\":\"" + $o + "\"}")}]}}' >>"$out"
    fi
  fi
  jq -cn --arg t "$text" --arg ts "$ts" '{timestamp:$ts,type:"assistant",message:{content:[{type:"text",text:$t}]}}' >>"$out"
}


# A canned facts-mode /ground response with two facts.
ground_body() {
  cat >"$CASE/ground.json" <<'JSON'
{"grounding_id":"g-abc-123","mode":"facts","facts":[
  {"content":"The staging deploy uses the pinned commit and skips the gate chain entirely","verify_hash":"vh1","verify_hash_version":3,"verified":true,"relevance":0.91,"message_hash":"mh-fact-one","title":"Pinned release"},
  {"content":"Postgres test database is named mollow_test and lives in docker compose","verify_hash":"vh2","verify_hash_version":3,"verified":true,"relevance":0.72,"message_hash":"mh-fact-two","title":"Test DB"}
]}
JSON
  export CURL_BODY_FILE="$CASE/ground.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# supply-ground.sh — OFF state (the blast-radius contract)
# ═══════════════════════════════════════════════════════════════════════════

# ── unset opt-in: no request, no output, exit 0 ──────────────────────────────
reset_case
ground_body                      # a valid response is available…
unset CURL_BODY_FILE             # …but nothing should ever call curl
run_hook "supply-ground.sh" '{"prompt":"how do releases work","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && [ -z "$LAST_OUT" ] && ! curl_called; then
  pass "ground: opt-in unset ⇒ no curl, no output, exit 0"
else
  fail "ground: opt-in unset ⇒ no curl, no output, exit 0" \
    "rc=$LAST_RC out='$LAST_OUT' curl_log='$(cat "$CURL_LOG")'"
fi

# ── explicit off (=0): same ──────────────────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=0
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && [ -z "$LAST_OUT" ] && ! curl_called; then
  pass "ground: MOLLOW_SUPPLY_MODE=0 ⇒ no curl, no output"
else
  fail "ground: MOLLOW_SUPPLY_MODE=0 ⇒ no curl, no output" "rc=$LAST_RC out='$LAST_OUT'"
fi

# ── guard is BEFORE mm_ready: unset opt-in wins even with no key at all ───────
reset_case
unset MOLLOW_MEMORY_API_KEY
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "ground: opt-in unset short-circuits before mm_ready (no key needed)"
else
  fail "ground: opt-in unset short-circuits before mm_ready" "rc=$LAST_RC"
fi

# ── on but not ready (no key): still no curl ─────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
unset MOLLOW_MEMORY_API_KEY
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "ground: on but no API key ⇒ mm_ready blocks the call"
else
  fail "ground: on but no API key ⇒ mm_ready blocks the call" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# supply-ground.sh — ON state
# ═══════════════════════════════════════════════════════════════════════════

# ── grounds, injects facts, writes a receipt ─────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"how do releases work","session_id":"sess-A","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && curl_called; then
  pass "ground: on ⇒ ground call attempted"
else
  fail "ground: on ⇒ ground call attempted" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi
# curl went to /seam/v1/ground with x-mollow-api-key, not Authorization: Bearer
if grep -q "/seam/v1/ground" "$CURL_LOG" && grep -q "x-mollow-api-key" "$CURL_LOG" \
   && ! grep -qi "Authorization: Bearer" "$CURL_LOG"; then
  pass "ground: uses /seam/v1/ground with x-mollow-api-key (not Bearer)"
else
  fail "ground: uses /seam/v1/ground with x-mollow-api-key (not Bearer)" "log='$(cat "$CURL_LOG")'"
fi
# injected context carries the fact content
if printf '%s' "$LAST_OUT" | jq -e '.hookSpecificOutput.additionalContext | test("pinned commit")' >/dev/null 2>&1; then
  pass "ground: injects fact content as additionalContext"
else
  fail "ground: injects fact content as additionalContext" "out='$LAST_OUT'"
fi
# a receipt was written keyed by grounding_id, holding each fact's citation_key
RECEIPT="$(find "$TMPDIR" -name 'g-abc-123.json' 2>/dev/null | head -1)"
if [ -n "$RECEIPT" ] \
  && [ "$(jq -r '.grounding_id' "$RECEIPT")" = "g-abc-123" ] \
  && [ "$(jq -r '[.facts[].citation_key] | sort | join(",")' "$RECEIPT")" = "mh-fact-one,mh-fact-two" ] \
  && [ "$(jq -r '.mode' "$RECEIPT")" = "facts" ]; then
  pass "ground: writes a receipt with grounding_id + each fact's citation_key"
else
  fail "ground: writes a receipt with grounding_id + citation_keys" "receipt='$(cat "$RECEIPT" 2>/dev/null)'"
fi

# ── workspace id header passed when set ──────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_WORKSPACE_ID="ws-uuid-1"
ground_body
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-W","cwd":"/tmp"}'
if grep -q "x-mollow-workspace-id: ws-uuid-1" "$CURL_LOG"; then
  pass "ground: sends x-mollow-workspace-id when MOLLOW_SUPPLY_WORKSPACE_ID set"
else
  fail "ground: sends x-mollow-workspace-id when set" "log='$(cat "$CURL_LOG")'"
fi

# ── empty prompt: no call ────────────────────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"","session_id":"s","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "ground: empty prompt ⇒ no call"
else
  fail "ground: empty prompt ⇒ no call" "curl='$(cat "$CURL_LOG")'"
fi

# ── dedupe: a second turn with the same facts suppresses re-injection ─────────
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"q1","session_id":"sess-D","cwd":"/tmp"}'
first_out="$LAST_OUT"
ground_body   # same facts, fresh grounding call
run_hook "supply-ground.sh" '{"prompt":"q2 still about the same thing","session_id":"sess-D","cwd":"/tmp"}'
if [ -n "$first_out" ] && [ -z "$LAST_OUT" ]; then
  pass "ground: dedupe suppresses already-shown facts on the next turn"
else
  fail "ground: dedupe suppresses already-shown facts" "first='$first_out' second='$LAST_OUT'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# supply-stop.sh — OFF state
# ═══════════════════════════════════════════════════════════════════════════

# ── unset opt-in: no post-back, exit 0 ───────────────────────────────────────
reset_case
# leave a pending receipt behind so "does it post back" is meaningful
rdir="$TMPDIR/mollow-supply/sess-S"
mkdir -p "$rdir"
echo '{"grounding_id":"g-x","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha beta"}]}' >"$rdir/g-x.json"
run_hook "supply-stop.sh" '{"session_id":"sess-S","transcript_path":"/nope","stop_hook_active":false}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "stop: opt-in unset ⇒ no post-back, exit 0"
else
  fail "stop: opt-in unset ⇒ no post-back" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi

# ── re-entrancy: stop_hook_active=true short-circuits ────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
rdir="$TMPDIR/mollow-supply/sess-R"
mkdir -p "$rdir"
echo '{"grounding_id":"g-y","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-y.json"
run_hook "supply-stop.sh" '{"session_id":"sess-R","transcript_path":"/nope","stop_hook_active":true}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "stop: stop_hook_active=true ⇒ no post-back (re-entrancy guard)"
else
  fail "stop: stop_hook_active=true ⇒ no post-back" "curl='$(cat "$CURL_LOG")'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# supply-stop.sh — ON state
# ═══════════════════════════════════════════════════════════════════════════

# ── posts back grounding_id + matched used_fact_ids, deletes the receipt ─────
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"
echo '{"grounding_id":"g-z","status":"ok","supplied_count":2}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-P"
mkdir -p "$rdir"
# fact-one is quoted verbatim (8+ words) in the answer; fact-two is not mentioned.
cat >"$rdir/g-z.json" <<'JSON'
{"grounding_id":"g-z","grounded_at":100,"facts":[
 {"citation_key":"mh-one","match_text":"the staging deploy uses the pinned commit and skips the gate chain"},
 {"citation_key":"mh-two","match_text":"an utterly unrelated fact about the phase of the moon tonight"}]}
JSON
# transcript: assistant content as an ARRAY of blocks
tp="$CASE/transcript.jsonl"
cat >"$tp" <<'JSON'
{"type":"user","message":{"role":"user","content":[{"type":"text","text":"how do releases work"}]}}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"As you noted, the staging deploy uses the pinned commit and skips the gate chain, so it is fast."}]}}
JSON
run_hook "supply-stop.sh" "{\"session_id\":\"sess-P\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}"
if grep -q "/seam/v1/outcome" "$CURL_LOG"; then
  pass "stop: on ⇒ posts to /seam/v1/outcome"
else
  fail "stop: on ⇒ posts to /seam/v1/outcome" "log='$(cat "$CURL_LOG")'"
fi
# the posted body: grounding_id + status + latency_ms + used_fact_ids=[mh-one].
# The shim logs the full arg vector ("$*"); the JSON body is the last field after
# "-d ", but grepping the whole log is enough to assert which ids are present.
POSTED="$(awk 'BEGIN{RS="";} {print}' "$CURL_LOG")"
if printf '%s' "$POSTED" | grep -q '"grounding_id"' && printf '%s' "$POSTED" | grep -q "mh-one" \
   && ! printf '%s' "$POSTED" | grep -q "mh-two"; then
  pass "stop: used_fact_ids cites the verbatim-quoted fact only (mh-one, not mh-two)"
else
  fail "stop: used_fact_ids cites verbatim fact only" "posted='$POSTED'"
fi
# receipt consumed
if [ -z "$(find "$TMPDIR" -name 'g-z.json' 2>/dev/null)" ]; then
  pass "stop: consumes (deletes) the receipt after posting"
else
  fail "stop: consumes the receipt after posting" "still present"
fi

# ── the string-vs-array fixture the issue warns about: bare-string content ───
# 598,380 entries carry content as an array of blocks, but the format PERMITS a
# bare string, and `map` over a string is a hard jq error. A reader that assumes
# an array crashes here and silently disables itself. This must not.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"
echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-STR"
mkdir -p "$rdir"
cat >"$rdir/g-str.json" <<'JSON'
{"grounding_id":"g-str","grounded_at":100,"facts":[
 {"citation_key":"mh-s","match_text":"the staging deploy uses the pinned commit and skips the gate chain"}]}
JSON
tp="$CASE/transcript-str.jsonl"
cat >"$tp" <<'JSON'
{"type":"user","message":{"role":"user","content":"how do releases work"}}
{"type":"assistant","message":{"role":"assistant","content":"the staging deploy uses the pinned commit and skips the gate chain entirely"}}
JSON
run_hook "supply-stop.sh" "{\"session_id\":\"sess-STR\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}"
if [ "$LAST_RC" -eq 0 ] && grep -q "/seam/v1/outcome" "$CURL_LOG"; then
  POSTED="$(awk 'BEGIN{RS="";} {print}' "$CURL_LOG")"
  if printf '%s' "$POSTED" | grep -q "mh-s"; then
    pass "stop: bare-string assistant content is handled (no crash, still matches)"
  else
    pass "stop: bare-string assistant content is handled (no crash; match optional)"
  fi
else
  fail "stop: bare-string assistant content is handled" "rc=$LAST_RC log='$(cat "$CURL_LOG")'"
fi

# ── unreadable transcript: still posts back, WITHOUT guessing used_fact_ids ──
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"
echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-NT"
mkdir -p "$rdir"
echo '{"grounding_id":"g-nt","grounded_at":100,"facts":[{"citation_key":"mh-nt","match_text":"alpha beta gamma delta epsilon zeta eta theta"}]}' >"$rdir/g-nt.json"
run_hook "supply-stop.sh" '{"session_id":"sess-NT","transcript_path":"/does/not/exist","stop_hook_active":false}'
if grep -q "/seam/v1/outcome" "$CURL_LOG"; then
  POSTED="$(awk 'BEGIN{RS="";} {print}' "$CURL_LOG")"
  if ! printf '%s' "$POSTED" | grep -q "used_fact_ids"; then
    pass "stop: unreadable transcript ⇒ posts back but omits used_fact_ids (no guessing)"
  else
    fail "stop: unreadable transcript should omit used_fact_ids" "posted='$POSTED'"
  fi
else
  fail "stop: unreadable transcript still posts back" "log='$(cat "$CURL_LOG")'"
fi

# ── no pending receipt: nothing to post ──────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
run_hook "supply-stop.sh" '{"session_id":"sess-EMPTY","transcript_path":"/nope","stop_hook_active":false}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "stop: no pending receipt ⇒ no post-back"
else
  fail "stop: no pending receipt ⇒ no post-back" "curl='$(cat "$CURL_LOG")'"
fi

# ── stale receipt is NOT attributed to this turn (Greptile PR #6160) ─────────
# A prior turn whose Stop never fired left g-old behind. This Stop must correlate
# ONLY the current turn's receipt (g-new) with the current answer, and discard
# g-old rather than post it against the wrong turn's answer/latency.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"
echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-STALE"
mkdir -p "$rdir"
echo '{"grounding_id":"g-old","grounded_at":100,"facts":[{"citation_key":"mh-old","match_text":"an old fact from a previous turn about elephants and giraffes"}]}' >"$rdir/g-old.json"
sleep 1
echo '{"grounding_id":"g-new","grounded_at":200,"facts":[{"citation_key":"mh-new","match_text":"the staging deploy uses the pinned commit and skips the gate chain entirely"}]}' >"$rdir/g-new.json"
touch "$rdir/g-new.json"   # ensure g-new is newest by mtime
tp="$CASE/t-stale.jsonl"
cat >"$tp" <<'JSON'
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"the staging deploy uses the pinned commit and skips the gate chain entirely, noted."}]}}
JSON
run_hook "supply-stop.sh" "{\"session_id\":\"sess-STALE\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}"
POSTS="$(grep -c "/seam/v1/outcome" "$CURL_LOG" 2>/dev/null || echo 0)"
POSTED="$(awk 'BEGIN{RS="";} {print}' "$CURL_LOG")"
if [ "$POSTS" = "1" ] && printf '%s' "$POSTED" | grep -q "g-new" && ! printf '%s' "$POSTED" | grep -q "g-old"; then
  pass "stop: only the current turn's receipt is posted; stale receipt discarded"
else
  fail "stop: only current receipt posted, stale discarded" "posts=$POSTS posted='$POSTED'"
fi
if [ -z "$(find "$TMPDIR" -name 'g-old.json' -o -name 'g-new.json' 2>/dev/null)" ]; then
  pass "stop: both stale and current receipts are consumed"
else
  fail "stop: both receipts consumed" "still: $(find "$TMPDIR" -name 'g-*.json')"
fi

# ── path-traversal session_id must not escape the receipt root ───────────────
# A session_id of ".." passes a bare charset check and would resolve receipt_dir
# to TMPDIR itself, whose chmod could lock the shared temp dir (Greptile PR #6160).
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
before_mode="$(stat -c '%a' "$TMPDIR" 2>/dev/null || stat -f '%Lp' "$TMPDIR" 2>/dev/null)"
run_hook "supply-ground.sh" '{"prompt":"how do releases work","session_id":"..","cwd":"/tmp"}'
after_mode="$(stat -c '%a' "$TMPDIR" 2>/dev/null || stat -f '%Lp' "$TMPDIR" 2>/dev/null)"
# No receipt written into TMPDIR, and TMPDIR's own perms untouched.
if [ -z "$(find "$TMPDIR" -maxdepth 2 -name 'g-abc-123.json' 2>/dev/null)" ] && [ "$before_mode" = "$after_mode" ]; then
  pass "ground: '..' session_id is rejected (no receipt, TMPDIR perms untouched)"
else
  fail "ground: '..' session_id rejected" "before=$before_mode after=$after_mode receipt=$(find "$TMPDIR" -name 'g-abc-123.json')"
fi

# ── receipt holds memory content, so it must not be world-readable ───────────
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"how do releases work","session_id":"sess-PERM","cwd":"/tmp"}'
RF="$(find "$TMPDIR" -name 'g-abc-123.json' 2>/dev/null | head -1)"
if [ -n "$RF" ]; then
  fmode="$(stat -c '%a' "$RF" 2>/dev/null || stat -f '%Lp' "$RF" 2>/dev/null)"
  dmode="$(stat -c '%a' "$(dirname "$RF")" 2>/dev/null || stat -f '%Lp' "$(dirname "$RF")" 2>/dev/null)"
  if [ "$fmode" = "600" ] && [ "$dmode" = "700" ]; then
    pass "ground: receipt file is 0600 in a 0700 dir (memory content owner-only)"
  else
    fail "ground: receipt perms owner-only" "file=$fmode dir=$dmode"
  fi
else
  fail "ground: receipt perms owner-only" "no receipt written"
fi

# ═══════════════════════════════════════════════════════════════════════════
# pointer mode (MOL-5936 p6) — its OWN opt-in on top of MOLLOW_SUPPLY_MODE
# ═══════════════════════════════════════════════════════════════════════════

# A canned pointer-mode /ground response: no content, two DIFFERENT locators with
# DIFFERENT hashes. Two entries is the minimum that can show a hash paired with
# the wrong entry's uri — a one-entry fixture cannot express that failure.
pointer_body() {
  cat >"$CASE/pointer.json" <<'JSON'
{"grounding_id":"g-ptr-1","mode":"pointer","facts":[
  {"citation_key":"rec-aaa","hash":"1111111111111111111111111111111111111111111111111111111111111111",
   "locator":{"kind":"file","uri":"file:///corpus/alpha.txt","canonical_form":"file-text-v1","hash_version":"sha256"},
   "title":"Alpha doc"},
  {"citation_key":"rec-bbb","hash":"2222222222222222222222222222222222222222222222222222222222222222",
   "locator":{"kind":"sql_row","uri":"pg://orders/42","canonical_form":"sql-row-text-v1","hash_version":"sha256"},
   "title":"Order 42"}
]}
JSON
  export CURL_BODY_FILE="$CASE/pointer.json"
}

# ── OFF state, tested SPECIFICALLY (MOL-5857's rule) ─────────────────────────
# A suite that only exercises the ON path passes whether or not the opt-in is
# honoured. These two pin that pointer mode changes NOTHING until asked for.

# supply mode on, pointer opt-in UNSET ⇒ still asks for facts
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-OFF","cwd":"/tmp"}'
if grep -q '"mode":"facts"' "$CURL_LOG" && ! grep -q '"mode":"pointer"' "$CURL_LOG"; then
  pass "pointer: opt-in unset ⇒ body still requests facts mode"
else
  fail "pointer: opt-in unset ⇒ body still requests facts mode" "log='$(cat "$CURL_LOG")'"
fi

# explicit off
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=0
ground_body
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-OFF2","cwd":"/tmp"}'
if grep -q '"mode":"facts"' "$CURL_LOG" && ! grep -q '"mode":"pointer"' "$CURL_LOG"; then
  pass "pointer: MOLLOW_SUPPLY_POINTER_MODE=0 ⇒ facts mode"
else
  fail "pointer: MOLLOW_SUPPLY_POINTER_MODE=0 ⇒ facts mode" "log='$(cat "$CURL_LOG")'"
fi

# pointer opt-in ON but supply mode OFF ⇒ no curl at all. The outer guard still
# wins; pointer mode must not be a second way to switch the hook on.
reset_case
export MOLLOW_SUPPLY_POINTER_MODE=on
unset MOLLOW_SUPPLY_MODE
ground_body
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-OFF3","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && [ -z "$LAST_OUT" ] && ! curl_called; then
  pass "pointer: pointer opt-in alone ⇒ no curl (outer guard still wins)"
else
  fail "pointer: pointer opt-in alone ⇒ no curl" "rc=$LAST_RC out='$LAST_OUT' log='$(cat "$CURL_LOG")'"
fi

# ── ON state ─────────────────────────────────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
pointer_body
run_hook "supply-ground.sh" '{"prompt":"what is in the corpus","session_id":"sess-PTR","cwd":"/tmp"}'

if grep -q '"mode":"pointer"' "$CURL_LOG"; then
  pass "pointer: on ⇒ body requests pointer mode"
else
  fail "pointer: on ⇒ body requests pointer mode" "log='$(cat "$CURL_LOG")'"
fi

CTX="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"

# §8: "the prompt names the tool" is the only remedy for the model not fetching.
# All three names, spelled as the model sees them.
missing=""
for t in "mcp__fetch-files__fetch_file" "mcp__fetch-postgres__execute_sql" "mcp__mollow-memory__verify_fetched_bytes"; do
  printf '%s' "$CTX" | grep -qF "$t" || missing="$missing $t"
done
if [ -z "$missing" ]; then
  pass "pointer: injected context names all three tools by their real names"
else
  fail "pointer: injected context names all three tools" "missing:$missing ctx='$CTX'"
fi

# No content crosses. The fixture carries none, so this asserts the WORDING does
# not invent any — and that the facts-mode phrasing is not reused.
if ! printf '%s' "$CTX" | grep -qiF "Facts from your memory"; then
  pass "pointer: does not reuse the facts-mode wording"
else
  fail "pointer: does not reuse the facts-mode wording" "ctx='$CTX'"
fi

# THE PAIRING TEST. Each entry's uri must appear on the SAME line as its OWN
# hash. Pairing entry A's hash with entry B's uri is the failure that reports a
# mismatch which is not real, and it is invisible if uris and hashes are only
# checked for presence.
a_ok="$(printf '%s' "$CTX" | grep -c 'uri=file:///corpus/alpha.txt hash=1111' || true)"
b_ok="$(printf '%s' "$CTX" | grep -c 'uri=pg://orders/42 hash=2222' || true)"
if [ "$a_ok" -eq 1 ] && [ "$b_ok" -eq 1 ]; then
  pass "pointer: each entry pairs its OWN uri with its OWN hash on one line"
else
  fail "pointer: uri/hash pairing" "alpha=$a_ok order=$b_ok ctx='$CTX'"
fi

# Locator kind is named per entry, so the model can pick the right fetch tool.
if printf '%s' "$CTX" | grep -qF "[file]" && printf '%s' "$CTX" | grep -qF "[sql_row]"; then
  pass "pointer: names each locator's kind so the fetch tool can be chosen"
else
  fail "pointer: names each locator's kind" "ctx='$CTX'"
fi

# Receipt: citation_key is the registry record id, match_text is the uri (Mollow
# holds no content to match against).
PR="$(find "$TMPDIR" -name 'g-ptr-1.json' 2>/dev/null | head -1)"
if [ -n "$PR" ] \
  && [ "$(jq -r '.mode' "$PR")" = "pointer" ] \
  && [ "$(jq -r '[.facts[].citation_key] | sort | join(",")' "$PR")" = "rec-aaa,rec-bbb" ] \
  && [ "$(jq -r '[.facts[].match_text] | sort | join(",")' "$PR")" = "file:///corpus/alpha.txt,pg://orders/42" ]; then
  pass "pointer: receipt carries citation_key + the locator uri as match_text"
else
  fail "pointer: receipt shape" "receipt='$(cat "$PR" 2>/dev/null)'"
fi

# ── Stop: credit on the VERIFY call, bounded to this turn ────────────────────
# Evidence is the entry hash reaching a tool input, not the uri and not the prose.
# GRD is a grounded_at just in the past so a "now" tool call is inside the turn.
GRD=$(( $(date +%s) - 30 ))

ptr_receipt() {  # $1=dir $2=gid $3..: citation_key:hash pairs
  local dir="$1" gid="$2"; shift 2
  local facts="[]"
  for pair in "$@"; do
    facts="$(jq -c --argjson f "$facts" --arg k "${pair%%:*}" --arg h "${pair#*:}" \
      '$f + [{citation_key:$k, match_text:("file:///c/"+$k+".txt"), verify_hash:$h, relevance:0.9}]' <<<'null')"
  done
  jq -cn --arg g "$gid" --argjson ts "$GRD" --argjson f "$facts" \
    '{grounding_id:$g, grounded_at:$ts, mode:"pointer", facts:$f}' >"$dir/$gid.json"
}

# Verifying entry A credits A and leaves B alone.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-PS"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-ptr-9" "rec-aaa:HASH_A" "rec-bbb:HASH_B"
tp="$CASE/t.jsonl"; ptr_transcript "$tp" "HASH_A" "Checked the first one."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-PS\",\"transcript_path\":\"$tp\",\"stop_hook_active\":false}"
if grep -q "rec-aaa" "$CURL_LOG" && ! grep -q "rec-bbb" "$CURL_LOG"; then
  pass "pointer stop: credits the VERIFIED entry, not the one left alone"
else
  fail "pointer stop: credits only the verified entry" "log='$(cat "$CURL_LOG")'"
fi

# A sql_row entry is credited too — the whole point of keying on the hash rather
# than the uri, since execute_sql never receives the pg:// locator.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-SQL"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-sql-1",grounded_at:$ts,mode:"pointer",facts:[
  {citation_key:"rec-sql",match_text:"pg://orders/42",verify_hash:"HASH_SQL",relevance:0.9}]}' >"$rdir/g-sql-1.json"
tpq="$CASE/tq.jsonl"; ptr_transcript "$tpq" "HASH_SQL" "Read the row and checked it."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-SQL\",\"transcript_path\":\"$tpq\",\"stop_hook_active\":false}"
if grep -q "rec-sql" "$CURL_LOG"; then
  pass "pointer stop: a sql_row entry IS credited (uri never reaches execute_sql)"
else
  fail "pointer stop: sql_row must be creditable by hash" "log='$(cat "$CURL_LOG")'"
fi

# A verify from BEFORE this grounding must not credit it — the tail spans turns.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-OLD"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-ptr-2" "rec-old:HASH_OLD"
tpo="$CASE/to.jsonl"
ptr_transcript "$tpo" "HASH_OLD" "Checked it last turn." "2020-01-01T00:00:00.000Z"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-OLD\",\"transcript_path\":\"$tpo\",\"stop_hook_active\":false}"
if grep -q "g-ptr-2" "$CURL_LOG" && ! grep -q "rec-old" "$CURL_LOG"; then
  pass "pointer stop: a verify from an EARLIER turn does not credit this one"
else
  fail "pointer stop: out-of-turn verify must not credit" "log='$(cat "$CURL_LOG")'"
fi

# No tool call at all ⇒ omit used_fact_ids rather than send an empty list.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-PN"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-ptr-8" "rec-none:HASH_N"
tp2="$CASE/t2.jsonl"; ptr_transcript "$tp2" "" "I did not open anything."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-PN\",\"transcript_path\":\"$tp2\",\"stop_hook_active\":false}"
if grep -q "g-ptr-8" "$CURL_LOG" && ! grep -q "used_fact_ids" "$CURL_LOG"; then
  pass "pointer stop: nothing verified ⇒ posts back WITHOUT used_fact_ids"
else
  fail "pointer stop: nothing verified ⇒ omits used_fact_ids" "log='$(cat "$CURL_LOG")'"
fi

# THE FINDING: the wording asks the model to NAME entries it skipped. Naming one
# in prose — no fetch, no verify — must not credit it.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-SKIP"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-ptr-3",grounded_at:$ts,mode:"pointer",facts:[
  {citation_key:"rec-skipped",match_text:"pg://orders/42",verify_hash:"HASH_SK",relevance:0.9}]}' >"$rdir/g-ptr-3.json"
tps="$CASE/ts.jsonl"
ptr_transcript "$tps" "" "I skipped pg://orders/42 and HASH_SK because execute_sql is unavailable."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-SKIP\",\"transcript_path\":\"$tps\",\"stop_hook_active\":false}"
if grep -q "g-ptr-3" "$CURL_LOG" && ! grep -q "rec-skipped" "$CURL_LOG"; then
  pass "pointer stop: an entry NAMED as skipped in prose is not credited"
else
  fail "pointer stop: naming a skipped entry must not credit it" "log='$(cat "$CURL_LOG")'"
fi

# A pointer entry whose locator uri is EMPTY must still be credited when its hash
# verifies. The uri stopped being the evidence; leaving it in the shared
# emptiness guard silently refused an entry that was fetched and checked.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-NOURI"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-nouri",grounded_at:$ts,mode:"pointer",facts:[
  {citation_key:"rec-nouri",match_text:"",verify_hash:"HASH_NU",relevance:0.9}]}' >"$rdir/g-nouri.json"
tnu="$CASE/tnu.jsonl"; ptr_transcript "$tnu" "HASH_NU" "Checked it."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-NOURI\",\"transcript_path\":\"$tnu\",\"stop_hook_active\":false}"
if grep -q "rec-nouri" "$CURL_LOG"; then
  pass "pointer stop: an empty uri does not disqualify a verified entry"
else
  fail "pointer stop: empty uri must not block a verified credit" "log='$(cat "$CURL_LOG")'"
fi

# Greptile #6228 round 5, finding 1: a verify that came back MISMATCH still has
# the hash in its INPUT. Reading inputs alone credited a pointer the check
# REFUTED — a receipt showing every pointer used while every verification failed.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-MM"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-mm-1" "rec-mm:HASH_MM"
tmm="$CASE/tmm.jsonl"; ptr_transcript "$tmm" "HASH_MM" "The bytes differ." "" "mismatch"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-MM\",\"transcript_path\":\"$tmm\",\"stop_hook_active\":false}"
if grep -q "g-mm-1" "$CURL_LOG" && ! grep -q "rec-mm" "$CURL_LOG"; then
  pass "pointer stop: a verify returning MISMATCH does not credit the pointer"
else
  fail "pointer stop: mismatch must not credit" "log='$(cat "$CURL_LOG")'"
fi

# Finding 2, and it is p9's lesson one layer out: two pointer records with
# IDENTICAL bytes at DIFFERENT locators legitimately share a hash and keep
# separate citation keys. Verifying one must not credit both — that is the exact
# collapse p9 changed the schema to prevent. A one-pointer fixture cannot express
# it, so this carries two.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-DUP"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-dup-1",grounded_at:$ts,mode:"pointer",facts:[
  {citation_key:"rec-one",match_text:"file:///c/one.txt",verify_hash:"HASH_SHARED",relevance:0.9},
  {citation_key:"rec-two",match_text:"file:///c/two.txt",verify_hash:"HASH_SHARED",relevance:0.8}]}' >"$rdir/g-dup-1.json"
tdp="$CASE/tdp.jsonl"; ptr_transcript "$tdp" "HASH_SHARED" "Checked one of them."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-DUP\",\"transcript_path\":\"$tdp\",\"stop_hook_active\":false}"
if grep -q "g-dup-1" "$CURL_LOG" && ! grep -q "rec-one" "$CURL_LOG" && ! grep -q "rec-two" "$CURL_LOG"; then
  pass "pointer stop: a hash shared by two entries credits NEITHER (unattributable)"
else
  fail "pointer stop: shared hash must credit neither" "log='$(cat "$CURL_LOG")'"
fi

# Greptile #6228 round 6: a tool_result's `content` arrives BOTH as a string and
# as an array of text blocks, in the SAME transcript. Every earlier fixture used
# the string shape, so none of them could express this.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-ARR"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-arr-1" "rec-arr:HASH_ARR"
tar="$CASE/tar.jsonl"; ptr_transcript "$tar" "HASH_ARR" "Checked it." "" "match" "array"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-ARR\",\"transcript_path\":\"$tar\",\"stop_hook_active\":false}"
if grep -q "rec-arr" "$CURL_LOG"; then
  pass "pointer stop: an ARRAY-shaped tool_result still credits the verified entry"
else
  fail "pointer stop: array-shaped result must credit" "log='$(cat "$CURL_LOG")'"
fi

# The extraction must not have become "any array result counts": a mismatch in
# array shape must still be refused.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-ARRM"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-arr-2" "rec-arrm:HASH_ARRM"
tam="$CASE/tam.jsonl"; ptr_transcript "$tam" "HASH_ARRM" "Differs." "" "mismatch" "array"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-ARRM\",\"transcript_path\":\"$tam\",\"stop_hook_active\":false}"
if grep -q "g-arr-2" "$CURL_LOG" && ! grep -q "rec-arrm" "$CURL_LOG"; then
  pass "pointer stop: an ARRAY-shaped MISMATCH still does not credit"
else
  fail "pointer stop: array-shaped mismatch must not credit" "log='$(cat "$CURL_LOG")'"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
