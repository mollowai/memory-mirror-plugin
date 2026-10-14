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
# The scope dimensions. Empty values are OMITTED rather than sent as "": absent
# has to mean "unknown, predates the dimension" and present has to mean "known",
# or a filter cannot tell them apart. `path` is the case that bites — mm_path_of
# returns "" both AT the repo root (known) and outside a repo (unknown) — so it
# is sent only when a repo was resolved, where "" unambiguously means the root.
#
# `source_project` preserves what the label used to be —
# the directory basename — so redefining `project` to the repo identity stays
# lossless and the original discriminator is never destroyed.
repo="$(mm_repo_of "$cwd")"
path="$(mm_path_of "$cwd")"
source_project="$(basename "${cwd:-.}")"

# 0) Who chose? An answer is only worth recording as "a decision the user just
# made" when a person made it. The plugin cannot know whether anyone is at this
# session's pane, so a host that can tell names a command for it:
#
#   MOLLOW_MEMORY_CAPTURE_GUARD   a command run as `<guard> <cwd>`. A relative
#                                 path resolves against CLAUDE_PROJECT_DIR (else
#                                 the session's cwd). Exit 0 means "nobody chose
#                                 this — do not record it"; exit 1 means record.
#                                 Any other outcome, including a guard that
#                                 cannot be run or does not answer within
#                                 MOLLOW_MEMORY_CAPTURE_GUARD_TIMEOUT seconds
#                                 (default 2), records the answer and says so on
#                                 stderr: a broken guard must not silently drop
#                                 every decision an attended session makes, and a
#                                 hung one must not spend the hook's whole budget.
#
# Unset, every answer is recorded, as before.
guard="${MOLLOW_MEMORY_CAPTURE_GUARD:-}"
if [ -n "$guard" ]; then
  case "$guard" in
    /*) ;;
    *) guard="${CLAUDE_PROJECT_DIR:-${cwd:-.}}/$guard" ;;
  esac
  if [ -x "$guard" ]; then
    # Bounded by hand: macOS ships no `timeout`. The guard runs in the
    # background and is killed on overrun, which reads as 124 — "could not
    # decide" — exactly like any other non-answer.
    guard_limit="${MOLLOW_MEMORY_CAPTURE_GUARD_TIMEOUT:-2}"
    "$guard" "${cwd:-$PWD}" </dev/null >/dev/null 2>&1 &
    guard_pid=$!
    guard_ticks=0
    guard_killed=false
    while kill -0 "$guard_pid" 2>/dev/null; do
      if [ "$guard_ticks" -ge $((guard_limit * 10)) ]; then
        kill -9 "$guard_pid" 2>/dev/null
        guard_killed=true
        break
      fi
      sleep 0.1
      guard_ticks=$((guard_ticks + 1))
    done
    if wait "$guard_pid" 2>/dev/null; then guard_rc=0; else guard_rc=$?; fi
    # Only the kill makes it a timeout. A guard that answered during the last
    # tick answered, and its answer stands (Greptile P2, PR #6985).
    [ "$guard_killed" = true ] && guard_rc=124
  else
    guard_rc=127
  fi
  case "$guard_rc" in
    0)
      echo "memory-mirror: not recording this answer as a decision — ${guard} reports nobody at this session chose it" >&2
      exit 0
      ;;
    1) ;;
    *)
      echo "memory-mirror: capture guard ${guard} could not decide (exit ${guard_rc}); recording the answer" >&2
      ;;
  esac
fi

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
    --arg project "$project" --arg sid "$sid" \
    --arg repo "$repo" --arg path "$path" --arg source_project "$source_project" '
    $pair.question as $q
    | ($input.tool_input.questions // [] | map(select(.question == $q)) | .[0].options // []) as $opts
    | {
        question: $q,
        chosen: $pair.chosen,
        rejected: [$opts[] | select(.label != $pair.chosen) | {label, description}],
        project: $project,
        session_id: $sid,
        source_project: $source_project
      }
    | (if $repo == "" then . else . + {repo: $repo} end)
    | (if $path == "" and $repo == "" then . else . + {path: $path} end)' 2>/dev/null || true)"
  # Synchronous (not backgrounded): a backgrounded curl can be SIGHUP-killed when
  # the hook process exits. The POST is sub-second and the hook timeout is 6s.
  [ -n "$body" ] && mm_post "/api/memory/decisions" "$body" 3
done

exit 0
