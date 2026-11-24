#!/usr/bin/env bash
# MOL-9571: a memory-rail miss must say WHICH miss it was, and an outage must be
# said once, mid-session.
#
# ## What this pins
#
# 1. Per FAILURE MODE, not per call. The issue's own negcheck: a single stub
#    that always times out passes under both the old and the new
#    implementation, because the old one also wrote `recall_unreachable` for a
#    timeout. So each mode is stubbed in turn — timeout, DNS, refused, a body
#    cut off mid-transfer, a 500 and a 403 — and every one must land as a
#    DIFFERENT record. Against the pre-fix hooks every transient case reads
#    `recall_unreachable` with no class and no detail, and those assertions go
#    red.
# 2. A definite error (500/403) is recorded as `*_refused:http<code>`, never as
#    `*_unreachable`, because it was already said in context and the close's
#    unreachable count is for the silent misses only.
# 3. A working call is recorded as `*_ok` with its latency, so the ledger has a
#    denominator and step 2 has a distribution to place a cap against.
# 4. The streak: below the threshold, silence; AT it, exactly one line; past
#    it, silence again; a success resets it, and the next outage is said again.
#
# Both rails run through the REAL hooks against a stubbed curl that behaves
# like curl 8.7.1 measured on 2026-11-24: `-w` output is printed even when the
# transfer fails (`\n000\t<secs>` on a timeout, NXDOMAIN and refused port; a
# cut-off 200 prints its partial body then `\n200\t<secs>` and exits 28).
#
# Run: bash plugins/mollow-claude/hooks/test-rail-failure-detail.sh

# Each case sets its STUB_* inside a `( … )` on purpose, so one case's stub can
# never leak into the next; `export "$@"` exports NAME=VALUE pairs passed in,
# and `STUB_BODY=` is a deliberate empty value.
# shellcheck disable=SC2030,SC2031,SC2163,SC1007

set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
# Most cases run inside `( … )`, where `FAIL=$((FAIL + 1))` changes only the
# child's copy. So every failure is ALSO appended to a file the parent reads
# before it exits — otherwise a contract breach inside a subshell (a hook that
# wrote to stderr or exited nonzero) would print FAIL and the suite exit 0
# (Greptile on #8718).
fail() {
  [ -n "${TMP:-}" ] && printf '%s\n' "$1" >>"$TMP/failures"
  echo -e "${RED}FAIL${NC}: $1"
  shift
  for line in "$@"; do echo "  $line"; done
  FAIL=$((FAIL + 1))
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-rail-detail-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/repo"
( cd "$TMP/repo" && git init -q . ) >/dev/null 2>&1

# STUB_RC: curl's exit code. STUB_CODE: the http code `-w` reports. STUB_BODY:
# what the server sent. STUB_TIME: the elapsed seconds `-w` reports.
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${STUB_BODY:-}"
for a in "$@"; do
  case "$a" in
    *time_total*) printf '\n%s\t%s' "${STUB_CODE:-200}" "${STUB_TIME:-0.5}" ;;
    *http_code*) printf '\n%s' "${STUB_CODE:-200}" ;;
  esac
done
exit "${STUB_RC:-0}"
EOF
chmod +x "$TMP/bin/curl"

log() { printf '%s' "$TMP/home/.mollow/supply-stop-reasons.log"; }
latency_log() { printf '%s' "$TMP/home/.mollow/rail-latency.log"; }

# run_hook <hook> <session> — run one hook once under the current STUB_*; the
# emitted additionalContext lands in CTX.
run_hook() {
  local hook="$1" sid="$2" out
  out="$(
    printf '{"hook_event_name":"UserPromptSubmit","prompt":"how is the cap tuned?","cwd":"%s","session_id":"%s"}' "$TMP/repo" "$sid" |
      env -i \
        PATH="$TMP/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" \
        HOME="$TMP/home" \
        STUB_RC="${STUB_RC:-0}" STUB_CODE="${STUB_CODE:-200}" \
        STUB_BODY="${STUB_BODY:-}" STUB_TIME="${STUB_TIME:-0.5}" \
        MOLLOW_MEMORY_API_KEY="mol_test" \
        MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2" \
        MOLLOW_MEMORY_CREDS_FROM_FILES=0 \
        MOLLOW_SUPPLY_MODE=1 \
        ${MOLLOW_RAIL_STREAK_WARN:+MOLLOW_RAIL_STREAK_WARN=$MOLLOW_RAIL_STREAK_WARN} \
        bash "$DIR/$hook" 2>"$TMP/stderr"
  )"
  local rc=$?
  # The hook contract every case is held to: exit 0 and nothing on stderr. A
  # breach inside the new code would otherwise pass every assertion below.
  if [ "$rc" -ne 0 ] || [ -s "$TMP/stderr" ]; then
    fail "$hook broke its contract (rc=$rc)" "$(cat "$TMP/stderr")"
  fi
  CTX="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")"
}

# last_record — the reason and detail columns of the newest ledger line.
last_record() { tail -n 1 "$(log)" 2>/dev/null | awk -F'\t' '{print $4 "|" $5}'; }

mkdir -p "$TMP/home"
RECALL_OK='{"proposed_answer":null,"unmapped_top_choice":null,"count":0,"past_decisions":[],"contradictions":[]}'

# ── 1. every failure mode is a different record ───────────────────────────
echo "── recall: each failure mode lands as its own record ──"
check_mode() {
  local label="$1" want="$2"
  shift 2
  ( export "$@"; run_hook recall-decisions.sh "mode-$RANDOM" )
  local got
  got="$(last_record)"
  case "$got" in
    "$want"*) pass "$label ⇒ ${got}" ;;
    *) fail "$label" "expected a record starting '$want'" "got '$got'" ;;
  esac
}
check_mode "timeout before any response" "recall_unreachable:timeout|rc=28 http=000 t=2.004" \
  STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.004
check_mode "body cut off by the cap" "recall_unreachable:timeout_mid_body|rc=28 http=200 t=2.001" \
  STUB_RC=28 STUB_CODE=200 STUB_BODY='{"proposed_ans' STUB_TIME=2.001
check_mode "DNS failure" "recall_unreachable:dns|rc=6 http=000" \
  STUB_RC=6 STUB_CODE=000 STUB_BODY= STUB_TIME=0.011
check_mode "connection refused" "recall_unreachable:refused|rc=7 http=000" \
  STUB_RC=7 STUB_CODE=000 STUB_BODY= STUB_TIME=0.001
check_mode "a 200 with nothing in it" "recall_unreachable:empty_body|rc=0 http=200" \
  STUB_RC=0 STUB_CODE=200 STUB_BODY= STUB_TIME=0.4
check_mode "a 200 carrying an HTML page" "recall_unreachable:unparseable|rc=0 http=200" \
  STUB_RC=0 STUB_CODE=200 STUB_BODY='<html>Just a moment...</html>' STUB_TIME=0.3
check_mode "a 200 carrying half a JSON document" "recall_unreachable:unparseable|rc=0 http=200" \
  STUB_RC=0 STUB_CODE=200 STUB_BODY='{"proposed_ans' STUB_TIME=0.3
check_mode "a 500" "recall_refused:http500|rc=0 http=500" \
  STUB_RC=0 STUB_CODE=500 STUB_BODY='{"error":"boom"}' STUB_TIME=0.3
check_mode "a 403 from a wrong-scoped key" "recall_refused:http403|rc=0 http=403" \
  STUB_RC=0 STUB_CODE=403 STUB_BODY='{"error":"forbidden"}' STUB_TIME=0.2

# A working call goes to the LATENCY log, not the ledger: one row per prompt
# there would halve the Stop-outcome history the ledger keeps.
before="$(wc -l <"$(log)" | tr -d ' ')"
( export STUB_RC=0 STUB_CODE=200 STUB_BODY="$RECALL_OK" STUB_TIME=0.64; run_hook recall-decisions.sh ok-1 )
got="$(tail -n 1 "$(latency_log)" 2>/dev/null | awk -F'\t' '{print $4 "|" $5}')"
after="$(wc -l <"$(log)" | tr -d ' ')"
if [ "$got" = "recall_ok|rc=0 http=200 t=0.64" ] && [ "$before" = "$after" ]; then
  pass "a working recall ⇒ recall_ok with its latency, in rail-latency.log only"
else
  fail "a working recall must land in rail-latency.log and not the ledger" "latency='$got'" "ledger $before -> $after"
fi

# The three the issue names, distinguished from EACH OTHER — not just each
# matching its own pattern, which a too-loose `want` would also satisfy.
distinct="$(awk -F'\t' '{print $4}' "$(log)" | grep -E '^recall_(unreachable:timeout|refused:http500|refused:http403)$' | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" = 3 ]; then
  pass "timeout, 500 and 403 are three different reasons"
else
  fail "timeout, 500 and 403 must be three different reasons" "distinct=$distinct" "$(cat "$(log)")"
fi

# ── 2. the close still counts only the silent misses ──────────────────────
echo
echo "── the reason prefix the close counts is unchanged ──"
n_unreach="$(grep -cE 'recall_unreachable' "$(log)" || true)"
if [ "$n_unreach" = 7 ]; then
  pass "7 silent misses match session-residue's 'recall_unreachable' grep; refused and ok do not"
else
  fail "expected 7 records matching recall_unreachable" "got $n_unreach" "$(cat "$(log)")"
fi

# ── 3. the grounding rail is classified the same way ───────────────────────
echo
echo "── ground: same classes, its own prefix ──"
( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.003; run_hook supply-ground.sh g-1 )
got="$(last_record)"
case "$got" in
  "ground_unreachable:timeout|rc=28 http=000 t=2.003") pass "ground timeout ⇒ $got" ;;
  *) fail "ground timeout" "got '$got'" ;;
esac
( export STUB_RC=0 STUB_CODE=403 STUB_BODY='{"error":"forbidden"}' STUB_TIME=0.2; run_hook supply-ground.sh g-1 )
got="$(last_record)"
case "$got" in
  "ground_refused:http403|"*) pass "ground 403 ⇒ ${got%%|*}" ;;
  *) fail "ground 403 must be ground_refused:http403" "got '$got'" ;;
esac

# ── 4. the streak is said once per outage ──────────────────────────────────
echo
echo "── a streak of misses is said once, at the threshold ──"
export MOLLOW_RAIL_STREAK_WARN=3
said=""
for i in 1 2 3 4 5; do
  ( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0; run_hook recall-decisions.sh streak-a; printf '%s' "$CTX" >"$TMP/ctx.$i" )
  [ -s "$TMP/ctx.$i" ] && said="$said $i"
done
if [ "$said" = " 3" ]; then
  pass "silent on misses 1-2, one line at 3, silent on 4-5"
else
  fail "expected exactly one line, on miss 3" "said on:${said:- none}"
fi
if grep -q "last 3 decision recall calls" "$TMP/ctx.3" && grep -q "timeout" "$TMP/ctx.3"; then
  pass "the line names the count and the kind of miss"
else
  fail "the line must name the count and the kind" "$(cat "$TMP/ctx.3")"
fi

( export STUB_RC=0 STUB_CODE=200 STUB_BODY="$RECALL_OK" STUB_TIME=0.5; run_hook recall-decisions.sh streak-a )
# An unreadable 200 is NOT a recovery: it must not clear the streak.
( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0; run_hook recall-decisions.sh streak-h )
( export STUB_RC=0 STUB_CODE=200 STUB_BODY='<html>oops</html>' STUB_TIME=0.2; run_hook recall-decisions.sh streak-h )
if [ "$(cat "$TMP/home/.mollow/rail-streak/streak-h.recall" 2>/dev/null)" = 2 ]; then
  pass "an HTML 200 mid-outage advances the streak rather than clearing it"
else
  fail "an HTML 200 must not clear the streak" "$(cat "$TMP/home/.mollow/rail-streak/streak-h.recall" 2>/dev/null)"
fi
if [ ! -e "$TMP/home/.mollow/rail-streak/streak-a.recall" ]; then
  pass "a working recall clears the streak file"
else
  fail "a working recall must clear the streak" "$(cat "$TMP/home/.mollow/rail-streak/streak-a.recall")"
fi
said=""
for i in 1 2 3; do
  ( export STUB_RC=7 STUB_CODE=000 STUB_BODY= STUB_TIME=0.001; run_hook recall-decisions.sh streak-a; printf '%s' "$CTX" >"$TMP/ctx2.$i" )
  [ -s "$TMP/ctx2.$i" ] && said="$said $i"
done
if [ "$said" = " 3" ] && grep -q "refused" "$TMP/ctx2.3"; then
  pass "after recovery, the next outage is said again — with its own kind"
else
  fail "the next outage must be said again at 3" "said on:${said:- none}" "$(cat "$TMP/ctx2.3" 2>/dev/null)"
fi

# A different session's misses do not advance this one's streak.
( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0; run_hook recall-decisions.sh streak-b; printf '%s' "$CTX" >"$TMP/ctx-b" )
if [ ! -s "$TMP/ctx-b" ] && [ "$(cat "$TMP/home/.mollow/rail-streak/streak-b.recall" 2>/dev/null)" = 1 ]; then
  pass "streaks are per session"
else
  fail "streaks must be per session" "ctx='$(cat "$TMP/ctx-b")'"
fi

# A session id that could shape a path is never counted.
(
  # shellcheck source=/dev/null
  HOME="$TMP/home" . "$DIR/_common.sh"
  HOME="$TMP/home" mm_rail_streak recall '../../evil' fail >"$TMP/evil.out"
)
if [ "$(cat "$TMP/evil.out")" = 0 ] && [ ! -e "$TMP/home/.mollow/evil.recall" ] && [ ! -e "$TMP/evil.recall" ]; then
  pass "a path-shaped session id is refused, not written"
else
  fail "a path-shaped session id must not be written" "$(cat "$TMP/evil.out")"
fi
# A definite refusal mid-outage was SAID already; it neither breaks nor
# advances the silent-miss streak.
( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0; run_hook recall-decisions.sh streak-c; run_hook recall-decisions.sh streak-c )
( export STUB_RC=0 STUB_CODE=500 STUB_BODY='{"e":1}' STUB_TIME=0.3; run_hook recall-decisions.sh streak-c )
if [ "$(cat "$TMP/home/.mollow/rail-streak/streak-c.recall" 2>/dev/null)" = 2 ]; then
  pass "a refusal mid-streak leaves the count alone"
else
  fail "a refusal mid-streak must leave the count at 2" "$(cat "$TMP/home/.mollow/rail-streak/streak-c.recall" 2>/dev/null)"
fi

# The grounding rail streaks on its own counter and names itself.
said=""
for i in 1 2 3; do
  ( export STUB_RC=6 STUB_CODE=000 STUB_BODY= STUB_TIME=0.01; run_hook supply-ground.sh streak-g; printf '%s' "$CTX" >"$TMP/ctxg.$i" )
  [ -s "$TMP/ctxg.$i" ] && said="$said $i"
done
if [ "$said" = " 3" ] && grep -q "last 3 grounding calls" "$TMP/ctxg.3" && grep -q "dns" "$TMP/ctxg.3"; then
  pass "the grounding rail is said once at the threshold, by name"
else
  fail "grounding streak" "said on:${said:- none}" "$(cat "$TMP/ctxg.3" 2>/dev/null)"
fi

# A count left by an earlier outage (over an hour old) starts over.
mkdir -p "$TMP/home/.mollow/rail-streak"
printf '2\n' >"$TMP/home/.mollow/rail-streak/streak-old.recall"
touch -t "$(date -v-2H +%Y%m%d%H%M 2>/dev/null || date -d '-2 hours' +%Y%m%d%H%M)" "$TMP/home/.mollow/rail-streak/streak-old.recall"
( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0; run_hook recall-decisions.sh streak-old; printf '%s' "$CTX" >"$TMP/ctx-old" )
if [ ! -s "$TMP/ctx-old" ] && [ "$(cat "$TMP/home/.mollow/rail-streak/streak-old.recall")" = 1 ]; then
  pass "a stale count from an earlier outage starts over"
else
  fail "a stale count must start over at 1" "$(cat "$TMP/home/.mollow/rail-streak/streak-old.recall")"
fi
unset MOLLOW_RAIL_STREAK_WARN

# The DEFAULT threshold is 5, and a zero-padded override still fires.
for warn in "" "05"; do
  said=""
  for i in 1 2 3 4 5 6; do
    ( export STUB_RC=28 STUB_CODE=000 STUB_BODY= STUB_TIME=2.0
      [ -n "$warn" ] && export MOLLOW_RAIL_STREAK_WARN="$warn"
      run_hook recall-decisions.sh "streak-d$warn"; printf '%s' "$CTX" >"$TMP/ctxd.$i" )
    [ -s "$TMP/ctxd.$i" ] && said="$said $i"
  done
  if [ "$said" = " 5" ]; then
    pass "threshold '${warn:-default}' fires once, on miss 5"
  else
    fail "threshold '${warn:-default}' must fire once on miss 5" "said on:${said:- none}"
  fi
done

echo
sub_fail="$(wc -l <"$TMP/failures" 2>/dev/null | tr -d ' ')"
sub_fail="${sub_fail:-0}"
echo "passed=$PASS failed=$sub_fail"
[ "$sub_fail" -eq 0 ]
