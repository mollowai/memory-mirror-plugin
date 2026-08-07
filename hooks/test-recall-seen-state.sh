#!/usr/bin/env bash
set -euo pipefail
# Tests for mm_seen_add — the locked read-modify-write behind recall-decisions.sh's
# contradiction seen-state (MOL-3755).
#
# The contract under test is concurrency. `recall-decisions.sh` fires on EVERY
# UserPromptSubmit, and this machine routinely runs many Claude sessions at once,
# so two hooks writing the shared seen-state file overlap in practice. An
# unlocked read-modify-replace loses the other writer's keys, and a lost key means
# an already-shown contradiction is injected into context a second time.
#
# Run: bash plugins/memory-mirror/hooks/test-recall-seen-state.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No key ⇒ mm_ready() short-circuits; nothing here should reach the network.
unset MOLLOW_MEMORY_API_KEY
# shellcheck source=/dev/null
. "$DIR/_common.sh"

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

tmpdir() { mktemp -d "${TMPDIR:-/tmp}/mm-seen-XXXXXX"; }

# ── records into a file that does not exist yet ──────────────────────────────
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["claim:a|claim:b"]' || true
if [ "$(jq -r '.prod[0]' "$f" 2>/dev/null)" = "claim:a|claim:b" ]; then
  pass "creates the state file on first record"
else
  fail "creates the state file on first record" "got: $(cat "$f" 2>/dev/null)"
fi
rm -rf "$t"

# ── merges rather than replaces, and keeps keys env-scoped ───────────────────
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["claim:a|claim:b"]' || true
mm_seen_add "$f" "prod" '["claim:c|claim:d"]' || true
mm_seen_add "$f" "staging" '["claim:e|claim:f"]' || true
if [ "$(jq -r '.prod | length' "$f")" = "2" ] && [ "$(jq -r '.staging | length' "$f")" = "1" ]; then
  pass "merges into the existing key and keeps envs separate"
else
  fail "merges into the existing key and keeps envs separate" "got: $(cat "$f")"
fi
rm -rf "$t"

# ── the regression: concurrent writers must not lose each other's keys ───────
# Without a lock each writer rewrites the file from its own snapshot, so the
# last mv wins and the rest of the keys vanish.
#
# These callers do NOT retry — they invoke mm_seen_add exactly the way
# recall-decisions.sh does, one shot. An earlier version of this test wrapped the
# call in a retry loop the production caller does not have, so it proved a
# durability the hook does not actually get. Whatever this asserts has to be true
# of the real caller.
t="$(tmpdir)"
f="$t/seen.json"
WRITERS=4
for i in $(seq 1 "$WRITERS"); do
  (
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    mm_seen_add "$f" "prod" "[\"claim:$i|claim:x\"]"
  ) &
done
wait

recorded="$(jq -r '.prod | length' "$f" 2>/dev/null || echo 0)"
if [ "$recorded" = "$WRITERS" ]; then
  pass "$WRITERS concurrent one-shot writers all land ($recorded/$WRITERS keys)"
else
  fail "$WRITERS concurrent one-shot writers all land" "kept $recorded/$WRITERS" "got: $(cat "$f" 2>/dev/null)"
fi
rm -rf "$t"

# ── under contention beyond the retry budget: may drop, must never corrupt ───
# The honest limit of a bounded retry. A dropped key re-shows one advisory once;
# a corrupt file would break seen-state for every contradiction on this machine,
# so THAT is the property worth guaranteeing unconditionally.
t="$(tmpdir)"
f="$t/seen.json"
for i in $(seq 1 24); do
  (
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    mm_seen_add "$f" "prod" "[\"claim:$i|claim:x\"]"
  ) &
done
wait

if jq -e 'type == "object" and (.prod | type) == "array"
          and (.prod | all(type == "string" and test("^claim:[0-9]+\\|claim:x$")))' \
  "$f" >/dev/null 2>&1; then
  pass "heavy contention may drop a key but leaves valid state ($(jq -r '.prod|length' "$f")/24 kept)"
else
  fail "heavy contention leaves valid state" "got: $(cat "$f" 2>/dev/null)"
fi
rm -rf "$t"

# ── a held lock is declined, not ignored ─────────────────────────────────────
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["claim:a|claim:b"]' || true
mkdir "$f.lock"
if mm_seen_add "$f" "prod" '["claim:should-not-land"]'; then
  fail "declines while another writer holds the lock" "returned 0 with the lock held"
else
  pass "declines while another writer holds the lock"
fi
if jq -e '.prod | index("claim:should-not-land")' "$f" >/dev/null 2>&1; then
  fail "a declined write leaves the file untouched" "got: $(cat "$f")"
else
  pass "a declined write leaves the file untouched"
fi
rmdir "$f.lock"
rm -rf "$t"

# ── a stale lock from a dead hook is stolen, not obeyed forever ──────────────
t="$(tmpdir)"
f="$t/seen.json"
mkdir "$f.lock"
# Backdate past the staleness threshold, as a hook killed mid-write would leave it.
touch -t "$(date -v-10M '+%Y%m%d%H%M' 2>/dev/null || date -d '10 minutes ago' '+%Y%m%d%H%M')" "$f.lock"
if mm_seen_add "$f" "prod" '["claim:a|claim:b"]' &&
  [ "$(jq -r '.prod[0]' "$f" 2>/dev/null)" = "claim:a|claim:b" ]; then
  pass "steals a stale lock left by a dead writer"
else
  fail "steals a stale lock left by a dead writer" "got: $(cat "$f" 2>/dev/null)"
fi
rm -rf "$t"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]
