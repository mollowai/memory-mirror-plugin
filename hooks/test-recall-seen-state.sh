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

# ── the key itself: per SESSION, not per environment (MOL-8078) ──────────────
#
# The whole point of the change. Suppression was keyed by env label alone, so a
# fact injected in one session was unservable in every other session on the host
# for ~100 turns — including a session that had never seen it.
if [ "$(mm_supply_seen_key prod abc123)" = "prod:abc123" ]; then
  pass "the key carries both the env label and the session"
else
  fail "the key carries both the env label and the session" \
    "got: $(mm_supply_seen_key prod abc123)"
fi

# The env label STAYS: a session id says nothing about which corpus answered, and
# the file has no other discriminator. Two sessions on different targets must not
# share a list.
if [ "$(mm_supply_seen_key prod s1)" != "$(mm_supply_seen_key staging s1)" ]; then
  pass "the same session against two targets gets two keys"
else
  fail "the same session against two targets gets two keys"
fi

# An absent session id falls back to TODAY'S behaviour rather than minting a
# `prod:` suffix that every id-less session would share. A shared degenerate key
# would look per-session while behaving machine-wide — harder to notice than the
# original defect.
if [ "$(mm_supply_seen_key prod '')" = "prod" ] &&
  [ "$(mm_supply_seen_key prod)" = "prod" ]; then
  pass "an absent session id falls back to the bare env label"
else
  fail "an absent session id falls back to the bare env label" \
    "empty: $(mm_supply_seen_key prod '')  missing: $(mm_supply_seen_key prod)"
fi

# Whitespace in a session id is a malformed input, not a key to honour: a tab or
# newline inside a JSON object key is where quoting surprises live.
if [ "$(mm_supply_seen_key prod "$(printf 'a\tb c\n')")" = "prod:abc" ]; then
  pass "tabs, spaces and newlines are stripped from the session id"
else
  fail "tabs, spaces and newlines are stripped from the session id" \
    "got: $(mm_supply_seen_key prod "$(printf 'a\tb c\n')")"
fi

# ── two sessions no longer suppress each other ───────────────────────────────
#
# The behaviour MOL-8078 is about, asserted end to end through mm_seen_add
# rather than only through the key helper.
t="$(tmpdir)"
f="$t/seen.json"
k1="$(mm_supply_seen_key prod sessA)"
k2="$(mm_supply_seen_key prod sessB)"
mm_seen_add "$f" "$k1" '["fact-x"]' || true
mm_seen_add "$f" "$k2" '["fact-y"]' || true
a_sees="$(jq -r --arg k "$k1" '.[$k] | index("fact-y") // "absent"' "$f")"
b_sees="$(jq -r --arg k "$k2" '.[$k] | index("fact-x") // "absent"' "$f")"
a_own="$(jq -r --arg k "$k1" '.[$k] | index("fact-x") // "absent"' "$f")"
if [ "$a_sees" = absent ] && [ "$b_sees" = absent ] && [ "$a_own" != absent ]; then
  pass "one session's injected fact is not suppressed for another"
else
  fail "one session's injected fact is not suppressed for another" \
    "A sees B's: $a_sees  B sees A's: $b_sees  A sees own: $a_own"
fi
rm -rf "$t"

# ── the key count is capped, and eviction is least-recently-WRITTEN ──────────
#
# Per-session keys made an unbounded dimension out of what used to be one key,
# so the cap is part of the same change rather than a follow-up.
#
# The fixture makes the two candidate behaviours DISAGREE, the same discipline as
# the id-eviction fixture above. With a cap of 3: write k1 k2 k3, then RE-write
# k1, then add k4. Under evict-by-FIRST-write (what a bare `.[$k] = …` gives,
# because jq updates an existing key in place) k1 is dropped. Under
# evict-by-LAST-write — which is what `del(.[$k])` before the assignment buys —
# k2 is dropped and k1 survives. A fixture that never re-wrote a key would pass
# either way and fence nothing.
t="$(tmpdir)"
f="$t/seen.json"
export MM_SEEN_MAX_KEYS=3
mm_seen_add "$f" "k1" '["a"]' || true
mm_seen_add "$f" "k2" '["b"]' || true
mm_seen_add "$f" "k3" '["c"]' || true
mm_seen_add "$f" "k1" '["a2"]' || true
mm_seen_add "$f" "k4" '["d"]' || true
n_keys="$(jq -r 'keys | length' "$f")"
has_k1="$(jq -r 'has("k1")' "$f")"
has_k2="$(jq -r 'has("k2")' "$f")"
has_k4="$(jq -r 'has("k4")' "$f")"
unset MM_SEEN_MAX_KEYS
if [ "$n_keys" = 3 ] && [ "$has_k1" = true ] && [ "$has_k2" = false ] && [ "$has_k4" = true ]; then
  pass "the key count is capped and the least-recently-WRITTEN key is evicted"
else
  fail "the key count is capped and the least-recently-WRITTEN key is evicted" \
    "keys=$n_keys k1=$has_k1 k2=$has_k2 k4=$has_k4" "file: $(cat "$f")"
fi
rm -rf "$t"

# A re-written key must keep its EARLIER ids, or moving it to the end would be a
# data loss dressed as an eviction policy.
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod:s" '["first"]' || true
mm_seen_add "$f" "prod:s" '["second"]' || true
both="$(jq -r '."prod:s" | (index("first") != null) and (index("second") != null)' "$f")"
if [ "$both" = true ]; then
  pass "re-writing a key preserves the ids it already held"
else
  fail "re-writing a key preserves the ids it already held" "got: $(cat "$f")"
fi
rm -rf "$t"

# CONTROL: the one-key caller (recall-decisions.sh's contradiction file) is
# untouched by the key cap. Without this, a cap bug that dropped every key but
# the newest would still pass everything above.
t="$(tmpdir)"
f="$t/seen.json"
mm_seen_add "$f" "prod" '["x"]' || true
mm_seen_add "$f" "prod" '["y"]' || true
if [ "$(jq -r 'keys | length' "$f")" = 1 ] &&
  [ "$(jq -r '.prod | length' "$f")" = 2 ]; then
  pass "a single-key caller is unaffected by the key cap"
else
  fail "a single-key caller is unaffected by the key cap" "got: $(cat "$f")"
fi
rm -rf "$t"

# A garbage or zero MM_SEEN_MAX_KEYS must not silently evict everything.
t="$(tmpdir)"
f="$t/seen.json"
export MM_SEEN_MAX_KEYS=nonsense
mm_seen_add "$f" "k1" '["a"]' || true
mm_seen_add "$f" "k2" '["b"]' || true
unset MM_SEEN_MAX_KEYS
if [ "$(jq -r 'keys | length' "$f")" = 2 ]; then
  pass "a malformed MM_SEEN_MAX_KEYS falls back to the default instead of evicting"
else
  fail "a malformed MM_SEEN_MAX_KEYS falls back to the default instead of evicting" \
    "got: $(cat "$f")"
fi
rm -rf "$t"

# ── a cap that evaluates to zero must not DISABLE the cap ───────────────────
#
# The failure runs the other way from the one above and is the one a string test
# misses (Greptile, #7574): `00` is all digits and is not the string `0`, so a
# `case` arm matching the literal `0` lets it through — and jq accepts `00` as
# JSON, where `.[-0:]` keeps the WHOLE array. The cap reads as configured and
# bounds nothing.
#
# This needs MORE KEYS THAN THE DEFAULT CAP to say anything. The first version
# of this case wrote four and asserted "4 of 4 survive", which is also exactly
# what the bug produces — it passed with the fix reverted. Writing 205 is the
# only fixture where falling back to 200 and disabling the cap differ.
for val in 00 000; do
  t="$(tmpdir)"
  f="$t/seen.json"
  export MM_SEEN_MAX_KEYS="$val"
  i=1
  while [ "$i" -le 205 ]; do
    mm_seen_add "$f" "k$i" "[\"v$i\"]" || true
    i=$((i + 1))
  done
  unset MM_SEEN_MAX_KEYS
  got="$(jq -r 'keys | length' "$f" 2>/dev/null)"
  if [ "$got" = "200" ]; then
    pass "MM_SEEN_MAX_KEYS=$val falls back to the default cap (200 of 205 keys kept)"
  else
    fail "MM_SEEN_MAX_KEYS=$val falls back to the default cap" \
      "kept $got of 205 — 205 means a zero-valued cap disabled the bound"
  fi
  rm -rf "$t"
done

# `10#` pins base 10 in the normalisation. Pre-fix the string went straight to
# jq, which reads `010` as ten; bash arithmetic without `10#` would read it as
# octal EIGHT, so this fences the fix against introducing a bug of its own
# rather than re-testing the old one. 12 keys makes all three outcomes
# distinguishable: ten (correct), eight (octal), twelve (no cap).
t="$(tmpdir)"
f="$t/seen.json"
export MM_SEEN_MAX_KEYS=010
i=1
while [ "$i" -le 12 ]; do
  mm_seen_add "$f" "k$i" "[\"v$i\"]" || true
  i=$((i + 1))
done
unset MM_SEEN_MAX_KEYS
got="$(jq -r 'keys | length' "$f" 2>/dev/null)"
if [ "$got" = "10" ]; then
  pass "MM_SEEN_MAX_KEYS=010 is ten, not octal eight (10 of 12 keys kept)"
else
  fail "MM_SEEN_MAX_KEYS=010 is ten, not octal eight" \
    "kept $got of 12 — 8 means octal, 12 means no cap"
fi
rm -rf "$t"

# The literal `0` was already rejected before this change; it stays as a control
# so a future rewrite of the normalisation cannot regress it. Four keys is a
# correct assertion here only because the expectation is the 200 default.
for spec in "0:4" "3:3" "1:1"; do
  val="${spec%%:*}"
  want_keys="${spec#*:}"
  t="$(tmpdir)"
  f="$t/seen.json"
  export MM_SEEN_MAX_KEYS="$val"
  for i in 1 2 3 4; do mm_seen_add "$f" "k$i" "[\"v$i\"]" || true; done
  unset MM_SEEN_MAX_KEYS
  got="$(jq -r 'keys | length' "$f" 2>/dev/null)"
  if [ "$got" = "$want_keys" ]; then
    pass "MM_SEEN_MAX_KEYS=$val keeps $want_keys of 4 keys"
  else
    fail "MM_SEEN_MAX_KEYS=$val keeps $want_keys of 4 keys" "kept $got"
  fi
  rm -rf "$t"
done

# A digit string too long to be a meaningful cap must fall back rather than
# abort the caller in arithmetic — mm_seen_add runs from a hook that must never
# cost a turn its context.
t="$(tmpdir)"
f="$t/seen.json"
export MM_SEEN_MAX_KEYS=99999999999999999999
# `cmd || true` followed by `rc=$?` reads the status of the `|| true`, which is
# always 0 — so the abort half of this assertion was dead and would have passed
# even if mm_seen_add aborted, the one thing this case exists to catch. Under
# `set -e` the status has to be captured in the `||` branch instead.
rc1=0
mm_seen_add "$f" "k1" '["a"]' || rc1=$?
rc2=0
mm_seen_add "$f" "k2" '["b"]' || rc2=$?
unset MM_SEEN_MAX_KEYS
if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] &&
   [ "$(jq -r 'keys | length' "$f" 2>/dev/null)" = 2 ]; then
  pass "an absurdly long MM_SEEN_MAX_KEYS falls back without aborting the caller"
else
  fail "an absurdly long MM_SEEN_MAX_KEYS falls back without aborting the caller" \
    "rc1=$rc1 rc2=$rc2 file: $(cat "$f" 2>/dev/null)"
fi
rm -rf "$t"

echo
echo "Passed: $PASS  Failed: $FAIL"
[ "$FAIL" -eq 0 ]