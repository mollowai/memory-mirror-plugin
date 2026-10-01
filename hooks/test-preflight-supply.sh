#!/usr/bin/env bash
# Full `set -euo pipefail`, the repo standard.
#
# Most cases here assert a NON-ZERO exit from the script under test (exit 1 for a
# pre-flight that could not run, exit 2 for an unmet `--expect-*`), so a bare
# `LAST_OUT=$(...)` followed by `LAST_RC=$?` would abort the suite at the first
# such case. Every assertion after it would then be ABSENT rather than failing —
# fewer PASS lines with nothing red, which reads as a shorter green suite.
#
# `run_pf` and the constructed-table cases take the status through an `if`
# CONDITION instead, which errexit exempts, so the suite keeps running and the
# status is still captured.
set -euo pipefail
# Tests for preflight-supply.sh (MOL-6431).
#
# The pre-flight's whole value is that it cannot report a comfortable answer
# when the thing it is checking is wrong. So the cases here are mostly the
# UNCOMFORTABLE ones, and each is built so it would pass on a broken script if
# the fixture were any weaker:
#
#   * `silent` and "the hook file is missing" must NOT share an exit code. They
#     produce byte-identical stdout from the hook (nothing at all), so a fixture
#     that only checked stdout would pass either way. These assert the EXIT.
#   * The live-copy resolution is driven through an injected process table, so a
#     case can construct the exact ambiguity the script exists for — two sessions
#     with two different --plugin-dir values — which a real `ps` cannot be made
#     to contain on demand.
#   * Drift is asserted with a hook whose CONTENT differs from the sibling, not
#     merely a different path. A path comparison alone reports DIFFERS for two
#     identical files, which is a false alarm about the one signal an editor is
#     supposed to trust.
#
# No network: the hook under test is itself a stub here. Driving the real
# supply-ground.sh would test the server, not the pre-flight.
#
# Run: bash plugins/memory-mirror/hooks/test-preflight-supply.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$DIR/preflight-supply.sh"

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

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mm-preflight-test-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A stub hook standing in for supply-ground.sh, in the real hook's wire shape.
#
# It is configured through FILES beside itself, not environment variables. The
# pre-flight runs every leg under `env -i` on purpose — supply-ground.sh records
# what it injected in $HOME and drops a receipt in TMPDIR, and a pre-flight that
# leaked those into the operator's real session would suppress the same facts in
# his next prompt. That isolation strips any STUB_* variable too, so an
# env-configured stub emits nothing and EVERY case classifies as `silent`: a
# suite that would report the same 10 passes whether or not the script worked.
#
# The stub also records the MOLLOW_SUPPLY_POINTER_MODE it was handed. That one
# DOES survive, because the pre-flight passes it deliberately — which is exactly
# the property the pointer leg needs asserted.
#
# A stub also needs an `_common.sh` beside it, because the pre-flight requires one
# next to whichever hook it chose and SOURCES it for `mm_resolve_memory_creds` —
# the real hook sources it unconditionally, so its absence means the hook could
# not have run. A no-op resolver is the right double here: the credentials are
# already in the environment for these cases, and a resolver with side effects
# would be sourced into the pre-flight's own shell.
make_stub() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat >"$(dirname "$path")/_common.sh" <<'COMMON'
# test double — the pre-flight sources this and calls the resolver below.
mm_resolve_memory_creds() { :; }
COMMON
  cat >"$path" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
printf '%s\n' "${MOLLOW_SUPPLY_POINTER_MODE:-unset}" >>"$here/pointer.log"
[ -s "$here/context.txt" ] || exit 0
jq -cn --rawfile c "$here/context.txt" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}'
STUB
  chmod +x "$path"
}

STUB_DIR="$WORK/plug/hooks"
set_context() { printf '%s' "$1" >"$STUB_DIR/context.txt"; }
clear_context() { : >"$STUB_DIR/context.txt"; }
pointer_log() { cat "$STUB_DIR/pointer.log" 2>/dev/null; }
reset_pointer_log() { : >"$STUB_DIR/pointer.log"; }

# A credential so the script gets past its own precondition. Nothing reaches a
# network — the stub above never calls curl.
export MOLLOW_MEMORY_API_KEY="mol_preflight_test_key"
export MOLLOW_MEMORY_URL="https://staging.mollow.ai/mcp/v2"
export MOLLOW_SUPPLY_WORKSPACE_ID="00000000-0000-0000-0000-000000000000"

STUB="$WORK/plug/hooks/supply-ground.sh"
make_stub "$STUB"

run_pf() {
  if LAST_OUT="$(MM_PREFLIGHT_HOOK="${PF_HOOK:-$STUB}" bash "$SCRIPT" "$@" 2>&1)"; then
    LAST_RC=0
  else
    LAST_RC=$?
  fi
}

# ── classification ───────────────────────────────────────────────────────────
# Each refusal shape the runbook has to tell apart maps to its own class. The
# 422/404 pair is the point of the issue: they are DIFFERENT causes needing
# DIFFERENT fixes, and before this they were two indistinguishable "it didn't
# work" outcomes.

set_context 'Facts from your memory that may bear on this request'
run_pf --legs facts
if echo "$LAST_OUT" | grep -q 'facts *served'; then
  pass "classify: injected facts => served"
else
  fail "classify: injected facts => served" "out='$LAST_OUT'"
fi

set_context 'Mollow supply mode handed you POINTERS, not content.'
run_pf --legs pointer
if echo "$LAST_OUT" | grep -q 'pointer *served'; then
  pass "classify: injected pointers => served"
else
  fail "classify: injected pointers => served" "out='$LAST_OUT'"
fi

set_context 'Mollow supply mode: the grounding request was rejected (422 invalid_mode). pointer_mode is off for your actor'
run_pf --legs pointer
if echo "$LAST_OUT" | grep -q 'pointer *invalid_mode'; then
  pass "classify: 422 invalid_mode => invalid_mode (not lumped with 404)"
else
  fail "classify: 422 invalid_mode => invalid_mode" "out='$LAST_OUT'"
fi

set_context 'Mollow supply mode: the grounding endpoint answered 404 for POST https://x/grounding/v1/ground.'
run_pf --legs pointer
if echo "$LAST_OUT" | grep -q 'pointer *not_found'; then
  pass "classify: 404 => not_found (a DIFFERENT class from invalid_mode)"
else
  fail "classify: 404 => not_found" "out='$LAST_OUT'"
fi

set_context 'Mollow supply mode: the grounding request was refused (400 workspace_not_named).'
run_pf --legs facts
if echo "$LAST_OUT" | grep -q 'facts *workspace'; then
  pass "classify: 400 workspace_not_named => workspace"
else
  fail "classify: 400 workspace_not_named => workspace" "out='$LAST_OUT'"
fi

clear_context
run_pf --legs facts
if echo "$LAST_OUT" | grep -q 'facts *silent'; then
  pass "classify: no output => silent"
else
  fail "classify: no output => silent" "out='$LAST_OUT'"
fi

# ── a LONG served context must not abort the runner (Greptile P1) ────────────
# The regression this catches was introduced by moving to `set -euo pipefail`:
# `LEG_DETAIL="$(printf '%s' "$ctx" | head -c 220 | tr '\n' ' ')"` aborts the whole
# script on the HEALTHY path once the context is big — `head` closes the pipe at
# 220 bytes, `printf` takes SIGPIPE and exits 141, `pipefail` surfaces it and `-e`
# ends the run before the leg is printed or `--expect-*` is checked.
#
# THE FIXTURE SIZE IS THE WHOLE TEST. A short context cannot express it: under the
# ~64KB pipe buffer `printf` finishes writing before `head` closes, so no SIGPIPE
# occurs and the bug is invisible. Every other case in this suite uses a one-line
# context and all of them stayed green while this was live. 200KB is comfortably
# past the buffer — measured: the old pipeline exits 141 at that size and prints
# nothing at all.
BIG_CTX="$WORK/big.txt"
{ printf 'Facts from your memory that may bear on this request'; head -c 200000 /dev/zero | tr '\0' 'a'; } >"$BIG_CTX"
cp "$BIG_CTX" "$STUB_DIR/context.txt"
run_pf --legs facts --expect-facts served
if [ "$LAST_RC" -eq 0 ] && echo "$LAST_OUT" | grep -q 'facts *served'; then
  pass "long context: a 200KB served context still prints its leg and honours --expect-*"
else
  fail "long context => no abort" "rc=$LAST_RC (141 = SIGPIPE abort) out='$(echo "$LAST_OUT" | head -c 300)'"
fi
# And the detail is still truncated rather than dumping 200KB into the output.
if [ "${#LAST_OUT}" -lt 4000 ]; then
  pass "long context: the detail column is truncated, not the whole context"
else
  fail "long context: detail truncated" "output was ${#LAST_OUT} bytes"
fi

# ── the pointer leg must actually ASK for pointer mode ───────────────────────
# Without this the pointer leg could be a facts request under a different label,
# and every classification case above would still pass — the whole suite would
# be asserting the script's own vocabulary against itself.
reset_pointer_log
set_context 'Mollow supply mode handed you POINTERS, not content.'
run_pf --legs "facts pointer"
got="$(pointer_log | tr '\n' ',' || true)"
if [ "$got" = "unset,on," ]; then
  pass "legs: facts runs with the pointer opt-in UNSET, pointer runs with it on"
else
  fail "legs: pointer opt-in per leg" "MOLLOW_SUPPLY_POINTER_MODE seen: '$got' (want 'unset,on,')"
fi

# ── expectations ─────────────────────────────────────────────────────────────
# "A pre-flight that only ever runs in the working configuration cannot detect
# the configuration being wrong" — so a met expectation and an unmet one must
# not both exit 0.

set_context 'Mollow supply mode: the grounding request was rejected (422 invalid_mode).'
run_pf --legs pointer --expect-pointer served
if [ "$LAST_RC" -eq 2 ]; then
  pass "expect: pointer_mode off while 'served' expected => exit 2"
else
  fail "expect: unmet expectation => exit 2" "rc=$LAST_RC out='$LAST_OUT'"
fi

run_pf --legs pointer --expect-pointer invalid_mode
if [ "$LAST_RC" -eq 0 ]; then
  pass "expect: met expectation => exit 0"
else
  fail "expect: met expectation => exit 0" "rc=$LAST_RC out='$LAST_OUT'"
fi

run_pf --legs pointer
if [ "$LAST_RC" -eq 0 ]; then
  pass "expect: no --expect-* => reports without failing"
else
  fail "expect: no --expect-* => exit 0" "rc=$LAST_RC out='$LAST_OUT'"
fi

# ── a missing hook is NOT a silent leg ───────────────────────────────────────
# The two produce identical hook output (none). Only the exit code separates
# them, which is why this asserts the exit and not the text.
#
# The fixture directory deliberately CONTAINS `_common.sh` and lacks only the
# hook. Pointing at a bare path instead makes TWO guards fire — the readable-hook
# check and the missing-`_common.sh` check — so removing either one leaves the
# other covering the case and the test stays green on a real regression. Measured:
# with a bare path, `if [ ! -r "$HOOK" ]` mutated to `if false` did NOT redden
# this suite. Asserting the guard's own wording is what binds it to one guard.
MISSING_HOOK_DIR="$WORK/hookless/hooks"
mkdir -p "$MISSING_HOOK_DIR"
printf 'mm_resolve_memory_creds() { :; }\n' >"$MISSING_HOOK_DIR/_common.sh"
PF_HOOK="$MISSING_HOOK_DIR/supply-ground.sh" run_pf --legs facts
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q 'is not a readable file'; then
  pass "missing hook => exit 1 from the readable-hook guard, not from _common.sh"
else
  fail "missing hook => exit 1 naming the readable-hook guard" "rc=$LAST_RC out='$LAST_OUT'"
fi
clear_context
run_pf --legs facts
if [ "$LAST_RC" -eq 0 ]; then
  pass "silent leg => exit 0 (the pair above is genuinely distinguished)"
else
  fail "silent leg => exit 0" "rc=$LAST_RC out='$LAST_OUT'"
fi

# ── drift: editing a copy that will not run ──────────────────────────────────
# The sibling is $DIR/supply-ground.sh — the real one. A stub with different
# CONTENT at a different path must read DIFFERS; a byte-identical copy at a
# different path must NOT, or the signal is noise.
set_context 'Facts from your memory'
run_pf --legs facts
if echo "$LAST_OUT" | grep -q 'DRIFT:'; then
  pass "drift: a hook whose content differs from the sibling is called out"
else
  fail "drift: differing content => DRIFT" "out='$LAST_OUT'"
fi

# The identical case can only be built from the REAL supply-ground.sh — drift is
# measured against that sibling, so a stub can never be byte-identical to it.
# Pointed at a closed local port so the real hook fails its curl instead of
# reaching a server: this case is about the drift line, and a pre-flight suite
# that quietly posts a bogus key to staging on every run is its own defect.
COPY="$WORK/copy/hooks/supply-ground.sh"
mkdir -p "$(dirname "$COPY")"
cp "$DIR/supply-ground.sh" "$COPY"
# The real `_common.sh` too: the pre-flight requires one beside the hook it chose,
# and this case is about the DRIFT line, not about the missing-companion refusal
# that the broken-hook cases below construct on purpose.
cp "$DIR/_common.sh" "$(dirname "$COPY")/_common.sh"
PF_HOOK="$COPY" MOLLOW_MEMORY_URL="http://127.0.0.1:1/mcp/v2" run_pf --legs facts
if echo "$LAST_OUT" | grep -q 'drift: *identical'; then
  pass "drift: a byte-identical copy at another path reads 'identical', not DIFFERS"
else
  fail "drift: identical copy must not alarm" "out='$LAST_OUT'"
fi

# ── live-copy resolution from the process tree ───────────────────────────────
# Constructed, because a real `ps` cannot be made to hold the ambiguity on
# demand: several sessions run at once and each loads a different worktree, so a
# resolver that scanned for the first match anywhere would confidently report a
# NEIGHBOUR's copy. The table below puts the neighbour FIRST for that reason.
make_stub "$WORK/mine/plugins/memory-mirror/hooks/supply-ground.sh"
make_stub "$WORK/theirs/plugins/memory-mirror/hooks/supply-ground.sh"

# The walk starts at pid 9992, injected, because a `$(...)` capture forks a
# subshell and the script's real PPID is that subshell rather than this suite.
# The neighbour is listed FIRST so a resolver that scanned for any --plugin-dir
# instead of walking the ancestry would pick it and this case would go red.
TABLE="printf '%s\n' \
 '9991 1 /bin/claude --plugin-dir $WORK/theirs/plugins/memory-mirror' \
 '9992 9990 bash test-preflight-supply.sh' \
 '9990 1 /bin/claude --plugin-dir $WORK/mine/plugins/memory-mirror'"

LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE" MM_PREFLIGHT_START_PID=9992 bash "$SCRIPT" --legs facts 2>&1 || true)"
if echo "$LAST_OUT" | grep -qF "$WORK/mine/plugins/memory-mirror/hooks/supply-ground.sh"; then
  pass "resolve: walks its OWN ancestry, not the first --plugin-dir in the table"
else
  fail "resolve: own ancestry wins" "out='$LAST_OUT'"
fi
if echo "$LAST_OUT" | grep -qF "$WORK/theirs/"; then
  fail "resolve: must not report the neighbour session's copy" "out='$LAST_OUT'"
else
  pass "resolve: the neighbour session's copy is never reported"
fi

# No --plugin-dir anywhere in the ancestry, and no marketplace cache to fall
# back to. The script must refuse rather than quietly run its own sibling — the
# sibling is the copy being EDITED, and running it would confirm an edit that a
# real session would never load.
TABLE_BARE="printf '%s\n' '9992 9990 bash test-preflight-supply.sh' '9990 1 /bin/claude'"
if LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_BARE" MM_PREFLIGHT_START_PID=9992 \
  HOME="$WORK/emptyhome" bash "$SCRIPT" --legs facts 2>&1)"; then LAST_RC=0; else LAST_RC=$?; fi
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q 'cannot tell which copy'; then
  pass "resolve: no --plugin-dir and no cache => refuses, never falls back to the sibling"
else
  fail "resolve: bare claude with no cache => exit 1" "rc=$LAST_RC out='$LAST_OUT'"
fi

# ── a hook that EXISTS but cannot run is not a silent leg (Greptile P1) ──────
# supply-ground.sh is fail-open by contract — every path ends at `exit 0` — so a
# non-zero exit means it could not run at all. Discarding the status made that
# emit nothing and classify as `silent`, a LEGITIMATE outcome meaning a miss.
# The fixture is the real failure: a copy of supply-ground.sh with no _common.sh
# beside it, which is exactly what the drift case above constructs.
BROKEN_DIR="$WORK/broken/hooks"
mkdir -p "$BROKEN_DIR"
cp "$DIR/supply-ground.sh" "$BROKEN_DIR/supply-ground.sh" # deliberately no _common.sh
PF_HOOK="$BROKEN_DIR/supply-ground.sh" run_pf --legs facts
# Asserts the UP-FRONT guard's own wording, not merely that `_common.sh` appears.
# A bare grep for the filename matches the OTHER guard too: with this check
# removed the real hook runs, fails to source its missing companion, and exits
# non-zero — so `hook_error` prints stderr that also contains `_common.sh`, and
# the case stays green on the regression. Measured: mutating this guard to
# `if false` did NOT redden a filename-only assertion. The two guards cover the
# same input, so each has to be pinned to a string only it can produce.
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q 'has no readable _common.sh beside it'; then
  pass "broken hook: no _common.sh => exit 1 from the up-front guard, before the hook runs"
else
  fail "broken hook: missing _common.sh => exit 1 from the up-front guard" "rc=$LAST_RC out='$LAST_OUT'"
fi

# And a hook that DOES have _common.sh but dies anyway must still not read as a
# miss. A `set -u` on an unset variable is the realistic shape.
DIES_DIR="$WORK/dies/hooks"
mkdir -p "$DIES_DIR"
: >"$DIES_DIR/_common.sh"
cat >"$DIES_DIR/supply-ground.sh" <<'DIES'
#!/usr/bin/env bash
set -uo pipefail
cat >/dev/null
echo "boom: cannot run" >&2
exit 3
DIES
chmod +x "$DIES_DIR/supply-ground.sh"
PF_HOOK="$DIES_DIR/supply-ground.sh" run_pf --legs facts
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q 'exited 3'; then
  pass "broken hook: a non-zero exit => exit 1, never classified silent"
else
  fail "broken hook: non-zero exit => exit 1" "rc=$LAST_RC out='$LAST_OUT'"
fi

# The negative half: the stub exits 0 with no output, which MUST stay `silent`
# and exit 0. Without this the two cases above would pass on a script that
# failed every empty leg, and `silent` would be unreachable.
clear_context
run_pf --legs facts
if [ "$LAST_RC" -eq 0 ] && echo "$LAST_OUT" | grep -q 'facts *silent'; then
  pass "broken hook: an exit-0 empty leg is still silent (the pair is distinguished)"
else
  fail "broken hook: exit-0 empty leg stays silent" "rc=$LAST_RC out='$LAST_OUT'"
fi

# ── a plugin dir with a SPACE (Greptile P1) ──────────────────────────────────
# Two different shapes, and they do NOT behave the same. The extractor takes the
# value up to the next ` --`, so a spaced path IS fully recovered whenever a FLAG
# follows it — which is every real launcher invocation, since `claude-session`
# always passes `--setting-sources` after the plugin dirs. Asserting a refusal
# here would have been asserting a defect.
SPACED="$WORK/my worktree/plugins/memory-mirror"
make_stub "$SPACED/hooks/supply-ground.sh"
TABLE_SP="printf '%s\n' '9992 9990 bash test' '9990 1 /bin/claude --plugin-dir $SPACED --setting-sources user'"
LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_SP" MM_PREFLIGHT_START_PID=9992 bash "$SCRIPT" --legs facts 2>&1 || true)"
if echo "$LAST_OUT" | grep -qF "$SPACED/hooks/supply-ground.sh"; then
  pass "spaced plugin dir: recovered in full when a flag follows it"
else
  fail "spaced plugin dir: recovered when a flag follows" "out='$LAST_OUT'"
fi

# The shape that genuinely cannot be recovered: a NON-flag argument after a spaced
# path. There is no way to tell the path's last word from the next argument, so the
# extracted value is not a directory. What must never happen then is falling
# through to the marketplace cache — that would test a copy this session does not
# load, which is worse than refusing. The fixture places a REAL stub at the spaced
# path, so substituting the cache is observably wrong rather than merely different.
CACHE_DECOY="$WORK/spacedhome/.claude/plugins/cache/mollow-local/memory-mirror/1.0.0/hooks"
make_stub "$CACHE_DECOY/supply-ground.sh"
TABLE_SP2="printf '%s\n' '9992 9990 bash test' '9990 1 /bin/claude --plugin-dir $SPACED trailing-positional'"
if LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_SP2" MM_PREFLIGHT_START_PID=9992 HOME="$WORK/spacedhome" bash "$SCRIPT" --legs facts 2>&1)"; then LAST_RC=0; else LAST_RC=$?; fi
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q 'is not there'; then
  pass "spaced plugin dir: unrecoverable shape refuses instead of using the cache"
else
  fail "spaced plugin dir: unrecoverable shape => exit 1, no cache fallback" "rc=$LAST_RC out='$LAST_OUT'"
fi
if echo "$LAST_OUT" | grep -qF "$CACHE_DECOY"; then
  fail "spaced plugin dir: the cached decoy must never be reported" "out='$LAST_OUT'"
else
  pass "spaced plugin dir: the cached decoy was not substituted"
fi

# A path with NO space resolves cleanly through the same extractor, including when
# memory-mirror is not the first --plugin-dir the launcher passed. Without this the
# case above would pass on an extractor that refused everything.
make_stub "$WORK/clean/plugins/memory-mirror/hooks/supply-ground.sh"
TABLE_2ND="printf '%s\n' '9992 9990 bash test' '9990 1 /bin/claude --plugin-dir $WORK/clean/plugins/hotline --plugin-dir $WORK/clean/plugins/memory-mirror --setting-sources user'"
LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_2ND" MM_PREFLIGHT_START_PID=9992 bash "$SCRIPT" --legs facts 2>&1 || true)"
if echo "$LAST_OUT" | grep -qF "$WORK/clean/plugins/memory-mirror/hooks/supply-ground.sh"; then
  pass "extractor: picks memory-mirror even when it is not the first --plugin-dir"
else
  fail "extractor: second --plugin-dir wins by name, not position" "out='$LAST_OUT'"
fi

# memory-mirror FIRST of several plugin dirs. This is the only arrangement that
# puts a trailing space on the SELECTED value: splitting on the flag consumes the
# space that preceded the NEXT `--plugin-dir`, and `s/ --.*//` cannot see it
# because the following `--` was the delimiter. The case above cannot express it —
# there the trailing space lands on the hotline segment, which is discarded — so
# removing the strip leaves that case green. This is the real launcher order
# (`claude-session` passes memory-mirror first), which is why it matters.
make_stub "$WORK/first/plugins/memory-mirror/hooks/supply-ground.sh"
TABLE_1ST="printf '%s\n' '9992 9990 bash test' '9990 1 /bin/claude --plugin-dir $WORK/first/plugins/memory-mirror --plugin-dir $WORK/first/plugins/hotline --setting-sources user'"
LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_1ST" MM_PREFLIGHT_START_PID=9992 bash "$SCRIPT" --legs facts 2>&1 || true)"
if echo "$LAST_OUT" | grep -qF "$WORK/first/plugins/memory-mirror/hooks/supply-ground.sh"; then
  pass "extractor: memory-mirror FIRST of several resolves (trailing space stripped)"
else
  fail "extractor: first-of-several must not carry a trailing space" "out='$LAST_OUT'"
fi

# ── several cached copies => refuse, never pick by path order (Greptile P1) ───
# Which version a bare `claude` loads is pinned in settings.json and is not
# decidable from these paths, so picking one could report success for a copy no
# session runs.
CH="$WORK/cachehome/.claude/plugins/cache/mollow-local/memory-mirror"
make_stub "$CH/1.0.0/hooks/supply-ground.sh"
make_stub "$CH/2.0.0/hooks/supply-ground.sh"
TABLE_BARE2="printf '%s\n' '9992 9990 bash test' '9990 1 /bin/claude'"
if LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_BARE2" MM_PREFLIGHT_START_PID=9992 HOME="$WORK/cachehome" bash "$SCRIPT" --legs facts 2>&1)"; then LAST_RC=0; else LAST_RC=$?; fi
if [ "$LAST_RC" -eq 1 ] && echo "$LAST_OUT" | grep -q '2 cached copies'; then
  pass "cache: two cached versions => refuses and names both"
else
  fail "cache: multiple versions => exit 1" "rc=$LAST_RC out='$LAST_OUT'"
fi

# Exactly one cached copy still resolves, or the case above would pass on a
# script that refused the cache path entirely.
CH1="$WORK/cachehome1/.claude/plugins/cache/mollow-local/memory-mirror/1.0.0/hooks"
make_stub "$CH1/supply-ground.sh"
LAST_OUT="$(MM_PREFLIGHT_PS="$TABLE_BARE2" MM_PREFLIGHT_START_PID=9992 HOME="$WORK/cachehome1" bash "$SCRIPT" --legs facts 2>&1 || true)"
if echo "$LAST_OUT" | grep -q 'marketplace cache'; then
  pass "cache: exactly one cached copy resolves through the cache path"
else
  fail "cache: single copy resolves" "out='$LAST_OUT'"
fi

# ── the client-side opt-in is reported separately (Greptile P2) ───────────────
# `--expect-pointer served` proves the SERVER flag. Real sessions keep asking for
# facts until MOLLOW_SUPPLY_POINTER_MODE is exported, so a pre-flight that showed
# only the server half would stand in for a half-configured demo.
set_context 'Mollow supply mode handed you POINTERS, not content.'
LAST_OUT="$(MM_PREFLIGHT_HOOK="$STUB" bash "$SCRIPT" --legs pointer 2>&1 || true)"
if echo "$LAST_OUT" | grep -q 'MOLLOW_SUPPLY_POINTER_MODE is UNSET here'; then
  pass "client opt-in: unset in the environment is stated next to a served pointer leg"
else
  fail "client opt-in: unset is reported" "out='$LAST_OUT'"
fi
LAST_OUT="$(MM_PREFLIGHT_HOOK="$STUB" MOLLOW_SUPPLY_POINTER_MODE=on bash "$SCRIPT" --legs pointer 2>&1 || true)"
if echo "$LAST_OUT" | grep -q 'MOLLOW_SUPPLY_POINTER_MODE=on in this environment'; then
  pass "client opt-in: set in the environment is reported as set"
else
  fail "client opt-in: set is reported" "out='$LAST_OUT'"
fi

# ── usage ────────────────────────────────────────────────────────────────────
run_pf --legs bogus
if [ "$LAST_RC" -eq 1 ]; then
  pass "usage: an unknown leg is refused"
else
  fail "usage: unknown leg => exit 1" "rc=$LAST_RC out='$LAST_OUT'"
fi

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
