#!/usr/bin/env bash
# UserPromptSubmit: find the user's most similar past decisions for THIS prompt
# and inject them so Claude pre-recommends the option they'd historically pick
# (e.g. ordering an AskUserQuestion's "(Recommended)" option to match).
#
# Fires on EVERY prompt, so it runs on a tight 2s budget and no-ops on any miss.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

mm_ready || exit 0

input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
project="$(mm_project_of "$cwd")"

[ -z "$prompt" ] && exit 0

body="$(jq -cn --arg q "$prompt" --arg p "$project" '{question: $q, project: $p, limit: 3}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Hard 2s cap; empty output on timeout/failure keeps the turn snappy.
resp="$(mm_post_read "/api/memory/decisions/recall" "$body" 2)"
[ -z "$resp" ] && exit 0

ctx="$(printf '%s' "$resp" | jq -r '
  (.past_decisions // []) as $ds
  | if ($ds | length) == 0 then empty
    else
      "Relevant past decisions for this request (propose answers consistent with these unless the user signals otherwise):\n"
      + ([ $ds[]
            | "- " + (.question // "decision") + " -> chose " + (.chosen // "?")
              + (if .rationale then " (" + .rationale + ")" else "" end) ]
         | join("\n"))
    end
  ' 2>/dev/null || true)"

mm_emit_context "UserPromptSubmit" "$ctx"
exit 0
