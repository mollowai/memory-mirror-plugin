#!/usr/bin/env bash
# pass() never fails, so `A && pass || fail` is a safe if/else here.
# shellcheck disable=SC2015
set -uo pipefail
# Tests for the per-turn grounding engagement hooks:
#   grounding-receipt.sh    (PostToolUse, mcp__mollow__get_session_context)
#   grounding-engagement.sh (Stop, every turn)
#
# The seam these exist to pin is the PostToolUse input shape. For an MCP tool,
# `.tool_response` is an ARRAY of content blocks whose text is the JSON-encoded
# result — measured from a live `claude -p` run on 2026-11-17, not inferred. A
# fixture built from the server's map shape (`.tool_response._grounding`) would
# pass against a parser that never writes a receipt in a real session, so the
# primary fixture here is the measured shape.
#
# No network: curl is a PATH shim that logs its argv, so "was a request
# attempted, and with what body" is a file check.
#
# Run: bash plugins/memory-mirror/hooks/test-grounding-engagement.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() {
  echo "FAIL: $1"
  shift
  for line in "$@"; do echo "  $line"; done
  FAIL=$((FAIL + 1))
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mm-grounding-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

SHIM="$WORK/bin"
mkdir -p "$SHIM"
cat >"$SHIM/curl" <<'SHIM_EOF'
#!/usr/bin/env bash
# One line per call: the URL, then the -d body. Written atomically enough for
# parallel posts (one printf per call).
url="" body=""
prev=""
for a in "$@"; do
  case "$prev" in -d) body="$a" ;; esac
  case "$a" in http*://*) url="$a" ;; esac
  prev="$a"
done
auth=""
prev=""
for a in "$@"; do
  [ "$prev" = "-H" ] && case "$a" in Authorization:*) auth="$a" ;; esac
  prev="$a"
done
printf '%s\t%s\t%s\n' "$url" "$auth" "$body" >>"${CURL_LOG:-/dev/null}"
exit 0
SHIM_EOF
chmod +x "$SHIM/curl"

SID="sess-abc"
EMISSION="5b2f7a3e-0000-4000-8000-000000000001"

# The `_grounding` the server emits (MemoryTools.maybe_put_grounding/3).
GROUNDING_JSON="$(jq -cn --arg e "$EMISSION" '{
  emission_id: $e,
  artifacts: [
    {kind: "skill", ref: "skill-1", terms: ["migration", "rollback"], tools: ["recall", "Bash"]},
    {kind: "hypothesis", ref: "hyp-1", terms: ["dropdown", "chevron"], tools: []},
    {kind: "decision", ref: "dec-key-1", terms: ["staging"], tools: []},
    {kind: "decision", ref: "dec-key-2", terms: ["rollback"], tools: []}
  ]}')"

# The MEASURED PostToolUse shape: tool_response = [{type:text, text:<json string>}].
post_input() { # <tool_response json> [tool_name] [transcript] [prompt_id]
  jq -cn --argjson resp "$1" --arg tool "${2:-mcp__mollow__get_session_context}" \
    --arg tp "${3:-}" --arg pid "${4:-prompt-1}" --arg sid "$SID" '{
      session_id: $sid, transcript_path: $tp, prompt_id: $pid,
      hook_event_name: "PostToolUse", tool_name: $tool,
      tool_input: {project: "monorepo"}, tool_response: $resp, mcp_server: "mollow"}'
}
array_response() { # <grounding json or null>
  jq -cn --argjson g "$1" '[{type: "text",
    text: ({skills: [], recent_decisions: [], _diagnostics: {}} + (if $g == null then {} else {_grounding: $g} end) | tojson)}]'
}

stop_input() { # <transcript> <prompt_id>
  jq -cn --arg tp "$1" --arg pid "$2" --arg sid "$SID" \
    '{session_id: $sid, transcript_path: $tp, prompt_id: $pid, hook_event_name: "Stop", stop_hook_active: false}'
}

# Transcript line builders (the JSONL shape Claude Code writes).
t_user() { jq -cn --arg pid "$1" --arg txt "$2" '{type: "user", promptId: $pid, message: {role: "user", content: $txt}}'; }
t_text() { jq -cn --arg txt "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $txt}]}}'; }
t_tool() { jq -cn --arg n "$1" --argjson in "${2:-{\}}" '{type: "assistant", message: {role: "assistant", content: [{type: "tool_use", id: "tu", name: $n, input: $in}]}}'; }

new_case() {
  CASE="$WORK/case-$1"
  mkdir -p "$CASE/home" "$CASE/tmp"
  export HOME="$CASE/home" TMPDIR="$CASE/tmp" CURL_LOG="$CASE/curl.log"
  export PATH="$SHIM:$ORIG_PATH"
  export MOLLOW_MEMORY_API_KEY="mol_test_key" MOLLOW_MEMORY_URL="https://example.test/mcp/v2"
  export MOLLOW_MEMORY_CREDS_FROM_FILES=0 MOLLOW_GROUNDING_ENGAGEMENT_SYNC=1
  unset MOLLOW_GROUNDING_ENGAGEMENT
  : >"$CURL_LOG"
  TRANSCRIPT="$CASE/transcript.jsonl"
  : >"$TRANSCRIPT"
  RECEIPT="$CASE/tmp/mollow-grounding/$SID/receipt.json"
}
ORIG_PATH="$PATH"

run_receipt() { printf '%s' "$1" | bash "$DIR/grounding-receipt.sh" >"$CASE/out" 2>"$CASE/err"; echo $?; }
run_stop() { printf '%s' "$1" | bash "$DIR/grounding-engagement.sh" >"$CASE/out" 2>"$CASE/err"; echo $?; }
posts() { cut -f3 "$CURL_LOG" | grep -v '^$' || true; }
signal_of() { # <ref> <signal>
  posts | jq -r --arg r "$1" --arg s "$2" 'select(.citation_key == $r) | .signals[$s] | tostring'
}

# ── receipt: the measured MCP shape ─────────────────────────────────────────
new_case receipt-array
printf '%s\n' "$(t_user prompt-1 'hello')" >"$TRANSCRIPT"
rc="$(run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT")")"
if [ "$rc" = 0 ] && [ -f "$RECEIPT" ] &&
  [ "$(jq -r .emission_id "$RECEIPT")" = "$EMISSION" ] &&
  [ "$(jq -r '.artifacts | length' "$RECEIPT")" = 4 ] &&
  [ "$(jq -r .offset "$RECEIPT")" = "$(wc -c <"$TRANSCRIPT" | tr -d ' ')" ] &&
  [ "$(jq -r .turn_ref "$RECEIPT")" = prompt-1 ]; then
  pass "receipt written from an array-of-text-blocks tool_response (the live MCP shape)"
else
  fail "receipt from the live MCP shape" "rc=$rc" "receipt=$(cat "$RECEIPT" 2>/dev/null)"
fi
[ ! -s "$CASE/out" ] && pass "receipt hook prints nothing to stdout" || fail "receipt hook stdout" "$(cat "$CASE/out")"
[ ! -s "$CURL_LOG" ] && pass "receipt hook makes no network call" || fail "receipt hook called curl" "$(cat "$CURL_LOG")"

new_case receipt-object
run_receipt "$(post_input "$(jq -cn --argjson g "$GROUNDING_JSON" '{_grounding: $g}')")" >/dev/null
[ "$(jq -r .emission_id "$RECEIPT" 2>/dev/null)" = "$EMISSION" ] &&
  pass "receipt also accepts an unwrapped object tool_response" ||
  fail "object tool_response" "$(cat "$RECEIPT" 2>/dev/null)"

new_case receipt-absent
run_receipt "$(post_input "$(array_response null)")" >/dev/null
[ ! -e "$RECEIPT" ] && pass "no _grounding in the response => no receipt" || fail "receipt without _grounding"

new_case receipt-other-tool
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__search_memories)" >/dev/null
[ ! -e "$RECEIPT" ] && pass "a different tool => no receipt" || fail "receipt for another tool"

new_case receipt-bad-artifacts
bad="$(jq -cn --arg e "$EMISSION" '{emission_id: $e, artifacts: [
  {kind: "skill", ref: "ok", terms: ["a", 5, {"x": 1}], tools: "notalist"},
  {kind: "memory", ref: "wrong-kind"},
  {kind: "decision", ref: ("x" * 201)},
  "junk"]}')"
run_receipt "$(post_input "$(array_response "$bad")")" >/dev/null
if [ "$(jq -c '[.artifacts[] | .ref]' "$RECEIPT" 2>/dev/null)" = '["ok"]' ] &&
  [ "$(jq -c '.artifacts[0].terms' "$RECEIPT")" = '["a"]' ] &&
  [ "$(jq -c '.artifacts[0].tools' "$RECEIPT")" = '[]' ]; then
  pass "receipt drops unknown kinds, oversized refs and non-string terms"
else
  fail "artifact sanitization" "$(cat "$RECEIPT" 2>/dev/null)"
fi

new_case receipt-unsafe-emission
run_receipt "$(post_input "$(array_response '{"emission_id":"../../etc","artifacts":[]}')")" >/dev/null
[ ! -e "$RECEIPT" ] && pass "unsafe emission_id => no receipt" || fail "unsafe emission_id accepted"

new_case receipt-optout
export MOLLOW_GROUNDING_ENGAGEMENT=0
printf '%s' "$(post_input "$(array_response "$GROUNDING_JSON")")" | bash "$DIR/grounding-receipt.sh" >/dev/null 2>&1
[ ! -e "$RECEIPT" ] && pass "MOLLOW_GROUNDING_ENGAGEMENT=0 => no receipt" || fail "opt-out ignored by receipt hook"

# ── stop: signals for one turn ──────────────────────────────────────────────
# Grounding turn: an Edit BEFORE the grounding arrived must not count; after it,
# the model mentions "migration" (skill term), runs mcp__mollow__recall (skill
# step tool, prefix-stripped), edits twice and records a decision. A sidechain
# Edit is ignored.
new_case stop-signals
{
  t_user prompt-1 'please mention dropdown chevron staging'
  t_tool Edit '{"file_path":"/x"}'
} >"$TRANSCRIPT"
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT" prompt-1)" >/dev/null
{
  t_text 'Running the Migration now.'
  t_tool mcp__mollow__recall '{"q":"x"}'
  t_tool Edit '{"file_path":"/a"}'
  t_tool Write '{"file_path":"/b","content":"rollbackish"}'
  t_tool mcp__mollow__record_decision '{"question":"q"}'
  # A user entry with array content (tool results, attachments) — the user's
  # words are not the model's engagement.
  jq -cn '{type: "user", promptId: "prompt-1", message: {role: "user", content: [{type: "text", text: "dropdown"}]}}'
  jq -cn '{type: "assistant", isSidechain: true, message: {content: [{type: "tool_use", name: "Edit", input: {}}]}}'
} >>"$TRANSCRIPT"
rc="$(run_stop "$(stop_input "$TRANSCRIPT" prompt-1)")"
if [ "$rc" = 0 ] && [ "$(posts | wc -l | tr -d ' ')" = 4 ]; then
  pass "one post per artifact"
else
  fail "post count" "rc=$rc" "$(cat "$CURL_LOG")"
fi
[ "$(cut -f1 "$CURL_LOG" | sort -u)" = "https://example.test/api/memory/grounding/engagement" ] &&
  pass "posts to /api/memory/grounding/engagement" || fail "post URL" "$(cut -f1 "$CURL_LOG")"
[ "$(cut -f2 "$CURL_LOG" | sort -u)" = "Authorization: Bearer mol_test_key" ] &&
  pass "authenticates with the mol_* memory key" || fail "auth header" "$(cut -f2 "$CURL_LOG")"
[ "$(posts | jq -r '[.emission_id, .turn_ref] | join(" ")' | sort -u)" = "$EMISSION prompt-1" ] &&
  pass "every row carries the emission_id and the prompt_id as turn_ref" ||
  fail "emission/turn_ref" "$(posts)"
[ "$(posts | jq -r '.fact_kind + ":" + .citation_key' | sort | tr '\n' ' ')" = "decision:dec-key-1 decision:dec-key-2 hypothesis:hyp-1 skill:skill-1 " ] &&
  pass "fact_kind and citation_key come from the receipt" || fail "fact_kind/citation_key" "$(posts)"

expect() { # <ref> <signal> <value>
  local got
  got="$(signal_of "$1" "$2")"
  [ "$got" = "$3" ] && pass "$1 $2 = $3" || fail "$1 $2: want $3, got '$got'"
}
expect skill-1 turn_seen true
expect skill-1 tool_invoked true
expect skill-1 term_match true
expect skill-1 edit_count 2
expect skill-1 decision_recorded true
expect hyp-1 tool_invoked false
# "dropdown chevron staging" appear only in the USER prompt — not engagement.
expect hyp-1 term_match false
expect dec-key-1 term_match false
# "rollbackish" (in a tool input) is not the whole token "rollback".
expect dec-key-2 term_match false
[ "$(posts | jq -c '.signals | keys' | sort -u)" = '["decision_recorded","edit_count","term_match","tool_invoked","turn_seen"]' ] &&
  pass "exactly the five approved signals" || fail "signal keys" "$(posts | jq -c '.signals | keys' | sort -u)"
if [ "$(posts | grep -ci 'migration\|rollback\|file_path')" != 0 ]; then
  fail "transcript text leaked into a post" "$(posts)"
else
  pass "no transcript text leaves in any post"
fi
[ "$(jq -r .offset "$RECEIPT")" = "$(wc -c <"$TRANSCRIPT" | tr -d ' ')" ] &&
  pass "offset advances to the end of the transcript" || fail "offset" "$(cat "$RECEIPT")"

# ── stop: the next turn is scored from the offset only ──────────────────────
: >"$CURL_LOG"
{
  t_user prompt-2 'next'
  t_text 'about the dropdown'
} >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" prompt-2)" >/dev/null
expect hyp-1 term_match true
expect skill-1 term_match false
expect skill-1 edit_count 0
expect skill-1 decision_recorded false
[ "$(posts | jq -r .turn_ref | sort -u)" = prompt-2 ] && pass "new turn uses its own prompt_id" || fail "turn_ref turn 2" "$(posts)"

# ── stop: a continuation of the same prompt re-scores the whole turn ────────
: >"$CURL_LOG"
t_tool Edit '{"file_path":"/c"}' >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" prompt-2)" >/dev/null
expect hyp-1 term_match true
expect skill-1 edit_count 1
[ "$(posts | jq -r .turn_ref | sort -u)" = prompt-2 ] && pass "continuation keeps the turn's prompt_id" || fail "continuation turn_ref"

# ── stop: nothing new => no post ────────────────────────────────────────────
: >"$CURL_LOG"
run_stop "$(stop_input "$TRANSCRIPT" prompt-3)" >/dev/null
[ ! -s "$CURL_LOG" ] && pass "an empty window posts nothing" || fail "posted on an empty window" "$(cat "$CURL_LOG")"

# ── stop: guards ────────────────────────────────────────────────────────────
new_case stop-no-receipt
t_text 'hi' >"$TRANSCRIPT"
rc="$(run_stop "$(stop_input "$TRANSCRIPT" p)")"
[ "$rc" = 0 ] && [ ! -s "$CURL_LOG" ] && pass "no receipt => exit 0, no network" || fail "no-receipt path" "rc=$rc"

new_case stop-optout
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT")" >/dev/null
t_text 'migration' >>"$TRANSCRIPT"
export MOLLOW_GROUNDING_ENGAGEMENT=off
run_stop "$(stop_input "$TRANSCRIPT" p2)" >/dev/null
[ ! -s "$CURL_LOG" ] && pass "MOLLOW_GROUNDING_ENGAGEMENT=off => no network" || fail "opt-out ignored by stop hook"

new_case stop-no-key
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT")" >/dev/null
t_text 'migration' >>"$TRANSCRIPT"
unset MOLLOW_MEMORY_API_KEY
rc="$(run_stop "$(stop_input "$TRANSCRIPT" p2)")"
[ "$rc" = 0 ] && [ ! -s "$CURL_LOG" ] && pass "no memory key => exit 0, no network" || fail "no-key path" "rc=$rc"

new_case stop-async
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT")" >/dev/null
t_text 'migration' >>"$TRANSCRIPT"
unset MOLLOW_GROUNDING_ENGAGEMENT_SYNC
rc="$(run_stop "$(stop_input "$TRANSCRIPT" p2)")"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(posts | wc -l | tr -d ' ')" = 4 ] && break
  sleep 0.2
done
[ "$rc" = 0 ] && [ "$(posts | wc -l | tr -d ' ')" = 4 ] &&
  pass "default (detached) mode still delivers every post" || fail "detached posts" "rc=$rc" "$(cat "$CURL_LOG")"

# ── tool_invoked: a synthesized skill's `server.tool` step ──────────────────
# Engram.StepSynthesizer stores step tools as "server.tool"; the transcript
# names the call mcp__server__tool. (Greptile, PR #8370.)
new_case stop-dotted-tool
dotted="$(jq -cn --arg e "$EMISSION" '{emission_id: $e, artifacts: [
  {kind: "skill", ref: "skill-dot", terms: [], tools: ["summarize.run"]},
  {kind: "skill", ref: "skill-other", terms: [], tools: ["summarize.other"]}]}')"
printf '%s\n' "$(t_user p1 'go')" >"$TRANSCRIPT"
run_receipt "$(post_input "$(array_response "$dotted")" mcp__mollow__get_session_context "$TRANSCRIPT" p1)" >/dev/null
t_tool mcp__summarize__run '{}' >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" p1)" >/dev/null
expect skill-dot tool_invoked true
expect skill-other tool_invoked false

# ── ordering: a continuation's fuller window is the one that lands ──────────
# Two Stops for the same prompt launch two background batches. Holding the post
# lock queues both; whichever acquires it first, only the NEWER window may post.
new_case stop-ordering
printf '%s\n' "$(t_user p1 'go')" >"$TRANSCRIPT"
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT" p1)" >/dev/null
unset MOLLOW_GROUNDING_ENGAGEMENT_SYNC
mkdir "$CASE/tmp/mollow-grounding/$SID/post.lock"
t_tool Edit '{"file_path":"/a"}' >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" p1)" >/dev/null # older window: 1 edit
t_tool Edit '{"file_path":"/b"}' >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" p1)" >/dev/null # continuation: 2 edits
sleep 0.5
rmdir "$CASE/tmp/mollow-grounding/$SID/post.lock"
prev=-1
for _ in $(seq 1 30); do
  sleep 0.3
  cur="$(posts | wc -l | tr -d ' ')"
  [ "$cur" = "$prev" ] && [ "$cur" -gt 0 ] && break
  prev="$cur"
done
sleep 1
[ "$(posts | wc -l | tr -d ' ')" = 4 ] &&
  pass "only one batch posts for a turn with a continuation" ||
  fail "posts for a continued turn: want 4, got $(posts | wc -l | tr -d ' ')" "$(posts | jq -c .signals.edit_count | tr '\n' ' ')"
[ "$(posts | jq -r .signals.edit_count | sort -u)" = 2 ] &&
  pass "the batch that posts is the newer, fuller window" ||
  fail "posted window" "$(posts | jq -c .signals.edit_count | tr '\n' ' ')"
export MOLLOW_GROUNDING_ENGAGEMENT_SYNC=1

# ── receipt directories must be ours and not symlinks ──────────────────────
new_case receipt-symlink-root
mkdir -p "$CASE/elsewhere"
ln -s "$CASE/elsewhere" "$CASE/tmp/mollow-grounding"
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")")" >/dev/null
[ -z "$(ls -A "$CASE/elsewhere")" ] &&
  pass "a symlinked receipt root is refused (nothing written through it)" ||
  fail "wrote through a symlinked root" "$(ls -AR "$CASE/elsewhere")"

new_case receipt-symlink-session
mkdir -p "$CASE/elsewhere" "$CASE/tmp/mollow-grounding"
ln -s "$CASE/elsewhere" "$CASE/tmp/mollow-grounding/$SID"
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")")" >/dev/null
[ -z "$(ls -A "$CASE/elsewhere")" ] &&
  pass "a symlinked session dir is refused" ||
  fail "wrote through a symlinked session dir" "$(ls -A "$CASE/elsewhere")"

new_case receipt-mode
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")")" >/dev/null
# GNU stat first: GNU `stat -f` is FILESYSTEM status and exits 0, so a
# BSD-first fallback never reaches -c on Linux (measured in CI on #8370).
modes="$(stat -c '%a' "$CASE/tmp/mollow-grounding" "$CASE/tmp/mollow-grounding/$SID" 2>/dev/null ||
  stat -f '%Lp' "$CASE/tmp/mollow-grounding" "$CASE/tmp/mollow-grounding/$SID")"
[ "$(printf '%s' "$modes" | tr '\n' ' ')" = "700 700" ] &&
  pass "receipt root and session dir are mode 700" || fail "dir modes" "$modes"

new_case stop-symlink-receipt
run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT")" >/dev/null
mv "$RECEIPT" "$CASE/planted.json"
ln -s "$CASE/planted.json" "$RECEIPT"
t_text 'migration' >>"$TRANSCRIPT"
run_stop "$(stop_input "$TRANSCRIPT" p2)" >/dev/null
[ ! -s "$CURL_LOG" ] && pass "a symlinked receipt is not read or posted" || fail "posted from a symlinked receipt"

# ── a sequence write that does not land stops the batch ─────────────────────
# If the per-session counter cannot be advanced, the next Stop would reuse the
# same sequence number, and two batches for one turn would both pass the
# newest-window check. So a counter write that fails must post nothing.
# A read-only DIRECTORY at the counter path makes the mv fail; root ignores
# the mode, so the case is skipped there.
new_case stop-seq-unwritable
if [ "$(id -u)" = 0 ]; then
  pass "(skipped as root: directory modes do not bind)"
else
  printf '%s\n' "$(t_user p1 'go')" >"$TRANSCRIPT"
  run_receipt "$(post_input "$(array_response "$GROUNDING_JSON")" mcp__mollow__get_session_context "$TRANSCRIPT" p1)" >/dev/null
  mkdir "$CASE/tmp/mollow-grounding/$SID/seq"
  chmod 500 "$CASE/tmp/mollow-grounding/$SID/seq"
  t_text 'migration' >>"$TRANSCRIPT"
  rc="$(run_stop "$(stop_input "$TRANSCRIPT" p1)")"
  chmod 700 "$CASE/tmp/mollow-grounding/$SID/seq"
  [ "$rc" = 0 ] && [ ! -s "$CURL_LOG" ] &&
    pass "an unwritable sequence counter => exit 0, nothing posted" ||
    fail "posted with an unwritable sequence counter" "rc=$rc" "$(cat "$CURL_LOG")"
fi

echo
echo "grounding engagement hooks: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
