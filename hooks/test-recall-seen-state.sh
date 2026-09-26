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

# ── eviction is by RECENCY, not lexicographic order ─────────────────────────
#
# The bug this fences: the cap used to be `(existing + new) | unique | .[-500:]`,
# and `unique` SORTS. Eviction therefore kept the 500 lexicographically-highest
# ids regardless of when they were seen — and because these ids are content
# digests, that is arbitrary per fact and permanent. A fact whose digest sorted
# low was re-injected every turn; one that sorted high stayed suppressed forever.
#
# The fixture is built so the two behaviours DISAGREE. 500 ids that sort ABOVE the
# probe fill the cap; then the probe is seen. Under sorted eviction the probe is
# dropped on the same write that recorded it. Under recency eviction the probe
# survives and the oldest id goes. A fixture whose probe sorted high would pass
# either way and fence nothing.
t="$(tmpdir)"
f="$t/seen.json"
high="$(python3 -c "import json;print(json.dumps(['zzz%03d' % i for i in range(500)]))")"
mm_seen_add "$f" "prod" "$high" || true
before="$(jq -r '.prod | length' "$f")"
if [ "$before" != "500" ]; then
  fail "fixture precondition: cap should be full at 500" "got $before"
else
  mm_seen_add "$f" "prod" '["aaa-just-seen"]' || true
  kept="$(jq -r '.prod | index("aaa-just-seen") // "absent"' "$f")"
  oldest="$(jq -r '.prod | index("zzz000") // "absent"' "$f")"
  count="$(jq -r '.prod | length' "$f")"

  if [ "$kept" = "absent" ]; then
    fail "a just-seen id was evicted on the write that recorded it" \
      "this is the lexicographic-eviction bug: the probe sorts below every id in the cap"
  elif [ "$oldest" != "absent" ]; then
    fail "the oldest id survived while the cap stayed at $count" \
      "eviction did not drop the least-recently-seen entry"
  elif [ "$count" != "500" ]; then
    fail "cap not honoured" "expected 500, got $count"
  else
    pass "eviction drops the least-recently-seen id, not the lexicographically-lowest"
  fi
fi

# ── re-seeing an id REFRESHES it rather than leaving it stale ────────────────
#
# The property that makes the cap an LRU rather than a FIFO. Without it, an id
# seen on every single turn would still age out after 500 others, and the fact
# would be re-injected despite never having gone unseen.
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["keep-me"]' || true
filler="$(python3 -c "import json;print(json.dumps(['f%03d' % i for i in range(499)]))")"
mm_seen_add "$f" "prod" "$filler" || true
mm_seen_add "$f" "prod" '["keep-me"]' || true   # re-seen: moves to the end
mm_seen_add "$f" "prod" '["one-more"]' || true  # forces an eviction
if [ "$(jq -r '.prod | index("keep-me") // "absent"' "$f")" = "absent" ]; then
  fail "a re-seen id was evicted" "re-seeing must move it to the end of the recency order"
elif [ "$(jq -r '.prod | index("f000") // "absent"' "$f")" != "absent" ]; then
  fail "the eviction dropped something other than the oldest" "f000 should have gone"
else
  pass "re-seeing an id refreshes its position, so it outlives older entries"
fi

# ── no duplicates, on the FIRST write as well as later ones ─────────────────
#
# Split into two cases because they go through DIFFERENT jq branches, and the
# first version of this test only exercised one of them.
#
# An absent file makes the main filter fail, so mm_seen_add falls through to
# `{($k): $new}` — which had no dedupe at all, because the main branch gets its
# dedupe from `- $new` and there is nothing to subtract from when the key is new.
# The original test wrote duplicates on a fresh file and then wrote again, so the
# SECOND write cleaned up after the first and the assertion passed over a real
# bug. Greptile caught that on #6360.
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["dup","dup","other"]' || true   # fresh file: fallback branch
first_total="$(jq -r '.prod | length' "$f")"
first_uniq="$(jq -r '.prod | unique | length' "$f")"
if [ "$first_total" != "$first_uniq" ]; then
  fail "the FIRST write stored duplicates" \
    "length=$first_total distinct=$first_uniq — the absent-file branch needs its own unique"
else
  pass "a first write into an absent file dedupes within the batch"
fi

mm_seen_add "$f" "prod" '["dup","other","third","third"]' || true  # file exists: main branch
n_total="$(jq -r '.prod | length' "$f")"
n_uniq="$(jq -r '.prod | unique | length' "$f")"
if [ "$n_total" != "$n_uniq" ]; then
  fail "duplicates accumulated on a subsequent write" "length=$n_total distinct=$n_uniq"
else
  pass "later writes stay distinct across and within batches"
fi

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
