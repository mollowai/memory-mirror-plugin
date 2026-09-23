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
# a receipt was written keyed by grounding_id, holding the message_hashes
RECEIPT="$(find "$TMPDIR" -name 'g-abc-123.json' 2>/dev/null | head -1)"
if [ -n "$RECEIPT" ] \
  && [ "$(jq -r '.grounding_id' "$RECEIPT")" = "g-abc-123" ] \
  && [ "$(jq -r '[.facts[].message_hash] | sort | join(",")' "$RECEIPT")" = "mh-fact-one,mh-fact-two" ]; then
  pass "ground: writes a receipt with grounding_id + each fact's message_hash"
else
  fail "ground: writes a receipt with grounding_id + message_hashes" "receipt='$(cat "$RECEIPT" 2>/dev/null)'"
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
echo '{"grounding_id":"g-x","grounded_at":100,"facts":[{"message_hash":"mh1","content":"alpha beta"}]}' >"$rdir/g-x.json"
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
echo '{"grounding_id":"g-y","grounded_at":100,"facts":[{"message_hash":"mh1","content":"alpha"}]}' >"$rdir/g-y.json"
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
 {"message_hash":"mh-one","content":"the staging deploy uses the pinned commit and skips the gate chain"},
 {"message_hash":"mh-two","content":"an utterly unrelated fact about the phase of the moon tonight"}]}
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
 {"message_hash":"mh-s","content":"the staging deploy uses the pinned commit and skips the gate chain"}]}
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
echo '{"grounding_id":"g-nt","grounded_at":100,"facts":[{"message_hash":"mh-nt","content":"alpha beta gamma delta epsilon zeta eta theta"}]}' >"$rdir/g-nt.json"
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
echo '{"grounding_id":"g-old","grounded_at":100,"facts":[{"message_hash":"mh-old","content":"an old fact from a previous turn about elephants and giraffes"}]}' >"$rdir/g-old.json"
sleep 1
echo '{"grounding_id":"g-new","grounded_at":200,"facts":[{"message_hash":"mh-new","content":"the staging deploy uses the pinned commit and skips the gate chain entirely"}]}' >"$rdir/g-new.json"
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

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
