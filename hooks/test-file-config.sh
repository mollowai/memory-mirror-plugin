#!/usr/bin/env bash
set -euo pipefail
# Tests for the file-backed halves of mm_supply_enabled and mm_ready (MOL-6221).
#
# ## The failure these exist for
#
# Both supply hooks open with two env-var guards:
#
#   supply-ground.sh:53   mm_supply_enabled || exit 0    # MOLLOW_SUPPLY_MODE
#   supply-ground.sh:54   mm_ready || exit 0             # MOLLOW_MEMORY_API_KEY
#
# A worktree pane loses both. `host-session-start.sh` writes them into
# `.session-config` precisely because direnv reverts the monorepo's `.envrc` the
# moment an interactive login zsh reaches a prompt in a worktree that has none —
# and when that write does not happen, `mm_ready` returns 1 with NO message and
# the hooks are silently inert. Measured on the `shop-watch` session: the live
# process environ carried MOLLOW_LOCAL_TMUX_SESSION and MOLLOW_WEBAPP_URL and
# neither guard's input, while `.mcp.json` held the credential all along.
#
# An env-var opt-in also cannot be switched on for a session that is ALREADY
# RUNNING — the hooks are children of a process whose environ was fixed at
# launch. So the file path is not a convenience; it is the only reachable switch.
#
# ## What must hold
#
#   * absent file ⇒ off, and unrecognised content ⇒ off. The opt-in is never
#     inherited by accident (the ~/.mollow/gate-mode convention).
#   * an explicitly-set env var beats the file in BOTH directions. The existing
#     suite and the launchers set it; a file that overrode them would break both,
#     and `off` in the environment must be able to hold a machine-wide `on` down.
#   * `.session-config` beats `.mcp.json` — one is written 0600 for this purpose,
#     the other is MCP transport config we are reading opportunistically.
#   * a URL arriving from a FILE is validated exactly like one from the
#     environment. This is the security-relevant case: resolution must happen
#     BEFORE the /mcp/v2 and HTTPS guards, never instead of them.
#   * the kill switch works, because `test-repo-identity.sh:26` guarantees "no
#     key in env ⇒ nothing reaches the network" by unsetting the variable. File
#     resolution silently voids that guarantee without it.
#   * no path prints the key. A hook that leaks a bearer token into a transcript
#     is worse than a hook that does nothing.
#
# Run: bash plugins/memory-mirror/hooks/test-file-config.sh

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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/mm-fileconf-XXXXXX")"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# A sentinel that names itself TESTONLY, and is long enough that a
# truncated leak would still match it.
FAKE_KEY="mol_TESTONLY_0000000000000000000000000000"

# Run one probe in a SUBSHELL with a controlled environment. Every case gets a
# fresh `HOME` and a fresh project dir so no case can see another's files — and
# so none of them can see the real ~/.mollow or the real .session-config, which
# would make a green run meaningless on this machine specifically.
#
# Emits: "<rc>|<stdout+stderr>"
probe() {
  local fn="$1"; shift
  # A UNIQUE HOME and project dir per case. Sharing one leaks state between
  # cases — an earlier case's .mcp.json satisfied a later case that was asserting
  # a MISS, turning four real failures into passes.
  #
  # The root comes from `mktemp -d`, NOT from a counter. Every call site here is
  # `r=$(probe …)`, and command substitution is itself a subshell, so a
  # `COUNTER=$((COUNTER+1))` inside probe cannot escape back to the parent — it
  # stayed 0 on every call and every case shared one directory, while the suite
  # went on reporting 31 passes. A counter cannot be made to work here; a fresh
  # directory needs nothing to persist.
  local case_root
  case_root="$(mktemp -d "$TMP/case-XXXXXX")"
  (
    export HOME="$case_root/home"
    mkdir -p "$HOME/.mollow"
    # Neutral defaults; each case overrides what it is testing.
    unset MOLLOW_SUPPLY_MODE MOLLOW_MEMORY_API_KEY MOLLOW_MEMORY_URL
    unset MOLLOW_MEMORY_CREDS_FROM_FILES
    export CLAUDE_PROJECT_DIR="$case_root/proj"
    mkdir -p "$CLAUDE_PROJECT_DIR"
    # Case-specific setup runs here, inside the subshell.
    eval "$1"
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    out="$("$fn" 2>&1)"; rc=$?
    printf '%s|%s' "$rc" "$out"
  )
}

rc_of() { printf '%s' "${1%%|*}"; }
out_of() { printf '%s' "${1#*|}"; }

expect_rc() {
  local label="$1" want="$2" got_pair="$3"
  local got; got="$(rc_of "$got_pair")"
  if [ "$got" = "$want" ]; then
    pass "$label"
  else
    fail "$label" "expected rc=$want" "actual   rc=$got" "output: [$(out_of "$got_pair")]"
  fi
}

# ─── mm_supply_enabled: the file fallback ────────────────────────────────────

r=$(probe mm_supply_enabled ':')
expect_rc "supply: no env, no file ⇒ OFF" 1 "$r"

r=$(probe mm_supply_enabled 'printf "on\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: no env, file=on ⇒ ON" 0 "$r"

for v in 1 true yes on ON True YES; do
  r=$(probe mm_supply_enabled "printf '%s\n' '$v' > \"\$HOME/.mollow/supply-mode\"")
  expect_rc "supply: file='$v' ⇒ ON" 0 "$r"
done

for v in 0 off false no maybe garbage; do
  r=$(probe mm_supply_enabled "printf '%s\n' '$v' > \"\$HOME/.mollow/supply-mode\"")
  expect_rc "supply: file='$v' ⇒ OFF" 1 "$r"
done

# Whitespace and a missing trailing newline are both normal ways a human writes
# this file by hand. Neither may read as garbage.
r=$(probe mm_supply_enabled 'printf "  on  \n\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: file with surrounding whitespace ⇒ ON" 0 "$r"

r=$(probe mm_supply_enabled 'printf "on" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: file with no trailing newline ⇒ ON" 0 "$r"

r=$(probe mm_supply_enabled 'printf "" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: empty file ⇒ OFF" 1 "$r"

# A multi-line file reads its FIRST line only. Anything else lets a stray second
# line decide, which is not what a one-word mode file means.
r=$(probe mm_supply_enabled 'printf "on\nrubbish\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: multi-line file reads line 1 ⇒ ON" 0 "$r"

# Env wins, in BOTH directions.
r=$(probe mm_supply_enabled 'export MOLLOW_SUPPLY_MODE=on; printf "off\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: env=on beats file=off ⇒ ON" 0 "$r"

r=$(probe mm_supply_enabled 'export MOLLOW_SUPPLY_MODE=off; printf "on\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: env=off beats file=on ⇒ OFF" 1 "$r"

# An EMPTY env var is not a decision — it is what an unset-but-exported variable
# looks like, and a launcher that exports it blank must not disable a declared
# machine mode.
r=$(probe mm_supply_enabled 'export MOLLOW_SUPPLY_MODE=""; printf "on\n" > "$HOME/.mollow/supply-mode"')
expect_rc "supply: empty env falls through to file=on ⇒ ON" 0 "$r"

# A directory where the file should be must not crash the hook.
r=$(probe mm_supply_enabled 'mkdir -p "$HOME/.mollow/supply-mode"')
expect_rc "supply: mode path is a DIRECTORY ⇒ OFF, no crash" 1 "$r"

# ─── mm_ready: credential resolution from files ──────────────────────────────

r=$(probe mm_ready ':')
expect_rc "ready: no key anywhere ⇒ 1" 1 "$r"

r=$(probe mm_ready "printf 'export MOLLOW_MEMORY_API_KEY=%s\n' '$FAKE_KEY' > \"\$CLAUDE_PROJECT_DIR/.session-config\"")
expect_rc "ready: key from .session-config ⇒ 0" 0 "$r"

r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"type\":\"http\",\"url\":\"https://mollow.ai/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
expect_rc "ready: key from .mcp.json Authorization ⇒ 0" 0 "$r"

# .session-config wins. Both present, and the one we must NOT pick carries a
# URL that would fail validation — so if precedence is wrong, rc flips.
r=$(probe mm_ready "printf 'export MOLLOW_MEMORY_API_KEY=%s\nexport MOLLOW_MEMORY_URL=%s\n' '$FAKE_KEY' 'https://staging.mollow.ai/mcp/v2' > \"\$CLAUDE_PROJECT_DIR/.session-config\"
cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"type\":\"http\",\"url\":\"http://evil.example.com/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
expect_rc "ready: .session-config URL beats .mcp.json URL ⇒ 0" 0 "$r"

# The security case: a bad URL arriving FROM A FILE is refused exactly as one
# from the environment would be. Resolution happens before the guards, not
# instead of them.
r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"type\":\"http\",\"url\":\"http://evil.example.com/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
expect_rc "ready: non-HTTPS URL from .mcp.json ⇒ REFUSED" 1 "$r"

r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"type\":\"http\",\"url\":\"https://mollow.ai/v1\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
expect_rc "ready: URL from .mcp.json missing /mcp/v2 ⇒ REFUSED" 1 "$r"

# A loopback http URL is still allowed from a file, same as from the env.
r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"type\":\"http\",\"url\":\"http://localhost:4000/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
expect_rc "ready: loopback http from .mcp.json ⇒ 0" 0 "$r"

# A .mcp.json with no mollow-memory server, and a malformed one, must both be
# misses rather than crashes.
r=$(probe mm_ready "printf '%s' '{\"mcpServers\":{\"github\":{}}}' > \"\$CLAUDE_PROJECT_DIR/.mcp.json\"")
expect_rc "ready: .mcp.json without mollow-memory ⇒ 1" 1 "$r"

r=$(probe mm_ready "printf '%s' 'not json at all {{{' > \"\$CLAUDE_PROJECT_DIR/.mcp.json\"")
expect_rc "ready: malformed .mcp.json ⇒ 1, no crash" 1 "$r"

# A bare key with no "Bearer " prefix is still a key.
r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"url\":\"https://mollow.ai/mcp/v2\",\"headers\":{\"Authorization\":\"$FAKE_KEY\"}}}}
J")
expect_rc "ready: Authorization without a Bearer prefix ⇒ 0" 0 "$r"

# The kill switch: test-repo-identity.sh's "unset the key ⇒ no network"
# guarantee must remain purchasable.
r=$(probe mm_ready "export MOLLOW_MEMORY_CREDS_FROM_FILES=0
printf 'export MOLLOW_MEMORY_API_KEY=%s\n' '$FAKE_KEY' > \"\$CLAUDE_PROJECT_DIR/.session-config\"")
expect_rc "ready: CREDS_FROM_FILES=0 ignores .session-config ⇒ 1" 1 "$r"

# ─── MOLLOW_SUPPLY_WORKSPACE_ID resolution ───────────────────────────────────
# Without this the hook RUNS, reaches the server, and injects `400
# workspace_not_named` instead of facts — a worse outcome than staying inert,
# because it looks like it is working.

ws_probe() {
  # Same isolation as probe(), but reports the resolved id rather than an rc.
  local case_root
  case_root="$(mktemp -d "$TMP/ws-XXXXXX")"
  (
    export HOME="$case_root/home"
    mkdir -p "$HOME/.mollow"
    unset MOLLOW_SUPPLY_WORKSPACE_ID MOLLOW_MEMORY_API_KEY MOLLOW_MEMORY_URL
    unset MOLLOW_MEMORY_CREDS_FROM_FILES
    export CLAUDE_PROJECT_DIR="$case_root/proj"
    mkdir -p "$CLAUDE_PROJECT_DIR"
    eval "$1"
    # shellcheck source=/dev/null
    . "$DIR/_common.sh"
    mm_resolve_memory_creds
    printf '%s' "${MOLLOW_SUPPLY_WORKSPACE_ID:-}"
  )
}

eq_ws() {
  local label="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$label"; else fail "$label" "expected: [$want]" "actual:   [$got]"; fi
}

eq_ws "workspace: nothing anywhere ⇒ empty" "" "$(ws_probe ':')"
eq_ws "workspace: from ~/.mollow/supply-workspace-id" "ws-from-file" \
  "$(ws_probe 'printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"')"
eq_ws "workspace: from .session-config when no file" "ws-from-cfg" \
  "$(ws_probe 'printf "export MOLLOW_SUPPLY_WORKSPACE_ID=ws-from-cfg\n" > "$CLAUDE_PROJECT_DIR/.session-config"')"
eq_ws "workspace: the file beats .session-config" "ws-from-file" \
  "$(ws_probe 'printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"
printf "export MOLLOW_SUPPLY_WORKSPACE_ID=ws-from-cfg\n" > "$CLAUDE_PROJECT_DIR/.session-config"')"
eq_ws "workspace: env beats both" "ws-from-env" \
  "$(ws_probe 'export MOLLOW_SUPPLY_WORKSPACE_ID=ws-from-env
printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"')"
eq_ws "workspace: whitespace in the file is trimmed" "ws-trimmed" \
  "$(ws_probe 'printf "  ws-trimmed \n" > "$HOME/.mollow/supply-workspace-id"')"
eq_ws "workspace: CREDS_FROM_FILES=0 resolves nothing" "" \
  "$(ws_probe 'export MOLLOW_MEMORY_CREDS_FROM_FILES=0
printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"')"

# The case a short-circuit on (key AND url) silently breaks (Greptile, #6406).
# With both credentials already in the environment there is nothing to resolve
# for them — but the workspace id may still live only in a file, and skipping it
# sends the request WITHOUT x-mollow-workspace-id. The server answers `400
# workspace_not_named`, so the hook runs, reaches the network, and injects a
# refusal instead of facts: the exact failure this file documents, reintroduced
# from the other side.
#
# Every other case here unsets key and url, so none of them reach that branch —
# a fixture that cannot express the failure passes whether or not it is present.
eq_ws "workspace: resolved even when key AND url are already in the env" "ws-from-file" \
  "$(ws_probe 'export MOLLOW_MEMORY_API_KEY=mol_TESTONLY_env
export MOLLOW_MEMORY_URL=https://mollow.ai/mcp/v2
printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"')"

eq_ws "workspace: resolved from .session-config when key AND url are in the env" "ws-from-cfg" \
  "$(ws_probe 'export MOLLOW_MEMORY_API_KEY=mol_TESTONLY_env
export MOLLOW_MEMORY_URL=https://mollow.ai/mcp/v2
printf "export MOLLOW_SUPPLY_WORKSPACE_ID=ws-from-cfg\n" > "$CLAUDE_PROJECT_DIR/.session-config"')"

# And nothing is re-read when all three are already set — the short-circuit is
# still allowed to exist, it just may not fire one input early.
eq_ws "workspace: all three in the env ⇒ env value kept" "ws-env" \
  "$(ws_probe 'export MOLLOW_MEMORY_API_KEY=mol_TESTONLY_env
export MOLLOW_MEMORY_URL=https://mollow.ai/mcp/v2
export MOLLOW_SUPPLY_WORKSPACE_ID=ws-env
printf "ws-from-file\n" > "$HOME/.mollow/supply-workspace-id"')"

# ─── the key must never be printed ───────────────────────────────────────────

leaked=0
for setup in \
  "printf 'export MOLLOW_MEMORY_API_KEY=%s\n' '$FAKE_KEY' > \"\$CLAUDE_PROJECT_DIR/.session-config\"" \
  "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"url\":\"http://evil.example.com/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J" \
  ; do
  r=$(probe mm_ready "$setup")
  if printf '%s' "$(out_of "$r")" | grep -qF "$FAKE_KEY"; then
    fail "no-leak: the key must not appear in stdout/stderr" "output: [$(out_of "$r")]"
    leaked=1
  fi
done
[ "$leaked" -eq 0 ] && pass "no-leak: the key never appears in stdout/stderr (incl. the refusal path)"

# The refusal message names the URL, which is intentional and safe. Assert that
# it still does — a fix that silenced it would make a misconfigured URL as hard
# to diagnose as the original bug.
r=$(probe mm_ready "cat > \"\$CLAUDE_PROJECT_DIR/.mcp.json\" <<'J'
{\"mcpServers\":{\"mollow-memory\":{\"url\":\"http://evil.example.com/mcp/v2\",\"headers\":{\"Authorization\":\"Bearer $FAKE_KEY\"}}}}
J")
if printf '%s' "$(out_of "$r")" | grep -q "evil.example.com"; then
  pass "refusal still names the offending URL"
else
  fail "refusal still names the offending URL" "output: [$(out_of "$r")]"
fi

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
