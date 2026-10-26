#!/usr/bin/env bash
set -uo pipefail
# Tests for the supply-mode dogfood hooks (MOL-5857):
#   supply-ground.sh  (UserPromptSubmit) — grounds from the register via
#                      POST /grounding/v1/ground and injects the facts.
#   supply-stop.sh     (Stop)            — posts the turn outcome back via
#                      POST /grounding/v1/outcome.
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
# Honour -w '\n%{http_code}' (MOL-5978). The shim has to reproduce this or the
# status the caller parses is the last line of the BODY, which would make every
# response read as an error while the source looked correct. $CURL_STATUS lets a
# case drive a specific code; 200 is the default so existing cases are unchanged.
for a in "$@"; do
  if [ "$a" = "-w" ]; then
    printf '\n%s' "${CURL_STATUS:-200}"
    break
  fi
done
exit 0
SHIM_EOF
chmod +x "$SHIM/curl"

# A shim on `mktemp` too: it logs every invocation's argv to $MKTEMP_LOG (so a
# test can assert whether match_used's file path was taken at all — cleanup
# erases the FILE either way, but never erases the fact that it was created)
# and then execs the real binary so behavior is unchanged.
REAL_MKTEMP="$(command -v mktemp)"
cat >"$SHIM/mktemp" <<SHIM_EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"\${MKTEMP_LOG:-/dev/null}"
exec "$REAL_MKTEMP" "\$@"
SHIM_EOF
chmod +x "$SHIM/mktemp"

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

# Same, but from a chosen working directory. Claude Code runs a Stop hook with
# the worktree ROOT as cwd, so any command in the hook that falls back to "the
# current directory" acts on the user's own files. run_hook leaves cwd wherever
# the suite happens to be, which cannot express that (MOL-6325) — a hook that
# deleted its cwd would pass every case above.
run_hook_cwd() {
  local cwd="$1" script="$2" stdin="$3"
  LAST_OUT="$(cd "$cwd" && printf '%s' "$stdin" | PATH="$SHIM:$PATH" bash "$DIR/$script" 2>/dev/null)"
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
  export MKTEMP_LOG="$CASE/mktemp.log"
  : >"$MKTEMP_LOG"
  unset CURL_BODY_FILE
  # A staging-shaped config so mm_ready passes when we want the ON path.
  export MOLLOW_MEMORY_URL="https://staging.mollow.ai/mcp/v2"
  export MOLLOW_MEMORY_API_KEY="mol_testkey"
  # MOLLOW_SUPPLY_POINTER_MODE is unset here too. Leaving it exported let a
  # pointer case contaminate every later facts-mode case, which made the
  # suite order-dependent and hid the contamination behind a passing run.
  unset MOLLOW_SUPPLY_MODE MOLLOW_SUPPLY_WORKSPACE_ID MOLLOW_SUPPLY_LIMIT
  unset MOLLOW_SUPPLY_POINTER_MODE CURL_STATUS
  # File-backed credential resolution OFF by default here, and an EMPTY project
  # root (MOL-6221). Both matter, for different reasons:
  #
  #   * several cases below buy "no key ⇒ no curl" by unsetting
  #     MOLLOW_MEMORY_API_KEY. Once mm_ready can resolve a key from a file, that
  #     purchase silently stops working — and it did: "ground: on but no API key
  #     ⇒ mm_ready blocks the call" failed because the hook found the developer's
  #     REAL key in the checkout's own .mcp.json.
  #   * with no CLAUDE_PROJECT_DIR, mm_session_root falls back to
  #     `git rev-parse --show-toplevel`, so the suite reads the working
  #     checkout's real .session-config and .mcp.json. A test suite must never
  #     be able to reach a live credential, whichever way this flag is set.
  #
  # The case that exercises resolution opts back in explicitly.
  export MOLLOW_MEMORY_CREDS_FROM_FILES=0
  export CLAUDE_PROJECT_DIR="$CASE/proj"
  mkdir -p "$CLAUDE_PROJECT_DIR"
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
#
# EVERY FACT CARRIES `citation_key`, and that is the whole point of this fixture
# rather than an incidental extra key (MOL-6563). `fact_wire/1` has put it on the
# FACTS wire since MOL-6233 (operator ruling 2026-09-28), equal in value to
# `message_hash` — so a fixture without it is a response shape the server has not
# sent for days.
#
# It is load-bearing because the receipt builder's `match_text` branch USED to
# read `citation_key` as "this is a pointer", and a pointer's text is its
# `locator.uri`. With the key absent the builder took the facts branch, wrote the
# content, and every citation case below passed — with the key present and the old
# branch in place they go red, because `match_text` is written as "". That is the
# bug this fixture now expresses: measured against prod, all 90 facts across all
# 35 live receipts on the dogfood Mac had an empty `match_text`, so the 8-word
# verbatim matcher could never fire and `used_fact_ids` was omitted on every
# facts-mode turn.
#
# Do not drop `citation_key` to make a future case easier to write. Without it the
# suite is green whether or not the projection is correct.
ground_body() {
  cat >"$CASE/ground.json" <<'JSON'
{"grounding_id":"g-abc-123","mode":"facts","facts":[
  {"citation_key":"mh-fact-one","content":"The staging deploy uses the pinned commit and skips the gate chain entirely","verify_hash":"vh1","verify_hash_version":3,"verified":true,"relevance":0.91,"message_hash":"mh-fact-one","title":"Pinned release"},
  {"citation_key":"mh-fact-two","content":"Postgres test database is named mollow_test and lives in docker compose","verify_hash":"vh2","verify_hash_version":3,"verified":true,"relevance":0.72,"message_hash":"mh-fact-two","title":"Test DB"}
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

# ── on, no key in the ENV, but one in .session-config: the call proceeds ──────
# The MOL-6221 path. A worktree pane loses MOLLOW_MEMORY_API_KEY to direnv, so
# the launcher writes it to .session-config; before this, mm_ready returned 1
# with no message and the hook was silently inert for the life of the session.
reset_case
export MOLLOW_SUPPLY_MODE=on
unset MOLLOW_MEMORY_API_KEY
export MOLLOW_MEMORY_CREDS_FROM_FILES=1
printf 'export MOLLOW_MEMORY_API_KEY=mol_fromsessionconfig\n' > "$CLAUDE_PROJECT_DIR/.session-config"
ground_body
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && curl_called; then
  pass "ground: key from .session-config ⇒ the ground call proceeds"
else
  fail "ground: key from .session-config ⇒ the ground call proceeds" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi
# And the resolved key is the one actually sent — resolution that finds a value
# but does not reach the request would look identical to a hook that worked.
if grep -q "mol_fromsessionconfig" "$CURL_LOG"; then
  pass "ground: the .session-config key reaches the request"
else
  fail "ground: the .session-config key reaches the request" "log='$(cat "$CURL_LOG")'"
fi

# ── the machine-wide opt-in file turns supply mode on with NO env var ─────────
# The only switch reachable for an already-running session, whose hook children
# inherit an environ fixed at launch.
reset_case
unset MOLLOW_SUPPLY_MODE
mkdir -p "$HOME/.mollow"
printf 'on\n' > "$HOME/.mollow/supply-mode"
ground_body
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && curl_called; then
  pass "ground: ~/.mollow/supply-mode=on ⇒ ON with no env var"
else
  fail "ground: ~/.mollow/supply-mode=on ⇒ ON with no env var" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi

# An explicit `off` in the environment holds the machine-wide file down.
reset_case
export MOLLOW_SUPPLY_MODE=off
mkdir -p "$HOME/.mollow"
printf 'on\n' > "$HOME/.mollow/supply-mode"
run_hook "supply-ground.sh" '{"prompt":"hi","session_id":"s1","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "ground: env off beats supply-mode file on ⇒ no call"
else
  fail "ground: env off beats supply-mode file on ⇒ no call" "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
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
# curl went to /grounding/v1/ground with x-mollow-api-key, not Authorization: Bearer
if grep -q "/grounding/v1/ground" "$CURL_LOG" && grep -q "x-mollow-api-key" "$CURL_LOG" \
   && ! grep -qi "Authorization: Bearer" "$CURL_LOG"; then
  pass "ground: uses /grounding/v1/ground with x-mollow-api-key (not Bearer)"
else
  fail "ground: uses /grounding/v1/ground with x-mollow-api-key (not Bearer)" "log='$(cat "$CURL_LOG")'"
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
# ── a facts receipt's match_text is the fact CONTENT (MOL-6563) ──────────────
# Rendered through the real generator, because that is the only place this can be
# observed: every citation case below hand-writes a receipt with `match_text`
# already populated, so all of them pass against a builder that writes "". The
# projection and the matcher are two halves of one mechanism and only this case
# covers the first half for facts mode. (Pointer mode has had its equivalent all
# along — "pointer: receipt carries citation_key + the locator uri as match_text".)
#
# Asserted as a NON-EMPTY exact value, not a substring: the failure mode is the
# empty string, and `contains("")` is true of every string.
if [ -n "$RECEIPT" ] \
  && [ "$(jq -r '[.facts[] | select((.match_text // "") == "")] | length' "$RECEIPT")" = "0" ] \
  && [ "$(jq -r '.facts[] | select(.citation_key == "mh-fact-one") | .match_text' "$RECEIPT")" \
    = "The staging deploy uses the pinned commit and skips the gate chain entirely" ]; then
  pass "ground: a facts receipt's match_text is the fact content, not an empty string"
else
  fail "ground: a facts receipt's match_text is the fact content, not an empty string" \
    "match_texts=$(jq -c '[.facts[].match_text]' "$RECEIPT" 2>/dev/null)"
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
if grep -q "/grounding/v1/outcome" "$CURL_LOG"; then
  pass "stop: on ⇒ posts to /grounding/v1/outcome"
else
  fail "stop: on ⇒ posts to /grounding/v1/outcome" "log='$(cat "$CURL_LOG")'"
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
if [ "$LAST_RC" -eq 0 ] && grep -q "/grounding/v1/outcome" "$CURL_LOG"; then
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
if grep -q "/grounding/v1/outcome" "$CURL_LOG"; then
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

# ── an EXISTING but EMPTY receipt dir must delete NOTHING (MOL-6325) ─────────
# The case above creates no receipt dir at all, so `[ -d "$receipt_dir" ]` exits
# before the glob is ever expanded — it passes whether or not the glob is safe.
# The destructive precondition is the dir EXISTING and holding no *.json: a turn
# that grounded nothing. `"$receipt_dir"/*.json` is ONE word, so under nullglob a
# glob matching nothing removes the whole word, quoted prefix included. Feed that
# to `ls -t` and it runs with zero arguments, which lists the CURRENT DIRECTORY —
# the worktree root — and every bare filename it returns is then `rm -f`ed.
#
# The fixture has to carry all three discriminators the incident showed, or it
# cannot tell this bug from a working hook: regular files (rm -f takes them), a
# directory (rm without -r refuses it), and a dotfile (ls without -a never lists
# it). Assert the whole listing is byte-identical, not just that one file exists.
reset_case
export MOLLOW_SUPPLY_MODE=on
rdir="$TMPDIR/mollow-supply/sess-NOGLOB"
mkdir -p "$rdir" # exists — and deliberately holds no *.json
root="$CASE/worktree-root"
mkdir -p "$root/webapp"
for f in package.json uv.lock ruff.toml mix.exs README.md; do
  echo "a tracked root file" >"$root/$f"
done
echo "dotfiles survived the incident" >"$root/.gitignore"
ROOT_BEFORE="$(ls -A "$root" | sort | tr '\n' ' ')"
run_hook_cwd "$root" "supply-stop.sh" \
  '{"session_id":"sess-NOGLOB","transcript_path":"/nope","stop_hook_active":false}'
ROOT_AFTER="$(ls -A "$root" | sort | tr '\n' ' ')"
if [ "$ROOT_BEFORE" = "$ROOT_AFTER" ] && [ "$LAST_RC" -eq 0 ] && ! curl_called; then
  pass "stop: existing-but-empty receipt dir deletes nothing in the cwd"
else
  fail "stop: empty receipt dir must not touch the cwd" \
    "before='$ROOT_BEFORE'" "after='$ROOT_AFTER'" "rc=$LAST_RC" "curl='$(cat "$CURL_LOG")'"
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
POSTS="$(grep -c "/grounding/v1/outcome" "$CURL_LOG" 2>/dev/null || echo 0)"
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
#
# The sql_row name CHANGED in MOL-6023, from `mcp__fetch-postgres__execute_sql`
# to `mcp__fetch-rows__fetch_row`. That was not a rename: through `execute_sql`
# the instruction in step 2 — "the bytes exactly as they came back" — had no
# satisfiable reading, because that tool returns a result set and the model had
# to build the canonical JSON array itself, which IS the re-encoding step 2
# forbids.
missing=""
for t in "mcp__fetch-files__fetch_file" "mcp__fetch-rows__fetch_row" "mcp__mollow-memory__verify_fetched_bytes"; do
  printf '%s' "$CTX" | grep -qF "$t" || missing="$missing $t"
done
if [ -z "$missing" ]; then
  pass "pointer: injected context names all three tools by their real names"
else
  fail "pointer: injected context names all three tools" "missing:$missing ctx='$CTX'"
fi

# THE NEGATIVE HALF, and the one that keeps the change from being undone by
# accident. Naming the new tool while ALSO naming execute_sql would leave the
# model free to author SQL for a pointer — the defect intact, with a second
# route beside it. `fetch-postgres` stays CONFIGURED for ad-hoc exploration;
# what it must not be is named as the way to read a locator.
if ! printf '%s' "$CTX" | grep -qF "mcp__fetch-postgres__execute_sql"; then
  pass "pointer: the grounding does NOT route a pointer through execute_sql"
else
  fail "pointer: the grounding does NOT route a pointer through execute_sql" "ctx='$CTX'"
fi

# The instruction has to say the row bytes arrive already canonical. Without
# that sentence a model told "do not re-encode" still has to decide what the
# bytes ARE, which is the ambiguity this whole change removes.
# shellcheck disable=SC2016  # backticks are literal here, not a substitution
if printf '%s' "$CTX" | grep -qF '`bytes` field'; then
  pass "pointer: the sql_row lane names which field carries the bytes"
else
  fail "pointer: the sql_row lane names which field carries the bytes" "ctx='$CTX'"
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

# ── canonical_form, as a COUPLED PAIR (MOL-5979) ─────────────────────────────
# The rule at the top of supply-ground.sh: an instruction that asks the model to
# MENTION something is a change to the matcher's input. The wording and the entry
# lines have to move together, so these assert BOTH halves and then assert the
# COUPLING itself — which is the only one of the three that can fail when the two
# halves drift apart.

if printf '%s' "$CTX" | grep -qF "canonical_form"; then
  pass "pointer: the wording names canonical_form"
else
  fail "pointer: the wording names canonical_form" "ctx='$CTX'"
fi

# Each entry's form on the SAME line as its own hash, for the same reason the
# uri/hash pairing is checked that way: the tool takes all three together and a
# form from the wrong entry is a mismatch that is not real.
af="$(printf '%s' "$CTX" | grep -c 'hash=1111.* canonical_form=file-text-v1' || true)"
bf="$(printf '%s' "$CTX" | grep -c 'hash=2222.* canonical_form=sql-row-text-v1' || true)"
if [ "$af" -eq 1 ] && [ "$bf" -eq 1 ]; then
  pass "pointer: each entry pairs its OWN hash with its OWN canonical_form"
else
  fail "pointer: hash/canonical_form pairing" "alpha=$af order=$bf ctx='$CTX'"
fi

# THE COUPLING TEST. Everything above passes if the wording names the form and
# the entries carry it. Neither can fail when one half is removed and the other
# left — which is the defect the file's own rule exists to prevent. This asserts
# the INVARIANT that ties them: if the instructions tell the model to pass a
# canonical_form, then every entry line must actually supply one.
#
# Written over the emitted text rather than over the source, because the source
# reads correct either way — the two halves live 40 lines apart in one jq
# program.
# `instructed` is measured on the INSTRUCTIONS ALONE — everything before the
# "Entries:" heading. Grepping the whole context made this self-satisfying: the
# entry lines themselves contain "canonical_form=", so removing the form from
# the WORDING left `instructed=1` and the suite green. Found by running the
# perturbation in both directions; one direction alone reds nothing.
INSTR="$(printf '%s' "$CTX" | sed -n '1,/^Entries:/p')"
instructed=0
printf '%s' "$INSTR" | grep -qF "canonical_form" && instructed=1
entry_lines="$(printf '%s' "$CTX" | grep -c '^- ' || true)"
entries_with_form="$(printf '%s' "$CTX" | grep -c '^- .* canonical_form=[^ ]' || true)"
if [ "$instructed" -eq 1 ] && [ "$entry_lines" -gt 0 ] && [ "$entry_lines" -eq "$entries_with_form" ]; then
  pass "pointer: the wording and the entry lines carry canonical_form TOGETHER"
else
  fail "pointer: canonical_form coupling" \
    "instructed=$instructed entries=$entry_lines with_form=$entries_with_form ctx='$CTX'"
fi

# The OTHER direction of the same coupling, as its own case. Entries carrying a
# form the instructions never mention hands the model a value it is not told to
# pass — and omitting canonical_form is the dangerous default (#6240), not a
# neutral one. Asserted on the instruction text rather than on the context, for
# the reason recorded above.
if [ "$entries_with_form" -gt 0 ] && printf '%s' "$INSTR" | grep -qF "canonical_form"; then
  pass "pointer: entries carrying a form are matched by wording that asks for it"
else
  fail "pointer: entries carry a form the wording never mentions" \
    "with_form=$entries_with_form instr='$INSTR'"
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
# than the uri. The original reason was that `execute_sql` never received the
# `pg://` locator at all; since MOL-6023 `fetch_row` DOES take it, so the reason
# is now the other one the matcher gives: a verify carrying the hash is evidence
# that bytes came back AND were checked, where a uri in a fetch is only evidence
# that a fetch was attempted.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-SQL"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-sql-1",grounded_at:$ts,mode:"pointer",facts:[
  {citation_key:"rec-sql",match_text:"pg://orders/42",verify_hash:"HASH_SQL",relevance:0.9}]}' >"$rdir/g-sql-1.json"
tpq="$CASE/tq.jsonl"; ptr_transcript "$tpq" "HASH_SQL" "Read the row and checked it."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-SQL\",\"transcript_path\":\"$tpq\",\"stop_hook_active\":false}"
if grep -q "rec-sql" "$CURL_LOG"; then
  pass "pointer stop: a sql_row entry IS credited (keyed on the hash, not the uri)"
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

# ptr_call <file> <id> <tool-name> <input-json> <result-text> [iso-ts] — appends
# one tool_use and its tool_result. The fixtures above hold ONE verify of ONE
# hash, so none of them can express a call whose bytes mention a second hash, a
# non-verify tool, or a verify from the turn before.
ptr_call() {
  local out="$1" id="$2" name="$3" input="$4" result="$5"
  local ts="${6:-$(date -u +%Y-%m-%dT%H:%M:%S.000Z)}"
  jq -cn --arg id "$id" --arg n "$name" --argjson in "$input" --arg ts "$ts" \
    '{timestamp:$ts,type:"assistant",message:{content:[{type:"tool_use",id:$id,name:$n,input:$in}]}}' >>"$out"
  jq -cn --arg id "$id" --arg r "$result" --arg ts "$ts" \
    '{timestamp:$ts,type:"user",message:{content:[{type:"tool_result",tool_use_id:$id,content:$r}]}}' >>"$out"
}
VERIFY_TOOL="mcp__mollow-memory__verify_fetched_bytes"

# Greptile #6414 (supply-stop.sh:193): credit was a SUBSTRING test over every
# successful call's joined input. A verify of A whose `bytes` happen to contain
# B's hash credited B, which was never checked. Needs TWO supplied hashes with
# only one verified — a one-hash fixture passes either way.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-XB"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-xb-1" "rec-xa:HASH_XA" "rec-xb:HASH_XB"
txb="$CASE/txb.jsonl"; : >"$txb"
ptr_call "$txb" "tu_x" "$VERIFY_TOOL" '{"hash":"HASH_XA","bytes":"a manifest listing HASH_XB"}' '{"outcome":"match"}'
ptr_transcript "$txb.tail" "" "Checked the first one."; cat "$txb.tail" >>"$txb"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-XB\",\"transcript_path\":\"$txb\",\"stop_hook_active\":false}"
if grep -q "rec-xa" "$CURL_LOG" && ! grep -q "rec-xb" "$CURL_LOG"; then
  pass "pointer stop: a hash inside ANOTHER verify's bytes is not credited"
else
  fail "pointer stop: only the verify call's own hash is credited" "log='$(cat "$CURL_LOG")'"
fi

# Same finding, second half: any tool whose result contained `"match"` counted.
# A fetch tool carrying the hash, answering with a `"match"` somewhere in its
# body, is not a verify.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-NV"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-nv-1" "rec-nv:HASH_NV"
tnv="$CASE/tnv.jsonl"; : >"$tnv"
ptr_call "$tnv" "tu_f" "mcp__fetch-files__fetch_file" '{"uri":"file:///c/rec-nv.txt","note":"HASH_NV"}' '{"outcome":"match"}'
ptr_transcript "$tnv.tail" "" "Read it."; cat "$tnv.tail" >>"$tnv"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-NV\",\"transcript_path\":\"$tnv\",\"stop_hook_active\":false}"
if grep -q "g-nv-1" "$CURL_LOG" && ! grep -q "rec-nv" "$CURL_LOG"; then
  pass "pointer stop: a NON-verify tool answering \"match\" does not credit"
else
  fail "pointer stop: only verify_fetched_bytes can credit" "log='$(cat "$CURL_LOG")'"
fi

# Greptile #6449: matching on the `__verify_fetched_bytes` SUFFIX let another MCP
# server's same-named tool earn credit without Mollow's verifier ever running.
# The grounding instructions name mcp__mollow-memory__verify_fetched_bytes, and
# `mollow-memory` is the server name every launcher injects.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-OV"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-ov-1" "rec-ov:HASH_OV"
tov="$CASE/tov.jsonl"; : >"$tov"
ptr_call "$tov" "tu_o" "mcp__other-server__verify_fetched_bytes" '{"hash":"HASH_OV","bytes":"x"}' '{"outcome":"match"}'
ptr_transcript "$tov.tail" "" "Checked it."; cat "$tov.tail" >>"$tov"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-OV\",\"transcript_path\":\"$tov\",\"stop_hook_active\":false}"
if grep -q "g-ov-1" "$CURL_LOG" && ! grep -q "rec-ov" "$CURL_LOG"; then
  pass "pointer stop: another server's verify_fetched_bytes does not credit"
else
  fail "pointer stop: only mollow-memory's verifier can credit" "log='$(cat "$CURL_LOG")'"
fi

# And the outcome is the TOP-LEVEL one. A named-form mismatch lists the forms
# that DID reproduce the digest under `dissenting_canonical_forms`, each with
# its own `"outcome":"match"` — pointer_tools.ex render/1. The quoted-substring
# test read that as a match on a pointer the check refuted.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-DS"; mkdir -p "$rdir"
ptr_receipt "$rdir" "g-ds-1" "rec-ds:HASH_DS"
tds="$CASE/tds.jsonl"; : >"$tds"
ptr_call "$tds" "tu_d" "$VERIFY_TOOL" '{"hash":"HASH_DS","bytes":"..."}' \
  '{"outcome":"mismatch","hash":"HASH_DS","dissenting_canonical_forms":[{"canonical_form":"raw","outcome":"match"}]}'
ptr_transcript "$tds.tail" "" "My form did not match."; cat "$tds.tail" >>"$tds"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-DS\",\"transcript_path\":\"$tds\",\"stop_hook_active\":false}"
if grep -q "g-ds-1" "$CURL_LOG" && ! grep -q "rec-ds" "$CURL_LOG"; then
  pass "pointer stop: a MISMATCH with a dissenting matching form does not credit"
else
  fail "pointer stop: the top-level outcome decides, not a nested one" "log='$(cat "$CURL_LOG")'"
fi

# Greptile #6414 (supply-stop.sh:249): the turn was bounded by `grounded_at`, in
# whole seconds, against transcript timestamps with the fraction stripped. A
# verify at .400 of the grounding second, BEFORE the prompt, passed `>=`. The
# fixture has to put the previous turn's verify INSIDE that second; the "2020"
# case above is a different turn by years and passes under either bound.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-SS"; mkdir -p "$rdir"
grd_iso="$(jq -rn --argjson t "$GRD" '$t | todate | sub("Z$"; "")')"
tss="$CASE/tss.jsonl"; : >"$tss"
ptr_call "$tss" "tu_p" "$VERIFY_TOOL" '{"hash":"HASH_SS","bytes":"..."}' '{"outcome":"match"}' "${grd_iso}.400Z"
off="$(wc -c <"$tss" | tr -d ' ')"
jq -cn --arg ts "${grd_iso}.900Z" '{timestamp:$ts,type:"user",message:{content:"next question"}}' >>"$tss"
jq -cn --arg ts "${grd_iso}.950Z" '{timestamp:$ts,type:"assistant",message:{content:[{type:"text",text:"Answered without checking."}]}}' >>"$tss"
jq -cn --argjson ts "$GRD" --argjson off "$off" '{grounding_id:"g-ss-1",grounded_at:$ts,transcript_offset:$off,mode:"pointer",facts:[
  {citation_key:"rec-ss",match_text:"file:///c/ss.txt",verify_hash:"HASH_SS",relevance:0.9}]}' >"$rdir/g-ss-1.json"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-SS\",\"transcript_path\":\"$tss\",\"stop_hook_active\":false}"
if grep -q "g-ss-1" "$CURL_LOG" && ! grep -q "rec-ss" "$CURL_LOG"; then
  pass "pointer stop: a verify BEFORE this prompt, in the same second, does not credit"
else
  fail "pointer stop: same-second previous-turn verify must not credit" "log='$(cat "$CURL_LOG")'"
fi

# The boundary cuts only BACKWARDS: a verify after the offset, in that same
# second, is this turn's and still credits.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-SN"; mkdir -p "$rdir"
tsn="$CASE/tsn.jsonl"
jq -cn --arg ts "${grd_iso}.100Z" '{timestamp:$ts,type:"user",message:{content:"earlier question"}}' >"$tsn"
off="$(wc -c <"$tsn" | tr -d ' ')"
ptr_call "$tsn" "tu_n" "$VERIFY_TOOL" '{"hash":"HASH_SN","bytes":"..."}' '{"outcome":"match"}' "${grd_iso}.600Z"
jq -cn --argjson ts "$GRD" --argjson off "$off" '{grounding_id:"g-sn-1",grounded_at:$ts,transcript_offset:$off,mode:"pointer",facts:[
  {citation_key:"rec-sn",match_text:"file:///c/sn.txt",verify_hash:"HASH_SN",relevance:0.9}]}' >"$rdir/g-sn-1.json"
run_hook "supply-stop.sh" "{\"session_id\":\"sess-SN\",\"transcript_path\":\"$tsn\",\"stop_hook_active\":false}"
if grep -q "rec-sn" "$CURL_LOG"; then
  pass "pointer stop: a verify AFTER the offset credits, even in the grounding second"
else
  fail "pointer stop: this turn's verify must still credit" "log='$(cat "$CURL_LOG")'"
fi

# The Stop side is only half: the offset has to be WRITTEN at UserPromptSubmit,
# as the transcript's size then, or the bound above never exists in real use.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
cat >"$CASE/pointer-off.json" <<'JSON'
{"grounding_id":"g-off-1","mode":"pointer","facts":[
  {"citation_key":"rec-off","hash":"4444444444444444444444444444444444444444444444444444444444444444",
   "locator":{"kind":"file","uri":"file:///corpus/off.txt","hash_version":"sha256"},
   "canonical_form":"raw","title":"Off doc"}
]}
JSON
export CURL_BODY_FILE="$CASE/pointer-off.json"
tof="$CASE/tof.jsonl"; printf '%s\n' '{"type":"user","message":{"content":"hi"}}' '{"type":"assistant","message":{"content":"hello"}}' >"$tof"
want_off="$(wc -c <"$tof" | tr -d ' ')"
run_hook "supply-ground.sh" "{\"prompt\":\"q\",\"session_id\":\"sess-OFF\",\"cwd\":\"/tmp\",\"transcript_path\":\"$tof\"}"
got_off="$(jq -r '.transcript_offset // "absent"' "$TMPDIR/mollow-supply/sess-OFF/g-off-1.json" 2>/dev/null || echo unreadable)"
if [ "$got_off" = "$want_off" ]; then
  pass "pointer ground: the receipt records the transcript's size at prompt time"
else
  fail "pointer ground: transcript_offset" "want=$want_off got=$got_off"
fi

# Greptile #6414 (supply-stop.sh:164): a receipt written by the hook BEFORE the
# upgrade carries `message_hash` + `content`, not `citation_key` + `match_text`.
# A turn that spans the upgrade must still be matched — the fixture has to be
# in the OLD shape, which no receipt the current ground hook writes can be.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/outcome.json"; echo '{"status":"ok"}' >"$CASE/outcome.json"
rdir="$TMPDIR/mollow-supply/sess-LEG"; mkdir -p "$rdir"
jq -cn --argjson ts "$GRD" '{grounding_id:"g-leg-1",grounded_at:$ts,facts:[
  {message_hash:"mh-legacy",content:"the deploy pipeline pins every base image by digest before release",relevance:0.9}]}' >"$rdir/g-leg-1.json"
tlg="$CASE/tlg.jsonl"
ptr_transcript "$tlg" "" "As noted, the deploy pipeline pins every base image by digest before release."
run_hook "supply-stop.sh" "{\"session_id\":\"sess-LEG\",\"transcript_path\":\"$tlg\",\"stop_hook_active\":false}"
if grep -q "mh-legacy" "$CURL_LOG"; then
  pass "stop: a pre-upgrade receipt (message_hash + content) still credits its citation"
else
  fail "stop: legacy receipt fields must be read" "log='$(cat "$CURL_LOG")'"
fi

# ── an entry with NO form omits the token rather than emitting it empty ───────
# `canonical_form=` with nothing after it reads as a value; the model passes ""
# and the tool refuses it outright, which is strictly worse than omitting the
# argument. `list_pointers/2` excludes formless records so nothing reaches this
# today — which is exactly why it needs a fixture rather than a reader's trust.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
cat >"$CASE/pointer-noform.json" <<'JSON'
{"grounding_id":"g-ptr-noform","mode":"pointer","facts":[
  {"citation_key":"rec-ccc","hash":"3333333333333333333333333333333333333333333333333333333333333333",
   "locator":{"kind":"file","uri":"file:///corpus/gamma.txt","hash_version":"sha256"},
   "title":"Gamma doc"}
]}
JSON
export CURL_BODY_FILE="$CASE/pointer-noform.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-NOFORM","cwd":"/tmp"}'
NCTX="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"

if printf '%s' "$NCTX" | grep -qF 'uri=file:///corpus/gamma.txt' \
  && ! printf '%s' "$NCTX" | grep -qE 'canonical_form=($| )'; then
  pass "pointer: an entry with no canonical_form omits the token, never emits it empty"
else
  fail "pointer: empty canonical_form token" "ctx='$NCTX'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# supply-ground.sh — the hook SAYS something when the server refuses (MOL-5978)
# ═══════════════════════════════════════════════════════════════════════════
# The defect being fixed is SILENCE, so every case here asserts that something
# was emitted and what it says. A test that only checked "exit 0" passes whether
# or not the fix is present — that is the shape of the bug itself.

# A 400 is the measured real case: MOLLOW_SUPPLY_WORKSPACE_ID unset with a
# workspace-scoped key. The curl path shows it; this path showed nothing.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=400
echo '{"error":"workspace_not_named"}' >"$CASE/err.json"
export CURL_BODY_FILE="$CASE/err.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-400","cwd":"/tmp"}'
ECTX="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if [ "$LAST_RC" -eq 0 ] && printf '%s' "$ECTX" | grep -qF "MOLLOW_SUPPLY_WORKSPACE_ID"; then
  pass "status: a 400 names the workspace variable instead of failing silently"
else
  fail "status: 400 must be surfaced" "rc=$LAST_RC ctx='$ECTX' out='$LAST_OUT'"
fi
unset CURL_STATUS

# 403 workspace_not_yours: the workspace id names someone else's workspace. The
# hint must point at the WORKSPACE variable, not the key — Greptile caught this
# pointing at MOLLOW_MEMORY_API_KEY, which sends the operator to troubleshoot a
# credential that is fine. One fixture per reachable code, because the codes
# differ in WHICH variable is wrong and that is the only useful part.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=403
echo '{"error":{"type":"workspace_not_yours"}}' >"$CASE/e403.json"
export CURL_BODY_FILE="$CASE/e403.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-403","cwd":"/tmp"}'
E3="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if [ "$LAST_RC" -eq 0 ] \
  && printf '%s' "$E3" | grep -qF "MOLLOW_SUPPLY_WORKSPACE_ID" \
  && ! printf '%s' "$E3" | grep -qF "MOLLOW_MEMORY_API_KEY"; then
  pass "status: a 403 points at the workspace id, NOT the key"
else
  fail "status: 403 must name the workspace id and not the key" "rc=$LAST_RC ctx='$E3'"
fi
unset CURL_STATUS

# THE OTHER 403, and the reason the one above is not enough on its own. Two
# DIFFERENT refusals share this status and need OPPOSITE actions:
#
#   JSON  {"error":{"type":"workspace_not_yours"}}  -> the app; fix the workspace id
#   HTML  <!DOCTYPE html> ... Cloudflare ...        -> the EDGE; the request never
#                                                     reached Phoenix at all
#
# The app 403 is real and reachable — `tenant.ex:115` `verify_workspace/2` returns
# `:workspace_not_yours` for a workspace id that is malformed, absent, or someone
# else's, and `ground_controller.ex:206` renders it 403. So the fix is NOT "treat
# every 403 as the edge"; it is to READ THE BODY, the same correction the 422
# branch already took (Greptile #6251).
#
# This fixture is the one that matters once MOLLOW_SUPPLY_WORKSPACE_ID is actually
# set, because from then on both 403s are plausible and asserting the wrong one
# sends the operator to edit a variable that is already correct.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=403
# A real Cloudflare refusal body: HTML, so it carries no `error.type` at all.
cat >"$CASE/e403html.json" <<'HTMLBODY'
<!DOCTYPE html><html><head><title>Just a moment...</title></head>
<body><div class="cf-error-details">Sorry, you have been blocked</div></body></html>
HTMLBODY
export CURL_BODY_FILE="$CASE/e403html.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-403-edge","cwd":"/tmp"}'
E3H="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if [ "$LAST_RC" -eq 0 ] \
  && printf '%s' "$E3H" | grep -qiF "edge" \
  && ! printf '%s' "$E3H" | grep -qF "MOLLOW_SUPPLY_WORKSPACE_ID"; then
  pass "status: a 403 with NO error.type is named as the edge, not the workspace id"
else
  fail "status: an HTML 403 must be attributed to the edge, not MOLLOW_SUPPLY_WORKSPACE_ID" \
    "rc=$LAST_RC ctx='$E3H'"
fi
# The hint must never echo the HTML it read — that body is an upstream error page
# and pasting it in front of the operator is noise at best.
if ! printf '%s' "$E3H" | grep -qF "<!DOCTYPE"; then
  pass "status: the edge hint does not paste the upstream HTML body"
else
  fail "status: the edge hint leaked the HTML body" "ctx='$E3H'"
fi
unset CURL_STATUS

# 422 covers several unrelated causes, so the hint reads the body's error.type
# rather than guessing from the status. One fixture per type, because guessing
# was wrong in a way a single fixture could not show: naming invalid_mode blamed
# pointer_mode for a blank query, and in FACTS mode invalid_mode is not reachable
# at all, so the guess was wrong for every 422 that path can produce.
for pair in "query_required:trimmed" "invalid_mode:pointer_mode" "request_required:prompt mode"; do
  ty="${pair%%:*}"; want="${pair#*:}"
  reset_case
  export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
  export CURL_STATUS=422
  printf '{"error":{"type":"%s"}}' "$ty" >"$CASE/e422.json"
  export CURL_BODY_FILE="$CASE/e422.json"
  run_hook "supply-ground.sh" "{\"prompt\":\"q\",\"session_id\":\"sess-422-$ty\",\"cwd\":\"/tmp\"}"
  E22="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
  if [ "$LAST_RC" -eq 0 ] && printf '%s' "$E22" | grep -qF "$ty" && printf '%s' "$E22" | grep -qF "$want"; then
    pass "status: a 422 $ty names its own cause, not a guessed one"
  else
    fail "status: 422 $ty must name its own cause" "rc=$LAST_RC want='$want' ctx='$E22'"
  fi
  unset CURL_STATUS
done

# The negative half: a 422 whose body names no type must NOT assert a cause.
# Without this, "read error.type" could fall back to the old guess and pass.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=422
echo '{}' >"$CASE/e422x.json"
export CURL_BODY_FILE="$CASE/e422x.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-422x","cwd":"/tmp"}'
EX="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if [ "$LAST_RC" -eq 0 ] \
  && printf '%s' "$EX" | grep -qF "422" \
  && ! printf '%s' "$EX" | grep -qE 'pointer_mode|query_required|request_required'; then
  pass "status: a typeless 422 states the code and asserts no cause"
else
  fail "status: typeless 422 must not guess a cause" "rc=$LAST_RC ctx='$EX'"
fi
unset CURL_STATUS

# A whitespace-only prompt never reaches the network. It passes `[ -z ]`, and the
# server trims it and refuses — so the hook used to spend its whole 2s budget to
# be told there was nothing to ground.
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"   \t  ","session_id":"sess-blank","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && [ -z "$LAST_OUT" ] && ! curl_called; then
  pass "ground: a whitespace-only prompt is skipped before the request"
else
  fail "ground: whitespace-only prompt must not call out" \
    "rc=$LAST_RC out='$LAST_OUT' curl='$(cat "$CURL_LOG")'"
fi


# A 404 is what an operator who opted in but has supply_mode off actually gets,
# and it must not read as an empty register.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=404
echo '{"error":{"type":"not_found"}}' >"$CASE/e404.json"
export CURL_BODY_FILE="$CASE/e404.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-404","cwd":"/tmp"}'
E4="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if [ "$LAST_RC" -eq 0 ] && printf '%s' "$E4" | grep -qF "supply_mode"; then
  pass "status: a 404 names the flag/key/header causes"
else
  fail "status: 404 must be surfaced" "rc=$LAST_RC ctx='$E4'"
fi
# ...and the PATH, which it did not name. The hooks hardcode the wire path
# (`supply-ground.sh` builds `$(mm_api_base)$path`) and no env var can repoint
# them, so a half-landed path rename produces exactly this 404 — and an operator
# handed "flag, key, or header" will check all three, find them correct, and have
# nowhere left to look.
#
# Asserted on the LITERAL wire path, not on the word "path" or "endpoint". The
# loose version PASSED before the fix existed, because the message already said
# "the grounding ENDPOINT answered 404" — it matched a word that was always there
# rather than the cause being added. The literal path is also the useful thing: it
# tells the operator which path the hook actually asked for.
# The FULL path, including the final segment. Greptile caught this one segment
# short (#6375): `/grounding/v1` still matches if the path drifts to a different
# action under the same scope, which is a realistic half-landed rename and exactly
# the 404 this branch exists to explain. Second tightening of this assertion — the
# first version matched the word "endpoint" and passed before the fix existed.
if printf '%s' "$E4" | grep -qF "/grounding/v1/ground"; then
  pass "status: a 404 names the full literal wire path it requested"
else
  fail "status: 404 must name the wire path — a stale path 404s identically" "ctx='$E4'"
fi
unset CURL_STATUS

# THE NEGATIVE HALF. A timeout stays silent — it is transient, the hook is capped
# at 2s, and a line in front of the operator on every slow turn is its own
# defect. Without this, "surface every non-200" would pass the two cases above
# and be wrong.
reset_case
export MOLLOW_SUPPLY_MODE=on MOLLOW_SUPPLY_POINTER_MODE=on
export CURL_STATUS=000
: >"$CASE/empty.json"
export CURL_BODY_FILE="$CASE/empty.json"
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-000","cwd":"/tmp"}'
if [ "$LAST_RC" -eq 0 ] && [ -z "$LAST_OUT" ]; then
  pass "status: a timeout (000) stays silent rather than nagging every slow turn"
else
  fail "status: 000 must stay silent" "rc=$LAST_RC out='$LAST_OUT'"
fi
unset CURL_STATUS

# And a 200 still grounds. The status plumbing sits between the request and every
# existing behaviour, so this pins that it did not eat the happy path.
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"q","session_id":"sess-200","cwd":"/tmp"}'
# facts mode deliberately: reset_case now unsets the pointer opt-in, so this
# exercises the shipped default path rather than inheriting the previous case.
if printf '%s' "$LAST_OUT" | jq -e '.hookSpecificOutput.additionalContext | test("pinned commit")' >/dev/null 2>&1; then
  pass "status: a 200 still grounds and injects normally"
else
  fail "status: 200 must still ground" "out='$LAST_OUT'"
fi

# The body must survive the status line being prepended — a split that returned
# the status as the body would make every response unparseable downstream, and
# the receipt is where that shows.
if printf '%s' "$LAST_OUT" | jq -e '.hookSpecificOutput.additionalContext | test("^200") | not' >/dev/null 2>&1; then
  pass "status: the status line is stripped from the body, not injected"
else
  fail "status: status line leaked into the body" "out='$LAST_OUT'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# Explicit citation tags (facts mode) — the wording and the matcher, together
# ═══════════════════════════════════════════════════════════════════════════
#
# The 8-word verbatim run credited 7 of 239 dogfood turns on Production: a model
# that USES a fact rarely quotes eight words of it. So facts are now shown with a
# tag and the model is asked to cite the tag; the matcher credits the tag OR the
# verbatim run. These cases are the coupled pair — each ground-side case has a
# stop-side case reading what it wrote.

# ── ground: each fact is injected with its tag, and the receipt records it ────
reset_case
export MOLLOW_SUPPLY_MODE=on
ground_body
run_hook "supply-ground.sh" '{"prompt":"how do releases work","session_id":"sess-TAG","cwd":"/tmp"}'
CTX="$(printf '%s' "$LAST_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null)"
if printf '%s' "$CTX" | grep -qF -- '- [fact-1] Pinned release: ' \
   && printf '%s' "$CTX" | grep -qF -- '- [fact-2] Test DB: ' \
   && printf '%s' "$CTX" | grep -qiF 'cite its tag'; then
  pass "tags: each fact is injected with its [fact-N] tag and a cite-by-tag instruction"
else
  fail "tags: injected context carries [fact-N] tags + instruction" "ctx='$CTX'"
fi
RECEIPT="$(find "$TMPDIR" -name 'g-abc-123.json' 2>/dev/null | head -1)"
if [ -n "$RECEIPT" ] \
   && [ "$(jq -r '[.facts[] | "\(.citation_key)=\(.label)"] | join(",")' "$RECEIPT")" = "mh-fact-one=fact-1,mh-fact-two=fact-2" ]; then
  pass "tags: the receipt pairs each citation_key with the tag it was shown under"
else
  fail "tags: receipt labels" "receipt='$(cat "$RECEIPT" 2>/dev/null)'"
fi

# stop_case <session> <receipt-json> <transcript-lines…> — runs supply-stop.sh
# and leaves the posted log in $POSTED.
stop_case() {
  local sess="$1" receipt="$2"
  shift 2
  export CURL_BODY_FILE="$CASE/outcome.json"
  echo '{"status":"ok"}' >"$CASE/outcome.json"
  local rdir="$TMPDIR/mollow-supply/$sess"
  mkdir -p "$rdir"
  local gid
  gid="$(printf '%s' "$receipt" | jq -r .grounding_id)"
  printf '%s' "$receipt" >"$rdir/$gid.json"
  TP="$CASE/transcript-$sess.jsonl"
  : >"$TP"
  for line in "$@"; do printf '%s\n' "$line" >>"$TP"; done
  run_hook "supply-stop.sh" "{\"session_id\":\"$sess\",\"transcript_path\":\"$TP\",\"stop_hook_active\":false}"
  POSTED="$(cat "$CURL_LOG")"
}
asst() { jq -cn --arg t "$1" '{type:"assistant",message:{role:"assistant",content:[{type:"text",text:$t}]}}'; }
usr() { jq -cn --arg t "$1" '{type:"user",message:{role:"user",content:[{type:"text",text:$t}]}}'; }
TAGGED='{"grounding_id":"g-tag","grounded_at":100,"transcript_offset":0,"mode":"facts","facts":[
 {"citation_key":"mh-one","label":"fact-1","match_text":"the staging deploy uses the pinned commit and skips the gate chain"},
 {"citation_key":"mh-two","label":"fact-2","match_text":"the postgres test database is named mollow_test and lives in docker compose"}]}'

# ── stop: a tag with NO verbatim run credits exactly that fact ────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T1 "$TAGGED" "$(usr "where do tests run")" "$(asst "Against mollow_test in compose [fact-2].")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-two"\]'; then
  pass "tags: a cited tag credits its fact with no verbatim run (mh-two only)"
else
  fail "tags: a cited tag credits its fact" "posted='$POSTED'"
fi

# ── stop: [fact-12] must not credit fact-1 — the tag is matched WHOLE ─────────
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T2 "$TAGGED" "$(usr "q")" "$(asst "See [fact-12] and [fact-21] for more.")"
if printf '%s' "$POSTED" | grep -q '/grounding/v1/outcome' && ! printf '%s' "$POSTED" | grep -q 'used_fact_ids'; then
  pass "tags: [fact-12] / [fact-21] credit nothing — no prefix match on a tag"
else
  fail "tags: tag must be matched whole" "posted='$POSTED'"
fi

# ── stop: tag case does not matter ───────────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T3 "$TAGGED" "$(usr "q")" "$(asst "Use the pinned build [Fact-1].")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one"\]'; then
  pass "tags: [Fact-1] credits fact-1 (case-insensitive)"
else
  fail "tags: case-insensitive tag" "posted='$POSTED'"
fi

# ── stop: a tag in an EARLIER assistant message of this turn counts ───────────
# Agentic turns cite mid-turn and end on a summary. Reading only the last
# assistant message was the other half of the 7-in-239.
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T4 "$TAGGED" \
  "$(usr "fix the release")" \
  "$(asst "Checking the pinned build first [fact-1].")" \
  "$(jq -cn '{type:"user",message:{role:"user",content:[{type:"tool_result",tool_use_id:"t1",content:"ok"}]}}')" \
  "$(asst "Done — the release is out.")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one"\]'; then
  pass "tags: a tag in an earlier assistant message of THIS turn is credited"
else
  fail "tags: mid-turn citation" "posted='$POSTED'"
fi

# ── stop: an early tag survives a turn longer than the 500-line tail window ───
# Greptile #6483: the offset-bounded window was further cut with `tail -n 500`,
# so an agentic turn producing more than 500 lines after the offset could push
# an early citation out of the window this reader searches — dropping it from
# used_fact_ids even though the model cited it this turn.
reset_case
export MOLLOW_SUPPLY_MODE=on
FILLER=()
for i in $(seq 1 600); do
  FILLER+=("$(usr "filler turn $i")")
done
stop_case sess-T4B "$TAGGED" \
  "$(asst "Checking the pinned build first [fact-1].")" \
  "${FILLER[@]}" \
  "$(asst "Done — the release is out.")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one"\]'; then
  pass "tags: an early tag survives a turn longer than the 500-line tail window"
else
  fail "tags: early tag lost past the 500-line tail window" "posted='$POSTED'"
fi

# ── stop: an answer too large for argv still matches (via file, not exec arg) ─
# Greptile #6483 (round 2): match_used passes the whole turn's answer to jq as
# a `--arg`, i.e. a process argument. Facts mode now reads the WHOLE turn
# (uncapped, per the fix above), so a long enough agentic turn's answer can
# exceed the OS's single-exec argument limit — jq then fails to even start,
# and the `|| printf '[]'` fallback silently drops every citation in the turn.
# Built with printf/tr (no subprocess sees the big string as an argv) so the
# test exercises supply-stop.sh's own argv use, not the harness's.
reset_case
export MOLLOW_SUPPLY_MODE=on
BIG_TEXT="$(head -c 2000000 /dev/zero | tr '\0' 'a')"
BIG_LINE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"'"$BIG_TEXT"' [fact-1]"}]}}'
stop_case sess-T4C "$TAGGED" "$(usr "q")" "$BIG_LINE"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one"\]'; then
  pass "tags: an answer too large for argv still matches (passed via file, not an exec argument)"
else
  fail "tags: an oversized answer must still be matched" "posted='$POSTED'"
fi

# ── stop: an ordinary small turn never touches a temp file ────────────────────
# Greptile #6483 (round 3): writing the answer to a temp file UNCONDITIONALLY
# gave every match — including pointer mode's typically-tiny $tools, which
# previously needed no filesystem at all — a new dependency on a writable
# TMPDIR, and a receipt with no verbatim run before this would never have
# touched disk. Only an answer large enough to risk the argv limit should.
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T4D "$TAGGED" "$(usr "where do tests run")" "$(asst "Against mollow_test in compose [fact-2].")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-two"\]' \
   && ! grep -q 'mm-supply' "$MKTEMP_LOG"; then
  pass "tags: an ordinary small turn matches without creating a temp file"
else
  fail "tags: ordinary turn must not touch a temp file" \
    "posted='$POSTED'" "mktemp_log='$(cat "$MKTEMP_LOG")'"
fi

# ── stop: the oversized-answer path cleans up its temp files ──────────────────
# The other half of round 3: if the Stop hook is interrupted between writing
# the answer to its temp file and reaching `rm`, that file leaks — a long turn
# can leave a large copy of its own text behind, and repeated interruptions
# accumulate. This asserts the normal-completion path (a RETURN trap) cleans
# up; an actual mid-flight interruption cannot be simulated portably here.
reset_case
export MOLLOW_SUPPLY_MODE=on
BIG_TEXT2="$(head -c 2000000 /dev/zero | tr '\0' 'a')"
BIG_LINE2='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"'"$BIG_TEXT2"' [fact-1]"}]}}'
stop_case sess-T4E "$TAGGED" "$(usr "q")" "$BIG_LINE2"
if grep -q 'mm-supply' "$MKTEMP_LOG" \
   && ! find "$TMPDIR" -maxdepth 1 -name 'mm-supply-*' 2>/dev/null | grep -q .; then
  pass "tags: the oversized-answer path removes its temp files on normal completion"
else
  fail "tags: oversized-answer temp files must not leak" \
    "mktemp_log='$(cat "$MKTEMP_LOG")'" "tmp='$(find "$TMPDIR" -maxdepth 1 -name 'mm-supply-*' 2>/dev/null)'"
fi

# ── stop: the size threshold counts BYTES, not characters (UTF-8) ─────────────
# Greptile #6483 (round 4): bash's `${#var}` counts CHARACTERS under a UTF-8
# locale, but the exec/kernel per-argument limit is a BYTE limit. A turn built
# from enough multi-byte characters can stay under a character-counted
# threshold while its byte size is well over it, so it silently stayed on the
# argv path instead of being routed to the file-backed one — exactly the
# argv-limit failure round 2 fixed, reintroduced for any non-ASCII answer.
reset_case
export MOLLOW_SUPPLY_MODE=on
# `export LC_ALL=en_US.UTF-8` falls back to the shell's inherited locale
# SILENTLY when that locale isn't installed (common on minimal CI images) —
# glibc/bash print a warning but do not error. In that fallback, `${#ans}`
# can end up counting BYTES, and the old character-counting bug would then
# take the same (correct) file-backed path as the fix, passing whether or not
# the regression is present. So verify the multibyte behavior actually landed
# — on a 1-character 3-byte string, ${#} must read 1 — before trusting the
# assertion below; search `locale -a` for one that truly does (Greptile,
# #6483 round 5).
CHAR=$'\xe4\xb8\xad' # U+4E2D ("中"), 3 bytes in UTF-8, 1 character
UTF8_LOCALE=""
for cand in en_US.UTF-8 en_US.utf8 C.UTF-8 C.utf8 $(locale -a 2>/dev/null | grep -i 'utf-\?8'); do
  if [ "$(LC_ALL="$cand" bash -c 'a=$'"'"'\xe4\xb8\xad'"'"'; printf %s "${#a}"' 2>/dev/null)" = "1" ]; then
    UTF8_LOCALE="$cand"
    break
  fi
done
if [ -z "$UTF8_LOCALE" ]; then
  fail "tags: the size threshold is byte-based, not character-based (UTF-8 safe)" \
    "no locale on this host makes bash count multibyte characters — this test cannot exercise the byte-vs-char distinction" \
    "locale -a: $(locale -a 2>/dev/null | tr '\n' ' ')"
else
  export LC_ALL="$UTF8_LOCALE"
  # 30,000 of the character above: 30,000 characters (under a 65536 CHARACTER
  # threshold) but 90,000 bytes (over a 65536 BYTE threshold).
  MULTIBYTE_TEXT="$(yes "$CHAR" | head -n 30000 | tr -d '\n')"
  MULTIBYTE_LINE='{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"'"$MULTIBYTE_TEXT"' [fact-1]"}]}}'
  stop_case sess-T4F "$TAGGED" "$(usr "q")" "$MULTIBYTE_LINE"
  if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one"\]' \
     && grep -q 'mm-supply' "$MKTEMP_LOG"; then
    pass "tags: the size threshold is byte-based, not character-based (UTF-8 safe)"
  else
    fail "tags: a multibyte answer over the BYTE threshold must use the file path" \
      "locale='$UTF8_LOCALE'" "posted='$POSTED'" "mktemp_log='$(cat "$MKTEMP_LOG")'"
  fi
fi

# ── stop: a tag from the PREVIOUS turn (before transcript_offset) does not ────
reset_case
export MOLLOW_SUPPLY_MODE=on
PREV="$(usr "earlier question")
$(asst "Earlier answer citing [fact-2].")"
prev_bytes="$(printf '%s\n' "$PREV" | wc -c | tr -d ' ')"
OFFSET_RECEIPT="$(printf '%s' "$TAGGED" | jq -c --argjson o "$prev_bytes" '.transcript_offset = $o | .grounding_id = "g-tag-prev"')"
stop_case sess-T5 "$OFFSET_RECEIPT" \
  "$(usr "earlier question")" "$(asst "Earlier answer citing [fact-2].")" \
  "$(usr "new question")" "$(asst "Unrelated reply with no citation.")"
if printf '%s' "$POSTED" | grep -q '/grounding/v1/outcome' && ! printf '%s' "$POSTED" | grep -q 'used_fact_ids'; then
  pass "tags: a tag written before this turn's transcript_offset is not credited"
else
  fail "tags: previous-turn tag must not credit" "posted='$POSTED'"
fi

# ── stop: a receipt with NO labels (old ground hook) does not credit on a tag ─
reset_case
export MOLLOW_SUPPLY_MODE=on
UNLABELLED="$(printf '%s' "$TAGGED" | jq -c '.grounding_id = "g-old-shape" | .facts |= map(del(.label))')"
stop_case sess-T6 "$UNLABELLED" "$(usr "q")" "$(asst "Against mollow_test in compose [fact-2].")"
if ! printf '%s' "$POSTED" | grep -q 'used_fact_ids'; then
  pass "tags: an unlabelled (pre-tag) receipt credits nothing from a tag it never showed"
else
  fail "tags: unlabelled receipt must not credit a tag" "posted='$POSTED'"
fi

# ── stop: the verbatim run still credits alongside a tag (union, no regression) ─
reset_case
export MOLLOW_SUPPLY_MODE=on
stop_case sess-T7 "$TAGGED" "$(usr "q")" \
  "$(asst "The staging deploy uses the pinned commit and skips the gate chain; tests use [fact-2].")"
if printf '%s' "$POSTED" | grep -q '"used_fact_ids":\["mh-one","mh-two"\]'; then
  pass "tags: verbatim run (fact-1) and tag (fact-2) are both credited"
else
  fail "tags: verbatim + tag union" "posted='$POSTED'"
fi

# ═══════════════════════════════════════════════════════════════════════════
# supply-stop.sh — the decline reason is RECORDED (MOL-7981)
# ═══════════════════════════════════════════════════════════════════════════
#
# Measured on production 2026-10-26: 37% of groundings in the dogfood workspace
# NEVER get an outcome row, steady across 30 days, and the share does not fall
# with grounding age — so a working hook would have posted days ago. The split
# of `no_outcome` from `claim_unrecorded` (MOL-7976) localised the whole gap to
# "the outcome row never arrived", and then the trail stopped: this hook exits 0
# on seven distinct paths after the opt-in guard and NONE of them is observable.
# The cause is not in the database and cannot be put there.
#
# So the reason is written locally. These cases pin the two properties that make
# the log usable, and the one that makes it safe:
#
#   * every decline names WHICH path, so the 37% can be attributed;
#   * a SUCCESS is logged too — a failure-only log is a numerator with no
#     denominator, and "47 declines" says nothing without the turns that worked;
#   * with the opt-in unset NOTHING is written, because both hooks load into
#     every session on the machine and a log that grows on every developer's
#     every turn is a cost paid by people who never opted in.

# Run "$@" with a deadline, without depending on GNU coreutils. `timeout` is
# NOT on a stock macOS install — the one on this machine is
# /opt/homebrew/bin/timeout, a Homebrew symlink — and these hooks run on macOS.
# A bare `timeout` call returns 127 having run nothing, which an assertion that
# only excludes 124 reads as a pass (Greptile, #7502). Same shape as
# `run_with_timeout` in scripts/check-bridge-build-env.sh, and the same trap
# scripts/claude-quota-state.sh records from Greptile P1 on #6564.
#
# Returns 124 on the deadline, like timeout(1), so a caller can tell a hang from
# a failure.
run_bounded() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?; fi

  "$@" &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid"
}

reasons_log() { printf '%s' "$HOME/.mollow/supply-stop-reasons.log"; }
reason_lines() { cat "$(reasons_log)" 2>/dev/null || true; }

# ── opt-in unset ⇒ the log is never even created ─────────────────────────────
# The isolation this asserts comes from `reset_case`, which points HOME at
# "$CASE/home" (see its body above) — so `$(reasons_log)` is a path no earlier
# case can have written. Named here because the guarantee is invisible from this
# body alone, and `[ ! -e ... ]` against a shared HOME would be meaningless.
reset_case
rdir="$TMPDIR/mollow-supply/sess-NL"
mkdir -p "$rdir"
echo '{"grounding_id":"g-nl","grounded_at":100,"facts":[]}' >"$rdir/g-nl.json"
run_hook "supply-stop.sh" '{"session_id":"sess-NL","transcript_path":"/nope","stop_hook_active":false}'
if [ "$LAST_RC" -eq 0 ] && [ ! -e "$(reasons_log)" ]; then
  pass "reasons: opt-in unset ⇒ no log file written at all"
else
  fail "reasons: opt-in unset must write nothing" "rc=$LAST_RC lines='$(reason_lines)'"
fi

# ── re-entrancy is recorded, not silent ──────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
rdir="$TMPDIR/mollow-supply/sess-RE"
mkdir -p "$rdir"
echo '{"grounding_id":"g-re","grounded_at":100,"facts":[]}' >"$rdir/g-re.json"
run_hook "supply-stop.sh" '{"session_id":"sess-RE","transcript_path":"/nope","stop_hook_active":true}'
if printf '%s' "$(reason_lines)" | grep -q 'reentrant'; then
  pass "reasons: re-entrant stop records 'reentrant'"
else
  fail "reasons: re-entrant stop" "lines='$(reason_lines)'"
fi

# ── no receipt directory is recorded ─────────────────────────────────────────
reset_case
export MOLLOW_SUPPLY_MODE=on
run_hook "supply-stop.sh" '{"session_id":"sess-ND","transcript_path":"/nope","stop_hook_active":false}'
if printf '%s' "$(reason_lines)" | grep -q 'no_receipt_dir'; then
  pass "reasons: missing receipt dir records 'no_receipt_dir'"
else
  fail "reasons: missing receipt dir" "lines='$(reason_lines)'"
fi

# ── a SUCCESS is recorded, so the declines have a denominator ────────────────
# `stored: true` is what makes it a success. A 200 is not enough — see the
# post_unstored case below.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/ok.json"
echo '{"grounding_id":"g-ok","status":"ok","stored":true}' >"$CURL_BODY_FILE"
rdir="$TMPDIR/mollow-supply/sess-OK"
mkdir -p "$rdir"
echo '{"grounding_id":"g-ok","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-ok.json"
run_hook "supply-stop.sh" '{"session_id":"sess-OK","transcript_path":"/nope","stop_hook_active":false}'
if [ "$(cut -f4 "$(reasons_log)" 2>/dev/null)" = "posted" ]; then
  pass "reasons: a stored post-back records exactly 'posted' (the denominator)"
else
  fail "reasons: successful post-back" "lines='$(reason_lines)' curl='$(cat "$CURL_LOG")'"
fi

# ── THE RECORD SHAPE, asserted field by field ───────────────────────────────
# The first version of these cases only grepped for the reason WORD, so
# dropping or swapping the id columns — or deleting the sanitizer — left them
# green while breaking the documented joins (Greptile, #7502). The join is the
# reason the grounding id is on the line at all, so it is asserted exactly.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/shape.json"
echo '{"stored":true}' >"$CURL_BODY_FILE"
rdir="$TMPDIR/mollow-supply/sess-SHAPE"
mkdir -p "$rdir"
echo '{"grounding_id":"g-shape-77","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g.json"
run_hook "supply-stop.sh" '{"session_id":"sess-SHAPE","transcript_path":"/nope","stop_hook_active":false}'
line="$(tail -1 "$(reasons_log)" 2>/dev/null || true)"
nfields="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
if [ "$nfields" = "4" ] &&
  [ "$(printf '%s' "$line" | cut -f2)" = "sess-SHAPE" ] &&
  [ "$(printf '%s' "$line" | cut -f3)" = "g-shape-77" ] &&
  [ "$(printf '%s' "$line" | cut -f4)" = "posted" ] &&
  printf '%s' "$line" | cut -f1 | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'; then
  pass "reasons: the record is 4 tab-separated fields — ts, session, grounding, reason"
else
  fail "reasons: record shape" "fields=$nfields line='$line'"
fi

# ── a decline with no grounding id uses '-', not an empty field ─────────────
# An empty third field would shift `cut -f4` onto nothing and silently break
# every reason tally, so the placeholder is asserted rather than assumed.
reset_case
export MOLLOW_SUPPLY_MODE=on
run_hook "supply-stop.sh" '{"session_id":"sess-DASH","transcript_path":"/nope","stop_hook_active":false}'
line="$(tail -1 "$(reasons_log)" 2>/dev/null || true)"
if [ "$(printf '%s' "$line" | awk -F'\t' '{print NF}')" = "4" ] &&
  [ "$(printf '%s' "$line" | cut -f3)" = "-" ] &&
  [ "$(printf '%s' "$line" | cut -f4)" = "no_receipt_dir" ]; then
  pass "reasons: an unknown grounding id is '-' and the field count still holds"
else
  fail "reasons: dash placeholder" "line='$line'"
fi

# ── a session id carrying a TAB or NEWLINE cannot forge a record ────────────
# Tabs and newlines are the separators, so an id containing one would write a
# second line that every tally counts as a real decline. Removing the sanitizer
# left the old assertions green.
reset_case
export MOLLOW_SUPPLY_MODE=on
run_hook "supply-stop.sh" '{"session_id":"evil\tinjected\nsecond-line","transcript_path":"/nope","stop_hook_active":true}'
if [ "$(grep -c "" "$(reasons_log)" 2>/dev/null || echo 0)" = "1" ] &&
  [ "$(tail -1 "$(reasons_log)" | awk -F'\t' '{print NF}')" = "4" ]; then
  pass "reasons: a tab/newline in the session id writes ONE 4-field record"
else
  fail "reasons: separator injection" \
    "lines=$(grep -c "" "$(reasons_log)" 2>/dev/null) content='$(reason_lines)'"
fi

# ── a 200 carrying stored:false is NOT 'posted' ────────────────────────────
# The endpoint fails open on its own storage error (outcome.ex:160-163, and a
# second path at :268) and still answers 200 with `"stored" => receipt.stored?`
# (outcome_controller.ex:398). Logging the status alone recorded a SERVER-side
# loss as a success — the exact failure this note exists to stop (Greptile P1).
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/unstored.json"
echo '{"grounding_id":"g-un","status":"ok","stored":false}' >"$CURL_BODY_FILE"
rdir="$TMPDIR/mollow-supply/sess-UN"
mkdir -p "$rdir"
echo '{"grounding_id":"g-un","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-un.json"
run_hook "supply-stop.sh" '{"session_id":"sess-UN","transcript_path":"/nope","stop_hook_active":false}'
if [ "$(cut -f4 "$(reasons_log)" 2>/dev/null)" = "post_unstored" ]; then
  pass "reasons: a 200 with stored:false records 'post_unstored', not 'posted'"
else
  fail "reasons: stored:false" "lines='$(reason_lines)'"
fi

# ── a 200 whose body has NO stored field is not read as a failure ───────────
# "I could not tell" must not be reported as "the server lost it": that would
# invent a server defect out of a response-shape change.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/noshape.json"
echo '{"grounding_id":"g-ns","status":"ok"}' >"$CURL_BODY_FILE"
rdir="$TMPDIR/mollow-supply/sess-NS"
mkdir -p "$rdir"
echo '{"grounding_id":"g-ns","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-ns.json"
run_hook "supply-stop.sh" '{"session_id":"sess-NS","transcript_path":"/nope","stop_hook_active":false}'
if [ "$(cut -f4 "$(reasons_log)" 2>/dev/null)" = "posted:unknown_stored" ]; then
  pass "reasons: an absent stored field is 'posted:unknown_stored', not a failure"
else
  fail "reasons: absent stored field" "lines='$(reason_lines)'"
fi

# ── the hook writes NOTHING to stderr, including on its very first note ────
# Redirections are applied left to right, so `wc -c <"$log" 2>/dev/null` printed
# "No such file or directory" to the hook's own stderr on EVERY first call —
# a diagnostic breaking the contract it documents (Greptile, #7502). This case
# captures stderr rather than discarding it, which is why the earlier cases
# could not see it.
reset_case
export MOLLOW_SUPPLY_MODE=on
err_file="$CASE/stderr.txt"
printf '{"session_id":"sess-ERR","transcript_path":"/nope","stop_hook_active":true}' |
  bash "$DIR/supply-stop.sh" >/dev/null 2>"$err_file"
if [ ! -s "$err_file" ] && printf '%s' "$(reason_lines)" | grep -q reentrant; then
  pass "reasons: the first note writes nothing to stderr"
else
  fail "reasons: stderr on first note" "stderr='$(cat "$err_file")' lines='$(reason_lines)'"
fi

# ── two overlapping writers do not erase the archive ───────────────────────
# Every session on this machine shares one $HOME. Without a lock both can read
# a size over the cap: the first rotates and appends to a fresh log, the second
# moves THAT nearly-empty file over .1 and the real archive is gone (Greptile).
reset_case
export MOLLOW_SUPPLY_MODE=on
mkdir -p "$HOME/.mollow"
head -c 1048577 /dev/zero | tr '\0' 'x' >"$(reasons_log)"
for n in 1 2 3; do
  printf '{"session_id":"sess-RACE%s","transcript_path":"/nope","stop_hook_active":true}' "$n" |
    bash "$DIR/supply-stop.sh" >/dev/null 2>&1 &
done
wait
archive_size="$(wc -c <"$(reasons_log).1" 2>/dev/null | tr -d ' ' || echo 0)"
if [ -f "$(reasons_log).1" ] && [ "${archive_size:-0}" -gt 1000000 ]; then
  pass "reasons: concurrent writers rotate once and keep the full archive"
else
  fail "reasons: concurrent rotate lost the archive" \
    "archive=${archive_size:-missing} live=$(wc -c <"$(reasons_log)" 2>/dev/null)"
fi

# ── a non-200 from the seam is recorded WITH its status ──────────────────────
# `000` and a real 4xx mean different things (one transient, one configuration
# that answers identically every turn), so the code has to ride the line.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_STATUS=500
export CURL_BODY_FILE="$CASE/err.json"
echo '{"error":{"type":"boom"}}' >"$CURL_BODY_FILE"
rdir="$TMPDIR/mollow-supply/sess-E5"
mkdir -p "$rdir"
echo '{"grounding_id":"g-e5","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-e5.json"
run_hook "supply-stop.sh" '{"session_id":"sess-E5","transcript_path":"/nope","stop_hook_active":false}'
if printf '%s' "$(reason_lines)" | grep -q 'post_failed:500'; then
  pass "reasons: a 500 from the seam records 'post_failed:500'"
else
  fail "reasons: non-200 post" "lines='$(reason_lines)'"
fi

# ── the log is bounded: it rotates rather than growing without limit ─────────
# A hook that appends forever on a dogfood machine is a slow disk leak, and the
# rotate uses `mv` only — this file's own history (MOL-6199/6255/6271) is why
# nothing here reaches for `rm` with a glob.
reset_case
export MOLLOW_SUPPLY_MODE=on
mkdir -p "$HOME/.mollow"
# One byte over the cap, so the next append must rotate.
head -c 1048577 /dev/zero | tr '\0' 'x' >"$(reasons_log)"
run_hook "supply-stop.sh" '{"session_id":"sess-RO","transcript_path":"/nope","stop_hook_active":false}'
if [ -f "$(reasons_log).1" ] && [ "$(wc -c <"$(reasons_log)" | tr -d ' ')" -lt 1048577 ]; then
  pass "reasons: an oversized log rotates to .1 and the live file restarts small"
else
  fail "reasons: rotate" "live=$(wc -c <"$(reasons_log)" 2>/dev/null) rotated=$([ -f "$(reasons_log).1" ] && echo yes || echo no)"
fi

# ── an UNWRITABLE log location must not break the turn ──────────────────────
# This is the one new failure mode the note introduces into every opted-in
# session, so it gets its own case rather than resting on the `|| true`s being
# read as correct. A post-back must still be sent when the log cannot be
# written: the diagnostic is subordinate to the thing it diagnoses.
reset_case
export MOLLOW_SUPPLY_MODE=on
export CURL_BODY_FILE="$CASE/ok2.json"
echo '{"grounding_id":"g-ro","status":"ok"}' >"$CURL_BODY_FILE"
# A FILE where the directory must go, so `mkdir -p` cannot succeed.
printf 'not a directory' >"$HOME/.mollow"
rdir="$TMPDIR/mollow-supply/sess-UW"
mkdir -p "$rdir"
echo '{"grounding_id":"g-ro","grounded_at":100,"facts":[{"citation_key":"mh1","match_text":"alpha"}]}' >"$rdir/g-ro.json"
run_hook "supply-stop.sh" '{"session_id":"sess-UW","transcript_path":"/nope","stop_hook_active":false}'
if [ "$LAST_RC" -eq 0 ] && curl_called; then
  pass "reasons: an unwritable log location still posts back, exit 0"
else
  fail "reasons: unwritable log must not break the post-back" \
    "rc=$LAST_RC curl='$(cat "$CURL_LOG")'"
fi

# ── an OLD lock that cannot be removed must still terminate ─────────────────
# The staleness sweep used to `continue`, skipping both the sleep and the
# attempt counter, so a stale lock `rmdir` could not remove spun the loop
# forever — in a function that runs on every Stop in every session (Greptile,
# #7502). `~/.mollow` is made read-only here so the rmdir genuinely fails,
# which is the case a writable-directory test cannot reach.
reset_case
export MOLLOW_SUPPLY_MODE=on
mkdir -p "$HOME/.mollow/supply-stop-reasons.lock"
# Backdated past the 60s threshold so the sweep branch is the one taken.
touch -t 202001010000 "$HOME/.mollow/supply-stop-reasons.lock" 2>/dev/null || true
chmod 500 "$HOME/.mollow"
lock_start=$(date +%s)
printf '{"session_id":"sess-LOCK","transcript_path":"/nope","stop_hook_active":true}' >"$CASE/lock-in.json"
run_bounded 20 bash "$DIR/supply-stop.sh" <"$CASE/lock-in.json" >/dev/null 2>&1
lock_rc=$?
lock_elapsed=$(($(date +%s) - lock_start))
chmod 700 "$HOME/.mollow"
# `-eq 0`, not `-ne 124`. The hook is fail-open and exits 0 on every path, so 0
# is the only passing status — and `-ne 124` accepted 127, which is what a
# MISSING `timeout` returns without running the hook at all. That made the case
# vacuous on a stock macOS install, which is the platform these hooks run on
# (Greptile, #7502). `run_bounded` removes the dependency; this assertion makes
# a silent non-run fail even so.
if [ "$lock_rc" -eq 0 ] && [ "$lock_elapsed" -lt 10 ]; then
  pass "reasons: an unremovable stale lock terminates (rc=$lock_rc, ${lock_elapsed}s)"
else
  fail "reasons: unremovable stale lock did not terminate cleanly" \
    "rc=$lock_rc (0 required; 124 = bounded out, 127 = command missing) elapsed=${lock_elapsed}s"
fi

# ── mm_supply_note survives being sourced into an ERREXIT caller ────────────
# "Always returns 0" has to hold in an errexit shell, and that is not
# hypothetical: `import-local-memories.sh`, `preflight-supply.sh`,
# `recall-batch.sh` and `scope-sync.sh` already source `_common.sh` under
# `set -euo pipefail`. Only the supply hooks call this function today and they
# use `-uo` without `-e`, so the hazard is one call site away rather than live.
#
# The trigger is the RELEASE `rmdir` failing while the lock is held. That cannot
# be reached by pre-creating the lock — then `mkdir` fails, `held` stays empty,
# and a failing left operand of `&&` is exempt from errexit, so the bare form
# passes. Measured: a fixture built that way reports green against the mutation
# (`negcheck` STILL GREEN), which is why `rmdir` is stubbed to fail instead.
# That is the one dependency whose failure the invariant is about.
reset_case
export MOLLOW_SUPPLY_MODE=on
errexit_out="$(
  bash -c '
    set -euo pipefail
    . "$1/_common.sh"
    rmdir() { return 1; }     # the release rmdir fails; the lock IS held
    mm_supply_note probe sess-EE g-ee
    echo REACHED_RETURN
  ' _ "$DIR" 2>/dev/null
)" || true
if [ "$errexit_out" = "REACHED_RETURN" ]; then
  pass "reasons: mm_supply_note returns 0 under set -e when the release rmdir fails"
else
  fail "reasons: an errexit caller aborted inside mm_supply_note" \
    "out='$errexit_out' (expected REACHED_RETURN)"
fi

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
