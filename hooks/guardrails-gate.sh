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

# ── Portable authored-doctrine predicates (warn-only; data-file driven) ───────
# The PUBLIC, SANITIZED slot (MOL-7864): the vehicle for one authored coding
# doctrine shipped to every customer with NO Mollow credential. The loader is
# zero-network; it reads a local JSON data file (guardrail-predicates.json, or
# MOLLOW_PORTABLE_PREDICATES_FILE). Absent loader OR absent data file => skipped,
# never fatal — so the gate still fails safe offline. MOL-7974 supplies the
# data-file CONTENT (see guardrail-predicates.sample.json); this is the plumbing.
if [ -f "$DIR/guardrail-predicates-portable.sh" ]; then
  # shellcheck source=/dev/null
  . "$DIR/guardrail-predicates-portable.sh"
  PORTABLE_WARN_LINES="$(portable_guardrail_predicates "$TOOL_NAME" "$CMD" "$FILE_PATH" "$CONTENT" "$CWD" 2>/dev/null || true)"
  if [ -n "$PORTABLE_WARN_LINES" ]; then
    WARN_LINES="${WARN_LINES:+${WARN_LINES}
}${PORTABLE_WARN_LINES}"
  fi
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
SERVER_WARN_LINES=""
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
  SERVER_RAW="$(printf '%s' "$INPUT" |
    jq -c --arg project "$(mm_project_of "$CWD")" '{tool_name, tool_input, project: $project}' 2>/dev/null |
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
       + (if .matched_text then " — matched: " + (.matched_text | tostring | .[0:120]) else "" end)),
     (.rule_hash // "" | tostring),
     (.matched_text // "" | tostring | .[0:120])]
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
# Record that someone proceeded past a rule. Args: hash, statement, severity,
# matched text, reason.
#
# This took its rule as ARGUMENTS from MOL-7846 onward. It used to hardcode
# `local:tdd-gate` in all five fields, so every record in the stream named the
# same rule however many rules existed — which made the override count a count of
# one rule's bypasses and made a per-rule retirement loop impossible to build on
# top of. Pass the rule that actually fired.
# How long the whole bypass-recording pass may take, and each request inside it.
# The hook's own budget is what bounds these: the evaluate call above has
# already spent some of it, and the tool call is blocked until this returns.
BYPASS_RECORD_BUDGET_S="${MOLLOW_BYPASS_RECORD_BUDGET_S:-3}"
BYPASS_RECORD_TIMEOUT_S="${MOLLOW_BYPASS_RECORD_TIMEOUT_S:-1}"

record_override_for() {
  mm_ready || return 0
  local body
  body="$(jq -cn \
    --arg hash "$1" --arg statement "$2" --arg severity "$3" \
    --arg matched "$4" --arg reason "$5" \
    --arg tool "$TOOL_NAME" --arg sid "$SESSION_ID" \
    --arg project "$(mm_project_of "$CWD")" '{
      rule_hash: $hash,
      rule_id: $hash,
      statement: $statement,
      severity: $severity,
      tool: $tool,
      matched_text: $matched,
      reason: $reason,
      project: $project,
      session_id: $sid
    }' 2>/dev/null || true)"
  [ -n "$body" ] && mm_post "/api/memory/guardrails/override" "$body" "${6:-3}"
}

record_tdd_override() {
  record_override_for \
    "local:tdd-gate" \
    "TDD: write the failing test before implementation code" \
    "block" \
    "${BLOCK_REL:-}" \
    "bypassed via tmp/.skip-tdd or SKIP_TDD"
}

# ── Decision ──────────────────────────────────────────────────────────────────
bypass_active() {
  [ "${SKIP_TDD:-0}" = "1" ] && return 0
  [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/tmp/.skip-tdd" ] && return 0
  return 1
}

# The escape for a SERVER rule, deliberately not the TDD one. SKIP_TDD names a
# specific rule; reusing it would mean switching off the test discipline to get
# past an unrelated guardrail, and the record would then name the wrong reason.
#
# This exists because a block nobody can get past is a block that gets the whole
# feature switched off the first time it is wrong — and then the rules stop
# applying to everything, not just to the rule that misfired. Taking the escape
# is recorded, so the bypass is data rather than a workaround.
rules_bypass_active() {
  mm_truthy "${SKIP_RULES:-}" && return 0
  [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/tmp/.skip-rules" ] && return 0
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

# Getting past a server :block. Each rule got past is recorded individually, by
# hash — one record per rule, because the retirement loop decides per rule and a
# single lumped record would retire all of them or none.
# An explicit bypass is the only moment a rule's evidence is worth recording,
# and it is worth recording for EVERY rule that fired — not only the ones that
# stopped the call.
#
# Blocks alone would mean a warn-severity rule could never accumulate a single
# escape, and warn is the default severity, so the retirement loop would be dead
# for almost every rule that exists. Found by an adversarial pass, not by the
# tests: a fixture that records overrides directly cannot see that the gate
# never calls the recorder.
#
# A warning on its own is still NOT evidence. This repository's own finding is
# that "a warning is never overridden" — so treating every warning as a
# disagreement would retire every rule after three firings. The signal is
# narrower and honest: somebody said "I know, let me through" WHILE it fired.
#
# Recording is bounded, because this is a hook and the call it gates is waiting.
# Each POST is a separate request, so N rules bypassed on one call meant N
# round trips in series — past the hook's budget the later ones are killed
# mid-flight, which undercounts exactly the rules that fire together and biases
# retirement toward never firing. So: a shared deadline, a short per-request
# timeout, and anything dropped is SAID rather than lost. A silent cap here
# would read as "those rules were never bypassed".
if rules_bypass_active; then
  _escaped="$(printf '%s\n%s' "${SERVER_BLOCK_LINES:-}" "${SERVER_WARN_LINES:-}")"
  _deadline=$((SECONDS + BYPASS_RECORD_BUDGET_S))
  _dropped=0
  while IFS=$'\t' read -r _sev _stmt _prov _hash _matched; do
    [ -n "${_hash:-}" ] || continue
    if [ "$SECONDS" -ge "$_deadline" ]; then
      _dropped=$((_dropped + 1))
      continue
    fi
    # Re-read the text from the ORIGINAL JSON rather than from the TSV line,
    # keeping the TSV path's 120-character bound.
    #
    # The bound is not cosmetic. `matched_text` on a Write or Edit can be the
    # whole matching body — ~140 KiB — and `mm_post` passes its payload as a
    # `curl -d` ARGUMENT, where Linux caps a single argument at 128 KiB
    # (MAX_ARG_STRLEN, 32 pages). Over that, curl never runs, `mm_post` swallows
    # the failure with `|| true`, and the bypass leaves NO record and counts
    # toward nothing. The first version of this re-read dropped the bound the
    # TSV had, which reintroduced exactly that (Greptile, #7410).
    #
    # 120 characters of the ORIGINAL bytes beats 120 characters of escaped ones,
    # which is the whole point of reading from the JSON.
    #
    # jq's @tsv escapes tab, newline, CR and backslash, and `read -r` leaves
    # those escapes as literal two-character sequences. A command containing a
    # backslash — a regex like `\s`, or a line continuation — would be recorded
    # with different bytes than the ones that actually fired the rule, which
    # defeats the point of the record being evidence (Greptile, #7410).
    #
    # Unescaping by hand is the wrong fix: after the fact `\\n` and `\n`
    # are indistinguishable. Going back to the JSON sidesteps the
    # ambiguity entirely. Falls back to the TSV value if the lookup comes back
    # empty, so a malformed response still records something.
    _exact_stmt="$(printf '%s' "$SERVER_RESP" | jq -r --arg h "$_hash" \
      '[.warnings[]? | select((.rule_hash // "" | tostring) == $h)][0].statement // ""' 2>/dev/null || true)"
    _exact_matched="$(printf '%s' "$SERVER_RESP" | jq -r --arg h "$_hash" \
      '[.warnings[]? | select((.rule_hash // "" | tostring) == $h)][0].matched_text // "" | .[0:120]' 2>/dev/null || true)"

    record_override_for "$_hash" "${_exact_stmt:-${_stmt:-}}" "${_sev:-warn}" \
      "${_exact_matched:-${_matched:-}}" \
      "proceeded past it via tmp/.skip-rules or SKIP_RULES" "$BYPASS_RECORD_TIMEOUT_S"
  done <<<"$_escaped"
  if [ "$_dropped" -gt 0 ]; then
    printf 'mollow guardrails: %d bypass record(s) not sent — %ss budget spent. Those rules will undercount toward retirement.\n' \
      "$_dropped" "$BYPASS_RECORD_BUDGET_S" >&2
  fi
  # The warnings are still SHOWN below: recording a disagreement is not a reason
  # to hide what was disagreed with.
  SERVER_BLOCK_LINES=""
fi

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
