#!/usr/bin/env bash
# PreToolUse(Bash|Write|Edit|MultiEdit): the Engram guardrail gate (MOL-2336).
#
# Generalizes the original TDD gate into a warn-on-violation guardrail layer:
#
#   * Seeded local predicates (guardrail-predicates-mollow.sh) — deterministic,
#     :warn-only conventions from CLAUDE.md. Surfaced as NON-BLOCKING
#     additionalContext; the tool call proceeds.
#   * TDD — folded in as the one :block rule. Same git-diff / expected-test-path
#     check as before; blocks an implementation edit with no test change this
#     session. Armed by arm-guardrails.sh (SessionStart) only on an Engram TDD
#     preference; a missing marker => no TDD enforcement.
#   * Override capture — when a :block is bypassed, record a DECISION via
#     POST /api/memory/guardrails/override (feeds the decompile/revise loop).
#
# Forward seam: per-workspace WayOfWorking rules distilled by MOL-2335 are fetched
# by the SessionStart arm hook for the self-check checklist. Per-tool server
# evaluation (POST /guardrails/evaluate) is wired behind MOLLOW_GUARDRAILS_SERVER_EVAL
# and OFF by default (MOL-7848 spike): with the flag unset the per-call path does
# zero network I/O, so it works offline with zero per-tool latency, as before.
# With it on, every Bash|Write|Edit|MultiEdit call pays one round trip.
#
# Block contract (unchanged): print {decision:"block", reason} to stdout, exit 2.
# Warn contract: print {hookSpecificOutput:{hookEventName,additionalContext}}, exit 0.
# Bypass: `mkdir -p tmp && touch tmp/.skip-tdd` at the repo root, or SKIP_TDD=1. Fail-safe: any error => exit 0.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh" # mm_emit_context, mm_post, mm_ready, mm_project_of, mm_tdd_marker; sets -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0

INPUT="$(cat)"
TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$TOOL_NAME" in
  Bash | Write | Edit | MultiEdit) ;;
  *) exit 0 ;;
esac

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
CWD="$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null || true)"
REPO_ROOT="$(cd "${CWD:-$PWD}" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null || true)"

# Tool-specific matchable text (mirrors Mollow.Engram.Guardrails.matchable_texts).
CMD=""
FILE_PATH=""
CONTENT=""
case "$TOOL_NAME" in
  Bash)
    CMD="$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
    ;;
  Write)
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.content // empty' 2>/dev/null || true)"
    ;;
  Edit)
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    # Only the new text: content predicates flag what an edit INTRODUCES. Scanning
    # old_string too would warn on a pattern being removed (e.g. :string → :text).
    CONTENT="$(printf '%s' "$INPUT" | jq -r '.tool_input.new_string // empty' 2>/dev/null || true)"
    ;;
  MultiEdit)
    FILE_PATH="$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true)"
    CONTENT="$(printf '%s' "$INPUT" | jq -r '[(.tool_input.edits // [])[] | .new_string] | map(select(. != null)) | join("\n")' 2>/dev/null || true)"
    ;;
esac

# ── Seeded local predicates (warn-only; absent file => skipped, never fatal) ───
WARN_LINES=""
if [ -f "$DIR/guardrail-predicates-mollow.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/guardrail-predicates-mollow.sh"
  WARN_LINES="$(mollow_guardrail_predicates "$TOOL_NAME" "$CMD" "$FILE_PATH" "$CONTENT" "$CWD" 2>/dev/null || true)"
fi

# ── Server evaluation (opt-in; MOL-7848) ──────────────────────────────────────
# Ships the pending call to Mollow.Engram.Guardrails.evaluate/2 and merges its
# warnings into WARN_LINES; a server :block lands in SERVER_BLOCK_LINES and
# reaches the exit 2 below. The response is trusted only when it parses and says
# ok:true as a single well-formed document — a non-2xx status, an HTML error
# page, trailing garbage, a malformed warnings list, a timeout or no network all
# leave both lists empty.
#
# Failure direction (BLD-032): this fails OPEN, and the cost it accepts is silent
# under-reporting — an unreachable server means its rules are not checked and
# nothing says so. The cost it refuses is failing a customer's tool call on a
# network blip, which dominates for an advisory layer.
SERVER_BLOCK_LINES=""
if mm_truthy "${MOLLOW_GUARDRAILS_SERVER_EVAL:-}" && mm_ready; then
  # The hook is killed at 5s (hooks.json), so an override may shorten the bound
  # but never widen it past 2s; a non-integer falls back to 2.
  SERVER_TIMEOUT="${MOLLOW_GUARDRAILS_SERVER_TIMEOUT:-2}"
  case "$SERVER_TIMEOUT" in '' | *[!0-9]*) SERVER_TIMEOUT=2 ;; esac
  [ "$SERVER_TIMEOUT" -ge 1 ] && [ "$SERVER_TIMEOUT" -le 2 ] || SERVER_TIMEOUT=2
  # Not mm_post_read: the request travels on stdin (an argv body past the OS
  # argument limit fails before curl runs, so a large Write would go unchecked),
  # --max-filesize caps what jq must read, and the status rides after the body so
  # only a 2xx is read. --fail alone would still pass a 3xx body through.
  SERVER_RAW="$(printf '%s' "$INPUT" | jq -c '{tool_name, tool_input}' 2>/dev/null |
    curl -sS --fail --max-time "$SERVER_TIMEOUT" --max-filesize 262144 \
      -X POST "$(mm_api_base)/api/memory/guardrails/evaluate" \
      -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
      -H "Content-Type: application/json" \
      -w '\n%{http_code}' \
      --data-binary @- 2>/dev/null)" || SERVER_RAW=""
  case "${SERVER_RAW##*$'\n'}" in
    2[0-9][0-9]) SERVER_RESP="${SERVER_RAW%$'\n'*}" ;;
    *) SERVER_RESP="" ;;
  esac
  # One TSV line per warning: severity, statement, provenance. @tsv escapes any
  # tab or newline inside a server-supplied statement so it cannot split a line.
  # -s plus `length == 1` and jq's own exit status make the parse all-or-nothing:
  # jq prints a stream's first valid document before failing on the rest, so a
  # block followed by an error page would otherwise be read as a block.
  SERVER_LINES="$(printf '%s' "$SERVER_RESP" | jq -rs '
    select(length == 1) | .[0] |
    select(type == "object" and .ok == true and ((.warnings // []) | type) == "array") |
    (.warnings // []) | if all(type == "object") then .[] else error("malformed") end |
    [(.severity // "warn" | tostring),
     (.statement // "" | tostring),
     ("Mollow rule " + (.rule_hash // "?" | tostring)
       + (if .matched_text then " — matched: " + (.matched_text | tostring | .[0:120]) else "" end))]
    | @tsv' 2>/dev/null)" || SERVER_LINES=""
  if [ -n "$SERVER_LINES" ]; then
    SERVER_BLOCK_LINES="$(printf '%s\n' "$SERVER_LINES" | awk -F'\t' '$1 == "block"')"
    SERVER_WARN_LINES="$(printf '%s\n' "$SERVER_LINES" | awk -F'\t' '$1 != "block" {OFS="\t"; $1 = "warn"; print}')"
    if [ -n "$SERVER_WARN_LINES" ]; then
      WARN_LINES="${WARN_LINES:+${WARN_LINES}
}${SERVER_WARN_LINES}"
    fi
  fi
fi

# ── TDD :block predicate (the original gate, scoped to file edits) ─────────────
# Returns 0 + sets BLOCK_REL/BLOCK_PRIMARY when the edit must be blocked; returns
# 1 (allow) otherwise. Only evaluated for Write|Edit|MultiEdit on a clearly-mapped
# implementation file in an armed session; everything else falls through to allow.
BLOCK_REL=""
BLOCK_PRIMARY=""
tdd_would_block() {
  case "$TOOL_NAME" in Write | Edit | MultiEdit) ;; *) return 1 ;; esac
  [ -n "$FILE_PATH" ] || return 1
  [ -n "$REPO_ROOT" ] || return 1

  # Armed? No marker for this session => TDD off.
  [ -n "$SESSION_ID" ] || return 1
  local marker
  marker="$(mm_tdd_marker "${CWD:-$PWD}" "$SESSION_ID")" || return 1
  [ -f "$marker" ] || return 1
  # Keep an in-use marker clear of arm-guardrails.sh's 14-day prune.
  touch "$marker" 2>/dev/null || true

  # Make the target repo-relative; ignore files outside the repo.
  local rel
  case "$FILE_PATH" in
    /*)
      rel="${FILE_PATH#"$REPO_ROOT"/}"
      case "$rel" in /*) return 1 ;; esac
      ;;
    *) rel="$FILE_PATH" ;;
  esac

  # Classify + derive the expected test path candidates. Only implementation logic
  # is gated; tests, configs, .heex, migrations, docs, and vendored deps fall
  # through to allow. PRIMARY is named in the block message; CANDIDATES are the
  # newline-separated acceptable test paths — allowed if ANY appears in this
  # session's working-tree changes. Unmapped files fall through to allow.
  local name dir stem PRIMARY CANDIDATES
  name="$(basename "$rel")"
  dir="$(dirname "$rel")"
  stem="${name%.*}"
  PRIMARY=""
  CANDIDATES=""

  case "$rel" in
    # Generated / vendored trees — at the repo root or nested. The leading-segment
    # forms (deps/*, …) catch root-level vendored dirs that */deps/* would miss and
    # that would otherwise fall through to an implementation mapping (e.g.
    # deps/<pkg>/lib/x.ex matching */lib/*.ex).
    deps/* | node_modules/* | _build/* | out/* | dist/* | \
      */deps/* | */node_modules/* | */_build/* | */out/* | */dist/*)
      return 1
      ;;

    # Elixir.
    */lib/*.ex | lib/*.ex)
      if [[ "$rel" == lib/* ]]; then
        PRIMARY="test/${rel#lib/}"
      else
        PRIMARY="${rel/\/lib\//\/test\/}"
      fi
      PRIMARY="${PRIMARY%.ex}_test.exs"
      CANDIDATES="$PRIMARY"
      ;;

    # Python (webapp ML).
    webapp/priv/python/*.py)
      case "$name" in test_*.py | *_test.py) return 1 ;; esac
      PRIMARY="${dir}/test_${stem}.py"
      CANDIDATES="$PRIMARY"
      ;;

    # VS Code extensions (Mocha; tests under <ext>/src/test/suite).
    extensions/*/src/*.ts | extensions/*/src/*.tsx)
      case "$rel" in
        *.d.ts | *.test.ts | *.test.tsx | *.spec.ts | *.spec.tsx | */src/test/*) return 1 ;;
      esac
      local ext_root sub
      ext_root="${rel%%/src/*}"
      sub="${rel#"${ext_root}"/src/}"
      PRIMARY="${ext_root}/src/test/suite/${stem}.test.ts"
      CANDIDATES="${PRIMARY}
${ext_root}/src/test/suite/${sub%.*}.test.ts"
      ;;

    # webapp/assets/js (Jest; co-located __tests__).
    webapp/assets/js/*.ts | webapp/assets/js/*.tsx)
      case "$rel" in
        *.d.ts | *.test.ts | *.test.tsx | *.spec.ts | *.spec.tsx) return 1 ;;
        */__tests__/* | */__mocks__/* | webapp/assets/js/types/*) return 1 ;;
      esac
      PRIMARY="${dir}/__tests__/${stem}.test.ts"
      CANDIDATES="${PRIMARY}
${dir}/__tests__/${stem}.test.tsx"
      ;;

    # browser-extension (Vitest; flat test/).
    browser-extension/src/*.js | browser-extension/src/*.ts)
      case "$rel" in
        *.d.ts | *.test.js | *.test.ts | *.spec.js | *.spec.ts) return 1 ;;
      esac
      PRIMARY="browser-extension/test/${stem}.test.js"
      CANDIDATES="$PRIMARY"
      ;;

    # iOS Swift (XCTest target).
    ios/MollowWorkstation/MollowWorkstation/*.swift)
      case "$rel" in
        */MollowWorkstationTests/* | *Tests.swift) return 1 ;;
      esac
      PRIMARY="ios/MollowWorkstation/MollowWorkstationTests/${stem}Tests.swift"
      CANDIDATES="$PRIMARY"
      ;;

    # Rust (bridge). Tests live in an external module file (idiomatic
    # `#[cfg(test)] mod tests;` -> <name>/tests.rs) or a tests/ integration file.
    bridge/tauri-app/src-tauri/src/*.rs)
      case "$rel" in
        *_test.rs | *_tests.rs | */tests.rs | */tests/* | */build.rs) return 1 ;;
      esac
      # Transitional: existing files still using inline #[cfg(test)] blocks count
      # as tested, so ongoing bridge work isn't blocked before migration.
      if [ -f "${REPO_ROOT}/${rel}" ] && grep -q '#\[cfg(test)\]' "${REPO_ROOT}/${rel}" 2>/dev/null; then
        return 1
      fi
      PRIMARY="${dir}/${stem}/tests.rs"
      CANDIDATES="${PRIMARY}
bridge/tauri-app/src-tauri/tests/${stem}.rs"
      ;;

    # Shell (scripts/; test-<name>.sh convention).
    scripts/*.sh)
      case "$name" in test-*.sh) return 1 ;; esac
      case "$rel" in scripts/tests/*) return 1 ;; esac
      PRIMARY="${dir}/test-${stem}.sh"
      CANDIDATES="${PRIMARY}
scripts/test-${stem}.sh
scripts/tests/test-${stem}.sh"
      ;;

    *) return 1 ;;
  esac

  # Test written this session? Tracked changes vs HEAD plus untracked files.
  local CHANGED cand
  CHANGED="$(
    cd "$REPO_ROOT" 2>/dev/null && {
      git diff --name-only HEAD 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    }
  )"
  while IFS= read -r cand; do
    [ -z "$cand" ] && continue
    if printf '%s\n' "$CHANGED" | grep -Fxq "$cand"; then
      return 1
    fi
  done <<EOF
$CANDIDATES
EOF

  BLOCK_REL="$rel"
  BLOCK_PRIMARY="$PRIMARY"
  return 0
}

# Record a bypassed :block as a guardrail override (DECISION event). Best-effort
# and synchronous (a backgrounded curl can be SIGHUP-killed on hook exit); the
# POST is sub-second against the 5s hook timeout.
record_tdd_override() {
  mm_ready || return 0
  local body
  body="$(jq -cn \
    --arg rel "${BLOCK_REL:-}" --arg tool "$TOOL_NAME" --arg sid "$SESSION_ID" \
    --arg project "$(mm_project_of "$CWD")" '{
      rule_hash: "local:tdd-gate",
      rule_id: "local:tdd-gate",
      statement: "TDD: write the failing test before implementation code",
      severity: "block",
      tool: $tool,
      matched_text: $rel,
      reason: "bypassed via tmp/.skip-tdd or SKIP_TDD",
      project: $project,
      session_id: $sid
    }' 2>/dev/null || true)"
  [ -n "$body" ] && mm_post "/api/memory/guardrails/override" "$body" 3
}

# ── Decision ──────────────────────────────────────────────────────────────────
bypass_active() {
  [ "${SKIP_TDD:-0}" = "1" ] && return 0
  [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/tmp/.skip-tdd" ] && return 0
  return 1
}

if tdd_would_block; then
  if bypass_active; then
    record_tdd_override # proceeding past the block — log it, then fall through to warn.
  else
    reason="TDD is on (your Engram preference). No test changes detected for this implementation file.

Write or extend the failing test first:
  ${BLOCK_PRIMARY}
then implement:
  ${BLOCK_REL}

Refactor-only change already covered by existing tests? Bypass this edit with:
  mkdir -p $(printf '%q' "${REPO_ROOT}/tmp") && touch $(printf '%q' "${REPO_ROOT}/tmp/.skip-tdd")"
    if [ -n "$WARN_LINES" ]; then
      reason="${reason}

Also flagged (advisory):
$(printf '%s\n' "$WARN_LINES" | awk -F'\t' 'NF>=2 {print "  • " $2}')"
    fi
    jq -n --arg r "$reason" '{decision: "block", reason: $r}'
    exit 2
  fi
fi

# A server :block has no bypass in the spike: the flag that enables the server
# path is the only way past it.
if [ -n "$SERVER_BLOCK_LINES" ]; then
  reason="Blocked by a Mollow guardrail rule:
$(printf '%s\n' "$SERVER_BLOCK_LINES" | awk -F'\t' 'NF>=2 {print "  • " $2 "\n    ↳ " $3}')"
  if [ -n "$WARN_LINES" ]; then
    reason="${reason}

Also flagged (advisory):
$(printf '%s\n' "$WARN_LINES" | awk -F'\t' 'NF>=2 {print "  • " $2}')"
  fi
  jq -n --arg r "$reason" '{decision: "block", reason: $r}'
  exit 2
fi

# No block (or bypassed): surface any warnings as advisory context, then allow.
if [ -n "$WARN_LINES" ]; then
  ctx="$(
    printf 'Guardrail check — advisory, the call proceeds:\n'
    printf '%s\n' "$WARN_LINES" | awk -F'\t' 'NF>=3 {print "  • " $2 "\n    ↳ " $3}'
  )"
  mm_emit_context "PreToolUse" "$ctx"
fi
exit 0
