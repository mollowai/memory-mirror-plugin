#!/usr/bin/env bash
# SessionStart: inject the user's decision profile (how they have decided before)
# so Claude proposes answers consistent with past choices. Read-path, deterministic.
#
# Fail-safe: no key / no jq / no/empty response => no context injected, exit 0.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

mm_ready || exit 0

input="$(cat)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
project="$(mm_project_of "$cwd")"
project_enc="$(jq -rn --arg p "$project" '$p|@uri' 2>/dev/null || true)"

resp="$(mm_get "/api/memory/decision-profile?project=${project_enc}" 2)"
[ -z "$resp" ] && exit 0

ctx="$(printf '%s' "$resp" | jq -r '
  (.decision_profile.recorded_decisions // []) as $ds
  | if ($ds | length) == 0 then empty
    else
      "Your recorded decisions (how you have decided before — prefer answers consistent with these unless the user signals otherwise):\n"
      + ([ $ds[]
            | "- " + (.question // "decision") + " -> chose " + (.chosen // "?")
              + (if .rationale then " (" + .rationale + ")" else "" end) ]
         | join("\n"))
    end
  ' 2>/dev/null || true)"

mm_emit_context "SessionStart" "$ctx"
exit 0
