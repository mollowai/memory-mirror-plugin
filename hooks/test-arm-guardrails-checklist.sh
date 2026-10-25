#!/usr/bin/env bash
# =============================================================================
# test-arm-guardrails-checklist.sh — the SessionStart checklist's own rendering
#
# Why this exists: until now NOTHING asserted this output. `grep -rn "Active
# ways-of-working"` across the repository matched the hook and nothing else, so
# the entire delivery path for doctrine — the only thing a session actually
# sees — was untested, and two defects lived in four lines of jq (MOL-7736):
#
#   * it rendered the first 8 of N and said nothing, so with 36 rules in a
#     Space 28 never reached a session and no output distinguished "you have 8
#     rules" from "you have 36 and are seeing 8"
#   * it claimed "for this workspace" while the project it sends is exactly
#     what makes the server resolve a SPACE owner instead
#
# Both are rendering, not logic, which is why a source-level read missed them
# and why this asserts the OUTPUT through the real hook.
#
# Run: bash plugins/memory-mirror/hooks/test-arm-guardrails-checklist.sh
# =============================================================================
set -uo pipefail

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; NC=$'\033[0m'
PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ${GREEN}✓${NC} $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  ${RED}FAIL${NC}: $1"; shift; for l in "$@"; do echo "      $l"; done; }

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$HOOK_DIR/arm-guardrails.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/mm-checklist-XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ── harness: a curl shim that serves a canned guardrails response ────────────
# Mirrors test-supply-hooks.sh's shim, including the -w '%{http_code}' handling
# (MOL-5978): without it the status the caller parses is the last line of the
# BODY, so every response reads as an error while the source looks correct.
SHIM="$WORK/bin"; mkdir -p "$SHIM"
cat >"$SHIM/curl" <<'SHIM_EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${CURL_LOG:-/dev/null}"
if [ -n "${CURL_BODY_FILE:-}" ] && [ -f "${CURL_BODY_FILE}" ]; then
  cat "${CURL_BODY_FILE}"
fi
for a in "$@"; do
  if [ "$a" = "-w" ]; then printf '\n%s' "${CURL_STATUS:-200}"; break; fi
done
exit 0
SHIM_EOF
chmod +x "$SHIM/curl"

# Build a response with N warn rules, optionally one `block` rule first.
rules_json() {
  local n="$1" with_block="${2:-no}"
  python3 - "$n" "$with_block" <<'PY'
import json, sys
n = int(sys.argv[1]); with_block = sys.argv[2] == "block"
rules = [{"severity": "warn", "statement": f"warn rule {i}"} for i in range(1, n + 1)]
if with_block:
    rules.append({"severity": "block", "statement": "THE BLOCK RULE"})
print(json.dumps({"ok": True, "ways_of_working": rules}))
PY
}

# Run the hook in a sandbox and capture whatever it emits as SessionStart text.
run_hook() {
  local body="$1" out="$2"
  (
    export PATH="$SHIM:$PATH"
    export HOME="$WORK/home"; mkdir -p "$HOME"
    export TMPDIR="$WORK/tmp"; mkdir -p "$TMPDIR"
    export CURL_BODY_FILE="$body"
    export CURL_STATUS=200
    export MOLLOW_MEMORY_API_KEY="mol_testkey"
    export CLAUDE_PROJECT_DIR="$WORK/repo"; mkdir -p "$CLAUDE_PROJECT_DIR"
    cd "$CLAUDE_PROJECT_DIR" || exit 1
    printf '{"session_id":"test-session","cwd":"%s"}\n' "$CLAUDE_PROJECT_DIR" \
      | bash "$HOOK" 2>/dev/null
  ) >"$out" 2>&1
}

echo "checklist rendering:"

# ── 1. no truncation: 3 rules, so no "showing" notice ───────────────────────
rules_json 3 >"$WORK/three.json"
run_hook "$WORK/three.json" "$WORK/out3.txt"

grep -q "Active ways-of-working" "$WORK/out3.txt" \
  && ok "renders a checklist when rules exist" \
  || bad "no checklist rendered for 3 rules" "$(head -5 "$WORK/out3.txt")"

grep -q "showing" "$WORK/out3.txt" \
  && bad "claimed truncation with only 3 rules (cap is 8)" \
  || ok "no truncation notice when nothing was truncated"

# ── 2. TRUNCATION MUST BE REPORTED: 36 rules, cap 8 ─────────────────────────
# The defect this file was written for. 36 in, 8 out, and the 28 dropped were
# invisible — a reader could not tell a short list from a truncated one.
rules_json 36 >"$WORK/many.json"
run_hook "$WORK/many.json" "$WORK/out36.txt"

ctx_has() { jq -r '.hookSpecificOutput.additionalContext // ""' <"$1" 2>/dev/null | grep -q "$2"; }
ctx_has "$WORK/out36.txt" "showing 8 of 36" \
  && ok "truncation is reported as 'showing 8 of 36'" \
  || bad "36 rules truncated to 8 with NO notice — the defect is back" \
         "$(grep -m1 'Active ways-of-working' "$WORK/out36.txt" || echo '(no checklist line)')"

# Decode the artifact with a real parser rather than grepping the raw line.
# The hook emits ONE JSON line whose additionalContext carries "\n" escapes, so
# bullets are not line-anchored and `grep -c '^ *•'` counts zero on correct
# output — which reads as "the cap broke" when nothing broke.
ctx() { jq -r '.hookSpecificOutput.additionalContext // ""' <"$1" 2>/dev/null; }

bullets="$(ctx "$WORK/out36.txt" | grep -c '• \[' 2>/dev/null || echo 0)"
[ "$bullets" = "8" ] \
  && ok "exactly 8 bullets rendered (the cap still holds)" \
  || bad "expected 8 bullets, got $bullets"

# ── 3. THE OWNER MUST NOT BE MISNAMED ───────────────────────────────────────
# It said "for this workspace". The rules may be owned by a Space — which is
# what sending `project` causes — and the response carries no owner field, so
# claiming either container is a guess. Claim neither.
grep -q "for this workspace" "$WORK/out36.txt" \
  && bad "claims 'for this workspace' — the owner may be a Space and the response does not say" \
  || ok "does not name a container it cannot know"

# ── 4. empty list emits nothing at all ──────────────────────────────────────
# An empty checklist must not render a header with no bullets under it.
echo '{"ok":true,"ways_of_working":[]}' >"$WORK/none.json"
run_hook "$WORK/none.json" "$WORK/out0.txt"

grep -q "Active ways-of-working" "$WORK/out0.txt" \
  && bad "rendered a checklist header for zero rules" \
  || ok "zero rules renders no checklist"

# ── 5. a block rule still sorts first ───────────────────────────────────────
# The cap makes ordering load-bearing: with more rules than the cap, a `block`
# that sorted last would be dropped entirely.
rules_json 9 block >"$WORK/block.json"
run_hook "$WORK/block.json" "$WORK/outb.txt"

first="$(ctx "$WORK/outb.txt" | grep -m1 '• \[' 2>/dev/null)"
case "$first" in
  *"[block]"*) ok "block sorts first, so the cap cannot drop it" ;;
  *)           bad "first bullet is not the block rule" "got: ${first:-<none>}" ;;
esac

echo
printf 'passed %d, failed %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
