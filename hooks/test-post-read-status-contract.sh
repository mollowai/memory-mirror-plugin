#!/usr/bin/env bash
# `mm_post_read_status` and `mm_seam_post_read` must return the SAME SHAPE.
#
# MOL-8256 added the first as a bearer-auth twin of the second, because the only
# difference between them is the auth header and folding them into one core
# would have been a refactor of a function `supply-ground.sh` depends on, inside
# a behaviour change. That choice leaves duplicated edge-case handling — and
# duplicated edge cases are exactly where two functions drift apart while both
# look right in isolation.
#
# So the contract is pinned here rather than trusted:
#
#   * the http code comes FIRST, before the first newline, even though
#     `curl -w '\n%{http_code}'` appends it LAST. Get this backwards and
#     `mm_seam_split_status` returns the body's opening line as the status,
#     which for a JSON body is `{` — not a number, so every status comparison
#     silently falls through to its default branch.
#   * a curl that could not run at all yields `000` and an empty body, not an
#     empty string. `000` is the transient case both callers must keep out of
#     the model's context.
#   * a response with NO body yields the code and an empty body, never the code
#     echoed back as the body.
#
# The assertions run both functions against the same stubbed curl and compare
# them to each other, so a change to one that is not made to the other fails
# here regardless of which one is "right".
#
# Run: bash plugins/memory-mirror/hooks/test-post-read-status-contract.sh

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-read-contract-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# A curl that honours the two knobs the cases below need: what body to print,
# and whether to produce anything at all.
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
[ -n "${STUB_SILENT:-}" ] && exit 7
printf '%s' "${STUB_BODY:-}"
for a in "$@"; do
  case "$a" in
    *http_code*) printf '\n%s' "${STUB_CODE:-200}" ;;
  esac
done
# STUB_TRUNCATED: the server answered with a real code and curl then failed
# mid-transfer (--max-time expiring part-way through the body). Output is
# non-empty and the code is a 200, but the transfer did not complete.
[ -n "${STUB_TRUNCATED:-}" ] && exit 28
exit 0
EOF
chmod +x "$TMP/bin/curl"

# `probe <fn>` — run one reader under the stub and print `<status>|<body>`.
# A subshell per call so a sourced `_common.sh` cannot leak state between them.
probe() {
  (
    PATH="$TMP/bin:/usr/bin:/bin"
    export PATH
    MOLLOW_MEMORY_API_KEY="mol_test"
    MOLLOW_MEMORY_URL="https://example.invalid/mcp/v2"
    MOLLOW_MEMORY_CREDS_FROM_FILES=0
    export MOLLOW_MEMORY_API_KEY MOLLOW_MEMORY_URL MOLLOW_MEMORY_CREDS_FROM_FILES
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    raw="$("$1" "/some/path" '{"a":1}' 2)"
    printf '%s|%s' "$(mm_seam_split_status "$raw")" "$(mm_seam_split_body "$raw")"
  )
}

check_both() {
  local label="$1" expected="$2" a b
  a="$(STUB_BODY="${STUB_BODY:-}" probe mm_post_read_status)"
  b="$(STUB_BODY="${STUB_BODY:-}" probe mm_seam_post_read)"

  if [ "$a" != "$expected" ]; then
    fail "$label — mm_post_read_status" "expected '$expected'" "got      '$a'"
  elif [ "$b" != "$expected" ]; then
    fail "$label — mm_seam_post_read" "expected '$expected'" "got      '$b'"
  elif [ "$a" != "$b" ]; then
    fail "$label — the twins disagree" "status: '$a'" "seam:   '$b'"
  else
    pass "$label (both)"
  fi
}

echo "── the code comes first, the body second ──"
export STUB_BODY='{"ok":true}' STUB_CODE=200
check_both "200 with a body" '200|{"ok":true}'

export STUB_CODE=403
check_both "a definite error keeps its code" '403|{"ok":true}'

echo
echo "── a curl that never ran is 000 with an empty body, not an empty string ──"
export STUB_SILENT=1 STUB_CODE=200 STUB_BODY='{"ok":true}'
check_both "curl could not run" '000|'
unset STUB_SILENT

echo
echo "── a response with no body does not echo the code back as the body ──"
export STUB_BODY='' STUB_CODE=204
check_both "empty body" '204|'

echo
echo "── a TRUNCATED 200 is not a usable answer, and must not read as one ──"
# The case Greptile found on #8372. Before the fix, curl's exit code was
# discarded: a 200 with half its JSON came back as a successful 200, the caller
# skipped its transient branch, and every later jq read failed against a partial
# document — silently. That is MOL-8256's own defect one layer in.
#
# Asserted on BOTH readers. The seam twin had the identical hole, and there it
# is worse: supply-ground.sh reads `.grounding_id` off the partial body, finds
# nothing, and exits silently — so a cut-off answer becomes "the register had
# nothing to say".
export STUB_BODY='{"ok":tru' STUB_CODE=200 STUB_TRUNCATED=1
check_both "a truncated 200 reports 000, not a usable 200" '000|'
unset STUB_TRUNCATED

echo
echo "── and the predicate reads those statuses the way the callers assume ──"
definite() {
  (
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    if mm_definite_http_failure "$1"; then printf 'yes'; else printf 'no'; fi
  )
}
for case_ in "403:yes" "500:yes" "000:no" ":no" "200:no" "204:no"; do
  code="${case_%%:*}"
  want="${case_##*:}"
  got="$(definite "$code")"
  if [ "$got" = "$want" ]; then
    pass "definite_http_failure('${code:-<empty>}') = $want"
  else
    fail "definite_http_failure('${code:-<empty>}')" "expected $want, got $got"
  fi
done

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
