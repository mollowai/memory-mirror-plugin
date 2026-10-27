#!/usr/bin/env bash
# Portable authored-doctrine guardrail predicates (MOL-7864).
#
# The PUBLIC, SANITIZED sibling of guardrail-predicates-mollow.sh. Where that
# file hardcodes Mollow-monorepo conventions in shell (and is STRIPPED from the
# public plugin by MOL-2182), this one is data-driven: the rules live in a JSON
# data file, so one authored coding doctrine can be shipped to every customer
# with no repo-specific shell and no Mollow credential.
#
# ┌─ INTEGRATION POINT (MOL-7974) ──────────────────────────────────────────────┐
# │ The DOCTRINE CONTENT is authored separately (MOL-7974) and dropped in as the │
# │ data file this loader reads. This file is only the PLUMBING. To activate a   │
# │ doctrine, place it at  guardrail-predicates.json  next to this script (the   │
# │ packaging step copies guardrail-predicates.sample.json there), or point      │
# │ MOLLOW_PORTABLE_PREDICATES_FILE at it. See guardrail-predicates.sample.json   │
# │ for the file shape and the sanitizer contract.                               │
# └──────────────────────────────────────────────────────────────────────────────┘
#
# Contract (mirrors mollow_guardrail_predicates):
#   portable_guardrail_predicates <tool> <cmd> <file> <content> <cwd>
# echoes zero or more TSV warning lines — "warn\t<short>\t<fix>" — one per matched
# predicate, in the exact shape guardrails-gate.sh renders. No network, no side
# effects, never fails the caller. Absent/malformed data file => zero lines.
#
# SEVERITY: portable predicates are WARN-ONLY, by design. :block is reserved for
# TDD + server rules, which carry override-recording plumbing and a credential;
# a block here would fail a customer's tool call OFFLINE, against the gate's
# fail-safe contract. The data file may carry a `severity` field for forward
# compatibility, but this loader always emits `warn`.
#
# SANITIZER (MOL-2182): the data file MUST contain no monorepo paths and no
# /workspaces/ assumptions. check_portable_predicates_sanitized() below is the
# enforceable check; the test suite and the packaging step both run it.

_PGP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Resolve the active data file: explicit override wins, else the conventional
# path next to this script. The ".sample.json" template is never auto-loaded —
# it is activated by copying it to this path (packaging) or by MOL-7974 writing
# its doctrine here directly.
_pgp_data_file() {
  if [ -n "${MOLLOW_PORTABLE_PREDICATES_FILE:-}" ]; then
    printf '%s' "$MOLLOW_PORTABLE_PREDICATES_FILE"
  else
    printf '%s' "${_PGP_DIR}/guardrail-predicates.json"
  fi
}

portable_guardrail_predicates() {
  # $5 (cwd) is accepted for signature parity with mollow_guardrail_predicates
  # but unused here, so it is intentionally not captured.
  local tool="$1" cmd="$2" file="$3" content="$4"
  command -v jq >/dev/null 2>&1 || return 0
  local data
  data="$(_pgp_data_file)"
  [ -f "$data" ] || return 0

  # The COMPLETE per-predicate evaluation — including the `applies_to`/index
  # check, which can itself throw on a wrong-type `applies_to` (e.g. a number) —
  # is wrapped in `try … catch empty`, so one malformed rule (bad regex, wrong
  # type) is skipped without killing the rules that follow it or failing the
  # gate. @tsv escapes any tab/newline inside a message so a rule cannot forge
  # extra warning lines. (The trailing `|| true` is the whole-file fail-safe for
  # a data file that is not valid JSON; it never reaches past a per-rule throw.)
  jq -r \
    --arg tool "$tool" \
    --arg cmd "$cmd" \
    --arg file "$file" \
    --arg content "$content" '
    (.predicates // [])[]
    | . as $p
    | try (
        if (($p.applies_to // []) | index($tool)) == null then empty
        else
          (if   $p.target == "command"   then $cmd
           elif $p.target == "file_path" then $file
           elif $p.target == "content"   then $content
           else "" end) as $text
          | if $text == "" then empty
            elif ($text | test(($p.pattern // "(?!)"); ($p.flags // "")))
            then ["warn", ($p.message // "" | tostring), ($p.fix // "" | tostring)] | @tsv
            else empty
            end
        end
      ) catch empty
  ' "$data" 2>/dev/null || true
}

# MOL-2182 sanitizer: fail if a data file's RULES embed a monorepo path, a
# /workspaces/ assumption, or a Mollow-internal identifier. Scans the string
# values inside `.predicates` (id/applies_to/target/pattern/flags/message/fix) —
# i.e. everything that becomes shipped doctrine behavior — NOT the meta/doc keys
# (those prefixed `_`), which legitimately NAME the forbidden tokens to describe
# this very contract. A file that will not parse as JSON cannot be cleared, so
# that returns 2 (treated as a failure by the packaging gate).
# Returns 0 clean, 1 if any forbidden token is present (prints each hit), 2 if
# the file is missing or unparseable.
check_portable_predicates_sanitized() {
  local data="$1" rc=0 pat values
  [ -f "$data" ] || { echo "sanitizer: no such file: $data" >&2; return 2; }
  command -v jq >/dev/null 2>&1 || { echo "sanitizer: jq required" >&2; return 2; }
  # Flatten every scalar reachable under .predicates to one value per line.
  values="$(jq -r '[(.predicates // [])[] | .. | strings] | .[]' "$data" 2>/dev/null)" \
    || { echo "sanitizer: $data is not valid JSON — cannot verify" >&2; return 2; }
  # Forbidden, case-insensitive, as extended-regex alternatives:
  #   /workspaces/            yolo container path assumption
  #   mollowai/monorepo       the private repo slug
  #   github.com/mollowai     any Mollow-internal repo URL
  #   monorepo-business / -shopwatch  sibling private repos
  #   /Users/<name>/          an author's absolute home path
  for pat in \
    '/workspaces/' \
    'mollowai/monorepo' \
    'github\.com/mollowai' \
    'monorepo-business' \
    'monorepo-shopwatch' \
    '/Users/[A-Za-z0-9._-]+/'; do
    if printf '%s\n' "$values" | grep -nEi "$pat" >/dev/null 2>&1; then
      echo "sanitizer: forbidden token /$pat/ in a predicate of $data:" >&2
      printf '%s\n' "$values" | grep -nEi "$pat" >&2
      rc=1
    fi
  done
  return $rc
}
