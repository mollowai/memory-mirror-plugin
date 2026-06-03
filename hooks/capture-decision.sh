#!/usr/bin/env bash
# PostToolUse(AskUserQuestion): deterministically record each decision the user
# just made to cross-session memory (staging), in real time.
#
# The AskUserQuestion tool_response is the rendered STRING
#   Your questions have been answered: "Q"="A", "Q2"="A2". You can now continue...
# (verified against real transcripts), so we parse that — with the structured
# {answers: {...}} object as a fallback in case a Claude Code version provides it.
# Options for each question (to compute the rejected set) come from tool_input.
#
# Fail-safe: never blocks the session. No key / no jq / unexpected payload => no-op.

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

mm_ready || exit 0

input="$(cat)"
cwd="$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null || true)"
sid="$(jq -r '.session_id // empty' <<<"$input" 2>/dev/null || true)"
project="$(mm_project_of "$cwd")"

# 1) Structured form (only if tool_response is an object with .answers).
pairs="$(jq -c '
  (.tool_response | if type == "object" then (.answers // null) else null end) as $ans
  | if ($ans | type) == "object"
    then ($ans | to_entries | map({question: .key, chosen: (.value | tostring)}))
    else empty end
' <<<"$input" 2>/dev/null || true)"

# 2) Fallback: parse the rendered string into "Q"="A" pairs.
if [ -z "$pairs" ] || [ "$pairs" = "null" ] || [ "$pairs" = "[]" ]; then
  resp="$(jq -r 'if (.tool_response | type) == "string" then .tool_response else (.tool_response | tostring) end' <<<"$input" 2>/dev/null || true)"
  pairs="$(printf '%s' "$resp" \
    | grep -oE '"[^"]+"="[^"]+"' \
    | jq -R -s -c 'split("\n") | map(select(length > 0))
        | map(capture("\"(?<question>[^\"]*)\"=\"(?<chosen>[^\"]*)\""))' 2>/dev/null || true)"
fi

[ -z "$pairs" ] || [ "$pairs" = "null" ] && exit 0

# One POST per answered question; rejected options resolved from tool_input.
echo "$pairs" | jq -c '.[]?' 2>/dev/null | while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  body="$(jq -cn --argjson pair "$pair" --argjson input "$input" \
    --arg project "$project" --arg sid "$sid" '
    $pair.question as $q
    | ($input.tool_input.questions // [] | map(select(.question == $q)) | .[0].options // []) as $opts
    | {
        question: $q,
        chosen: $pair.chosen,
        rejected: [$opts[] | select(.label != $pair.chosen) | {label, description}],
        project: $project,
        session_id: $sid
      }' 2>/dev/null || true)"
  # Synchronous (not backgrounded): a backgrounded curl can be SIGHUP-killed when
  # the hook process exits. The POST is sub-second and the hook timeout is 6s.
  [ -n "$body" ] && mm_post "/api/memory/decisions" "$body" 3
done

exit 0
