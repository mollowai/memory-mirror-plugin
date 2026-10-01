#!/usr/bin/env bash
# preflight-supply.sh — exercise the supply loop through the hook a live session
# actually loads, before a demo run puts it in front of an audience (MOL-6431).
#
# `plan-ipgp-hash-in-place-demo.md` §H asks for a pre-flight. Two things make a
# hand-run one untrustworthy, and this script exists to remove both.
#
# ── 1. The mode the pre-flight exercises is not the mode the demo shows ──────
#
# supply-ground.sh asks for `facts` unless MOLLOW_SUPPLY_POINTER_MODE is set, and
# every pre-flight before this one ran with it unset. The demo's headline beat is
# POINTER mode — the one where, in Mariam's framing, "the grep prints no content
# and response; the only readable text is the file name." A green facts-mode
# pre-flight says nothing about it.
#
# The two modes do not even fail the same way. `pointer` needs a SECOND
# server-side flag (`pointer_mode`) that gates the accepted mode VOCABULARY
# rather than the endpoint, so asking for it while the flag is off is
# `422 invalid_mode` — NOT the `404` that a disabled `supply_mode` returns. An
# operator who has only ever seen one of those two shapes cannot tell them apart
# when it matters, so this runs both legs and names which shape came back.
#
# ── 2. Which COPY of the hook runs depends on the launcher, and guessing is silent ─
#
# The spec records this as "the plugin resolves from the marketplace path, not
# from a worktree". Measured on 2026-09-30, that is no longer the rule here, and
# the truth is launcher-dependent:
#
#   * Launched through `scripts/claude-session` (which `scripts/dev/claude`,
#     `claude-tmux`, `host-session-start.sh`, yolo and the forge agents all go
#     through) the session carries `--plugin-dir <that clone>/plugins/memory-mirror`.
#     The WORKTREE copy is live, and editing it does take effect next session.
#     All six claude processes on this machine were in this state.
#   * Launched as a bare `claude`, the `enabledPlugins` + version-pinned
#     `~/.claude/plugins/cache/` path applies instead. On this machine that cache
#     is a June copy that contains NO supply-ground.sh at all — so a bare session
#     runs no supply hook whatsoever, which reads as "supply mode is broken"
#     rather than "this launcher does not load the plugin".
#
# Both readings produce the same symptom — you edit, re-run, and see the old
# behaviour — so this script never assumes. It resolves the hook from the
# RUNNING session's own argv, prints the path it chose and why, and says so out
# loud when its own sibling copy differs from the one that will actually run.
#
# ── Isolation ────────────────────────────────────────────────────────────────
# Every leg runs under a throwaway HOME and TMPDIR. supply-ground.sh records what
# it injected in `$HOME/.mollow/supply-seen.json` and drops a receipt under
# TMPDIR; without isolation a pre-flight would suppress those same facts in the
# operator's real sessions and leave receipts the Stop hook would post back.
# Credentials are read from the real HOME and passed in explicitly.
#
# ── Exit status ──────────────────────────────────────────────────────────────
#   0  every requested leg ran and matched its expectation
#   1  a leg could not be run at all (no credential, hook unresolvable)
#   2  a leg ran and did NOT match `--expect-*`
#
# A pre-flight that only ever runs in the working configuration cannot detect the
# configuration being wrong, so `--expect-pointer served` is how a demo-day run
# goes red on a flag that is off, rather than printing a refusal nobody reads.
#
# ── Strict mode ──────────────────────────────────────────────────────────────
# Full `set -euo pipefail`, the repo standard.
#
# `-e` is NOT a free choice here: running the hook is expected to fail sometimes
# and the failure IS the measurement — a non-zero exit is the only thing that
# separates "the hook could not run" from "the hook ran with nothing to inject",
# since both emit nothing on stdout. A bare `out=$(...)` followed by `rc=$?`
# would abort under `-e` before the status was ever read.
#
# The idiom that keeps both is `if out=$(...); then rc=0; else rc=$?; fi`: a
# command in an `if` CONDITION is exempt from errexit, so the status is captured
# and nothing aborts. Every deliberate failure in this script is taken that way,
# and `[ x ] && y=z` at statement level is written as `if`/`fi` for the same
# reason — a false test there returns 1 and would end the script.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

QUERY="What does the hash-in-place demo verify about a pointed-at document?"
LEGS="facts pointer"
EXPECT_FACTS=""
EXPECT_POINTER=""
HOOK_OVERRIDE="${MM_PREFLIGHT_HOOK:-}"
JSON_OUT=false

usage() {
  cat <<'USAGE'
usage: preflight-supply.sh [options]

  --query TEXT             prompt to ground (default: a demo-shaped question)
  --legs "facts pointer"   which legs to run (default: both)
  --expect-facts   CLASS   require the facts leg to classify as CLASS
  --expect-pointer CLASS   require the pointer leg to classify as CLASS
  --hook PATH              drive this copy of supply-ground.sh instead of
                           resolving the one the running session loads
  --json                   emit one JSON object per leg instead of a table
  -h, --help               this

CLASS is one of:
  served          a grounding came back and context was injected
  invalid_mode    422 invalid_mode — pointer_mode is off for this actor
  not_found       404 — supply_mode off, bad key, wrong header, or wrong path
  workspace       400/403 — the workspace id is missing or not this key's
  refused         some other stated refusal
  silent          the hook emitted nothing (miss, timeout, or nothing fresh)

Environment: MM_PREFLIGHT_HOOK (same as --hook); MM_PREFLIGHT_PS (a command
printing `pid ppid args` lines) and MM_PREFLIGHT_START_PID (where the ancestry
walk begins) are test seams.
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --query) QUERY="${2:?--query needs text}"; shift 2 ;;
    --legs) LEGS="${2:?--legs needs a list}"; shift 2 ;;
    --expect-facts) EXPECT_FACTS="${2:?--expect-facts needs a class}"; shift 2 ;;
    --expect-pointer) EXPECT_POINTER="${2:?--expect-pointer needs a class}"; shift 2 ;;
    --hook) HOOK_OVERRIDE="${2:?--hook needs a path}"; shift 2 ;;
    --json) JSON_OUT=true; shift ;;
    -h | --help) usage; exit 0 ;;
    *) echo "preflight-supply: unknown argument '$1'" >&2; usage >&2; exit 1 ;;
  esac
done

note() { printf '%s\n' "$*" >&2; }

# ── Resolve the hook the running session actually loads ──────────────────────
# `--plugin-dir` is what `scripts/claude-session` injects, so the argv of the
# claude process this script is running under is the ONLY thing that answers
# "which copy is live" without guessing. Walk up the process tree rather than
# scanning all of `ps`: several sessions run at once on this machine and each
# loads a different worktree, so picking the first match would report a
# neighbour's copy as confidently as its own.
#
# MM_PREFLIGHT_PS injects the process table for tests. It prints `pid ppid args`
# per line, the same three fields read here. MM_PREFLIGHT_START_PID injects where
# the walk begins: a test invokes this script inside `$(...)`, which forks a
# subshell, so the script's real PPID is that subshell and not the suite — a
# synthetic table keyed on the suite's own pid would never be entered, and the
# resolver would report "no --plugin-dir anywhere" for every constructed tree.
ps_table() {
  if [ -n "${MM_PREFLIGHT_PS:-}" ]; then
    eval "$MM_PREFLIGHT_PS"
  else
    ps -Ao pid,ppid,args 2>/dev/null
  fi
}

# Print the memory-mirror --plugin-dir of the nearest ancestor that declares one.
resolve_live_plugin_dir() {
  local table pid depth line lpid lppid rest
  table="$(ps_table)" || return 1
  pid="${MM_PREFLIGHT_START_PID:-${PPID:-0}}"
  depth=0
  while [ "$pid" != "0" ] && [ "$pid" != "1" ] && [ "$depth" -lt 24 ]; do
    line="$(printf '%s\n' "$table" | awk -v p="$pid" '$1 == p {print; exit}' || true)"
    [ -n "$line" ] || return 1
    read -r lpid lppid rest <<<"$line"
    : "$lpid"
    case "$rest" in
      *--plugin-dir*memory-mirror*)
        # The first --plugin-dir naming memory-mirror wins; a session may declare
        # several plugin dirs and only one of them is this plugin.
        #
        # Extracted by taking everything after `--plugin-dir ` up to the next
        # ` --`, NOT by splitting the argv on spaces. `ps` renders the argument
        # vector space-joined, so a worktree path containing a space is
        # indistinguishable from two arguments — and splitting yields a prefix of
        # the real path, which then fails the -f test below and drops through to
        # the marketplace cache. That is the worst outcome available: the
        # pre-flight would silently test a copy the session does not load, which
        # is the exact failure this function exists to prevent (Greptile, #6526).
        #
        # A path with a space is still not perfectly recoverable from `ps` alone
        # — nothing can be, the information is gone. What this guarantees is that
        # a WRONG extraction is caught rather than papered over: the caller
        # checks the result is a real directory and says so when it is not.
        # Split on the FLAG, then take each value up to the next ` --`, and keep
        # the one naming this plugin. Taking the first `--plugin-dir` instead
        # would return a sibling plugin's directory whenever the launcher orders
        # them differently — `claude-session` passes three.
        # `s/ --.*//` drops a following flag; the trailing-space strip is separate
        # and load-bearing, because splitting ON the flag consumes the space that
        # preceded the NEXT `--plugin-dir` and leaves it on this value. A path with
        # one trailing space fails the -f test and, before the caller learned to
        # refuse, sent the run to the marketplace cache.
        # `|| true` on the pipeline, NOT because a failure was demonstrated. It
        # was not: a 708KB argv with 20,000 matching segments still completed, with
        # and without the guard. But `head -1` closing the pipe early is the same
        # construct that DID abort this script at `head -c 220` once `-e` was on,
        # and "I could not build the failing case" is not "there is no failing
        # case" — it is what every earlier green run here also reported. The guard
        # costs nothing and the failure it covers is a pre-flight that exits
        # silently mid-resolution, which is the one outcome this file exists to
        # make impossible.
        printf '%s\n' "$rest" |
          sed 's/--plugin-dir /\n/g' |
          sed '1d; s/ --.*//; s/[[:space:]]*$//' |
          grep -F -- 'memory-mirror' |
          head -1 || true
        return 0
        ;;
    esac
    pid="$lppid"
    depth=$((depth + 1))
  done
  return 1
}

HOOK=""
HOOK_SOURCE=""
if [ -n "$HOOK_OVERRIDE" ]; then
  HOOK="$HOOK_OVERRIDE"
  HOOK_SOURCE="--hook / MM_PREFLIGHT_HOOK"
else
  live_dir="$(resolve_live_plugin_dir || true)"
  if [ -n "$live_dir" ]; then
    if [ -f "$live_dir/hooks/supply-ground.sh" ]; then
      HOOK="$live_dir/hooks/supply-ground.sh"
      HOOK_SOURCE="--plugin-dir of the running session"
    else
      # The session DOES declare a plugin dir and it does not hold the hook. Stop
      # here rather than dropping through to the marketplace cache: this session
      # loads from --plugin-dir, so the cache is not what runs for it, and
      # testing the cache would answer a question about a different session.
      # Most likely a path `ps` could not render faithfully (a space in it).
      note "preflight-supply: the running session declares --plugin-dir"
      note "    ${live_dir}"
      note "  but ${live_dir}/hooks/supply-ground.sh is not there."
      note "  \`ps\` renders argv space-joined, so a path containing a space comes back"
      note "  truncated and there is no way to recover the rest from it. Refusing rather"
      note "  than falling back to the marketplace cache, which is NOT what this session"
      note "  loads — testing it would answer a question about a different session."
      note "  Pass --hook <path> with the real path."
      exit 1
    fi
  fi
fi

# No --plugin-dir in the ancestry means this is (or descends from) a bare
# `claude`, where the version-pinned marketplace cache is what loads. Name that
# path explicitly rather than falling back to this script's own sibling: the
# sibling is the copy the operator is EDITING, and silently running it is the
# exact confusion this script exists to end.
if [ -z "$HOOK" ]; then
  cache_root="${HOME}/.claude/plugins/cache"
  cached_all="$(find "$cache_root" -path '*memory-mirror*/hooks/supply-ground.sh' 2>/dev/null | sort || true)"
  cached_n=0
  if [ -n "$cached_all" ]; then
    cached_n="$(printf '%s\n' "$cached_all" | grep -c . || true)"
  fi
  if [ "$cached_n" -gt 1 ]; then
    # Several cached versions. `head -1` here would pick one by path order, which
    # has nothing to do with which version `enabledPlugins` pins — so the
    # pre-flight could report success for a copy no session loads. The version is
    # not recoverable from the filesystem alone (the pin lives in settings.json
    # and Claude Code resolves it), so this names the candidates and refuses
    # (Greptile, #6526).
    note "preflight-supply: ${cached_n} cached copies of supply-ground.sh under ${cache_root}:"
    printf '%s\n' "$cached_all" | sed 's/^/    /' >&2
    note "  Which one a bare \`claude\` loads depends on the version enabledPlugins pins,"
    note "  and that is not decidable from these paths. Picking one would let this report"
    note "  success for a copy no session runs. Pass --hook <path> to name one."
    exit 1
  fi
  cached="$cached_all"
  if [ -n "$cached" ]; then
    HOOK="$cached"
    HOOK_SOURCE="marketplace cache (no --plugin-dir in this process tree)"
  else
    note "preflight-supply: cannot tell which copy of supply-ground.sh a session would load."
    note "  No ancestor process declares --plugin-dir for memory-mirror, so this is not"
    note "  a session launched through scripts/claude-session, and the marketplace cache"
    note "  under ${cache_root} contains no supply-ground.sh either."
    note "  That second state is not 'stale' — a bare \`claude\` here runs NO supply hook"
    note "  at all, which looks identical to supply mode being broken."
    note "  Re-run from a scripts/dev/claude session, or pass --hook <path> deliberately."
    exit 1
  fi
fi

# A hook path that is not there must be LOUD. Without this, `bash <missing>`
# writes nothing to stdout, the leg classifies as `silent`, and `silent` is a
# legitimate result meaning "a miss, a timeout, or nothing fresh to inject" — so
# a typo'd --hook reports a plausible pre-flight outcome and exits 0. That is the
# same false-green shape this whole script exists to remove, arriving through its
# own front door.
if [ ! -r "$HOOK" ]; then
  note "preflight-supply: '$HOOK' is not a readable file (chosen via $HOOK_SOURCE)."
  note "  Refusing to run: a missing hook emits nothing, and 'emitted nothing' is"
  note "  also what a legitimate miss looks like. The two must not share an exit code."
  exit 1
fi

# Drift between what you are editing and what will run. Reported always, because
# "identical" is itself the answer to the question an editor is asking.
SIBLING="$SELF_DIR/supply-ground.sh"
DRIFT="n/a"
if [ -f "$SIBLING" ]; then
  if [ "$(cd "$(dirname "$SIBLING")" && pwd)/$(basename "$SIBLING")" = "$HOOK" ]; then
    DRIFT="same-file"
  elif cmp -s "$SIBLING" "$HOOK"; then
    DRIFT="identical"
  else
    DRIFT="DIFFERS"
  fi
fi

# ── Credentials, from the REAL home, passed explicitly into the isolated one ──
API_KEY="${MOLLOW_MEMORY_API_KEY:-}"
API_URL="${MOLLOW_MEMORY_URL:-}"
WS_ID="${MOLLOW_SUPPLY_WORKSPACE_ID:-}"
CRED_SOURCE="environment"

# Resolve credentials with the LIVE HOOK'S OWN resolver, not a second copy of the
# rules. `mm_resolve_memory_creds` reads `mm_session_root`'s `.session-config`
# plus the one-value `supply-workspace-id` file, and the earlier version of this
# script reimplemented a subset of that against `$PWD` — so any session whose cwd
# was not the session root, or whose key reached the hook by a path this script
# did not know, got a pre-flight run on DIFFERENT credentials from the live hook.
# It would then report a refusal the live session never sees, or a `served` the
# live session cannot reproduce (Greptile, #6526).
#
# Sourced from the chosen hook's own directory, so it is the resolver that
# belongs to the copy being tested — a worktree hook resolves by its worktree's
# rules and a cached hook by the cached ones. `_common.sh` missing next to the
# hook is a hard stop: the hook itself sources it unconditionally, so it could not
# run either, and that has to be said rather than surfacing as an empty leg.
HOOK_DIR="$(cd "$(dirname "$HOOK")" && pwd)"
if [ ! -r "$HOOK_DIR/_common.sh" ]; then
  note "preflight-supply: $HOOK has no readable _common.sh beside it."
  note "  ${HOOK_DIR}/_common.sh is missing, and supply-ground.sh sources it before"
  note "  anything else — so the hook could not run, and every leg would come back"
  note "  empty and classify as a legitimate miss. Refusing instead."
  exit 1
fi
# shellcheck source=/dev/null
. "$HOOK_DIR/_common.sh"
if [ -z "$API_KEY" ] || [ -z "$API_URL" ] || [ -z "$WS_ID" ]; then
  mm_resolve_memory_creds || true
  API_KEY="${MOLLOW_MEMORY_API_KEY:-$API_KEY}"
  API_URL="${MOLLOW_MEMORY_URL:-$API_URL}"
  WS_ID="${MOLLOW_SUPPLY_WORKSPACE_ID:-$WS_ID}"
  CRED_SOURCE="mm_resolve_memory_creds (the hook's own resolver)"
fi
API_URL="${API_URL:-https://mollow.ai/mcp/v2}"

if [ -z "$API_KEY" ]; then
  note "preflight-supply: no MOLLOW_MEMORY_API_KEY after the hook's own resolver ran."
  note "  mm_resolve_memory_creds found none, so the live hook would not have one either"
  note "  and mm_ready would exit before any request. Every leg would report the same 404"
  note "  and none of it would be about the server."
  exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/mm-preflight-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

STDIN_JSON="$(jq -cn --arg q "$QUERY" \
  '{prompt: $q, session_id: "preflight-supply", transcript_path: ""}')"

# Classify the hook's OWN OUTPUT — the additionalContext a person would see —
# rather than re-issuing the request here. Re-issuing would test this script's
# idea of the wire shape; running the hook tests the hook.
classify() {
  local ctx="$1"
  case "$ctx" in
    "") printf 'silent' ;;
    *"422 invalid_mode"*) printf 'invalid_mode' ;;
    *"answered 404"*) printf 'not_found' ;;
    *"400 workspace_not_named"* | *"403 workspace_not_yours"*) printf 'workspace' ;;
    *"handed you POINTERS"* | *"Facts from your memory"*) printf 'served' ;;
    *"Mollow supply mode:"*) printf 'refused' ;;
    *) printf 'served' ;;
  esac
}

run_leg() {
  local leg="$1" pointer_flag="" home tmp out ctx rc err
  if [ "$leg" = "pointer" ]; then pointer_flag="on"; fi
  home="$SANDBOX/$leg/home"
  tmp="$SANDBOX/$leg/tmp"
  err="$SANDBOX/$leg.err"
  mkdir -p "$home/.mollow" "$tmp"
  # Keep the EXIT STATUS and the stderr. supply-ground.sh is fail-open by
  # contract — every path in it ends at `exit 0` — so a non-zero exit does not
  # mean "the grounding failed", it means the hook could not run at all: a missing
  # companion file, a syntax error, an unset variable under `set -u`. Discarding
  # the status made that case emit nothing and classify as `silent`, which is a
  # LEGITIMATE outcome meaning a miss or nothing fresh. The pre-flight would then
  # report a plausible result for a hook that never reached the network
  # (Greptile, #6526) — the same false-green as the missing-hook case above, one
  # level deeper.
  if out="$(printf '%s' "$STDIN_JSON" | env -i \
    PATH="$PATH" HOME="$home" TMPDIR="$tmp" \
    MOLLOW_MEMORY_API_KEY="$API_KEY" \
    MOLLOW_MEMORY_URL="$API_URL" \
    MOLLOW_SUPPLY_WORKSPACE_ID="$WS_ID" \
    MOLLOW_SUPPLY_MODE=on \
    ${pointer_flag:+MOLLOW_SUPPLY_POINTER_MODE=$pointer_flag} \
    bash "$HOOK" 2>"$err")"; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    LEG_CLASS="hook_error"
    local errtext=""
    if [ -r "$err" ]; then errtext="$(cat "$err" 2>/dev/null || true)"; fi
    errtext="${errtext:0:160}"
    LEG_DETAIL="the hook exited $rc — it is fail-open by contract, so this means it could not run: ${errtext//$'\n'/ }"
    return 0
  fi
  ctx="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null || true)"
  LEG_CLASS="$(classify "$ctx")"
  # Truncated with parameter expansion, NOT `printf | head -c`. Under
  # `set -e` + `pipefail` that pipeline aborts the whole runner on exactly the
  # healthy path: `head` closes the pipe at 220 bytes, `printf` takes SIGPIPE and
  # exits 141, `pipefail` surfaces it, and `-e` ends the script before the leg
  # result is printed or `--expect-*` is checked. A SUCCESSFUL grounding with a
  # long facts context would kill the pre-flight (Greptile, #6526).
  #
  # It does not fire on a short context, which is why a live run looked fine: a
  # context under the ~64KB pipe buffer lets `printf` finish before `head` closes.
  # Measured — 200KB of context exits 141 and prints nothing.
  LEG_DETAIL="${ctx:0:220}"
  LEG_DETAIL="${LEG_DETAIL//$'\n'/ }"
}

note "hook:    $HOOK"
note "chosen:  $HOOK_SOURCE"
note "editing: $SIBLING"
if [ "$DRIFT" = "DIFFERS" ]; then
  note "DRIFT:   the copy you are editing is NOT the copy that ran. Your edits did not load."
else
  note "drift:   $DRIFT"
fi
note "target:  $API_URL"
note "creds:   $CRED_SOURCE"
# ── The client-side opt-in is a SEPARATE fact from the server-side flag ───────
# The pointer leg forces MOLLOW_SUPPLY_POINTER_MODE=on for itself, because its job
# is to ask the server for pointer mode. That says nothing about whether the
# operator's OWN sessions will ask for it — `mm_supply_pointer_enabled` reads that
# variable, and while it is unset every real session keeps requesting `facts` no
# matter what the server-side flag says. So `--expect-pointer served` passing is
# necessary and NOT sufficient for "the demo will show pointers", and reporting
# only the server half would let a green pre-flight stand in for a configuration
# that is still half off (Greptile, #6526).
CLIENT_POINTER="${MOLLOW_SUPPLY_POINTER_MODE:-}"
if [ -n "$CLIENT_POINTER" ]; then
  note "client:  MOLLOW_SUPPLY_POINTER_MODE=$CLIENT_POINTER in this environment"
else
  note "client:  MOLLOW_SUPPLY_POINTER_MODE is UNSET here — the pointer leg forces it on for"
  note "         itself, so a served pointer leg proves the SERVER side only. Real sessions in"
  note "         this environment still request facts until this is exported."
fi
note ""

RC=0
$JSON_OUT || printf '%-9s %-14s %s\n' "LEG" "CLASS" "DETAIL"
for leg in $LEGS; do
  case "$leg" in
    facts | pointer) ;;
    *) note "preflight-supply: unknown leg '$leg'"; exit 1 ;;
  esac
  run_leg "$leg"
  # `hook_error` is never a result about the server, so it can never be an
  # expectation that is "met" — it fails the run outright, even under
  # `--expect-pointer hook_error`, which is not a configuration anyone wants to
  # assert. Exit 1, the same code the unreadable-hook and missing-_common cases
  # use: all three mean the pre-flight did not happen.
  if [ "$LEG_CLASS" = "hook_error" ]; then
    note "preflight-supply: the $leg leg could not run the hook."
    note "  $LEG_DETAIL"
    exit 1
  fi
  expected=""
  if [ "$leg" = "facts" ]; then expected="$EXPECT_FACTS"; fi
  if [ "$leg" = "pointer" ]; then expected="$EXPECT_POINTER"; fi
  verdict="-"
  if [ -n "$expected" ]; then
    if [ "$LEG_CLASS" = "$expected" ]; then
      verdict="ok"
    else
      verdict="EXPECTED $expected"
      RC=2
    fi
  fi
  if $JSON_OUT; then
    jq -cn --arg leg "$leg" --arg class "$LEG_CLASS" --arg detail "$LEG_DETAIL" \
      --arg expected "$expected" --arg verdict "$verdict" --arg hook "$HOOK" --arg drift "$DRIFT" \
      '{leg: $leg, class: $class, expected: $expected, verdict: $verdict, hook: $hook, drift: $drift, detail: $detail}'
  else
    printf '%-9s %-14s %s\n' "$leg" "$LEG_CLASS" "$LEG_DETAIL"
    [ "$verdict" = "-" ] || printf '%-9s %-14s %s\n' "" "" "-> $verdict"
  fi
done

exit $RC
