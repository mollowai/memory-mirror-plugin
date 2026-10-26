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
#                                 (default 2), records the answer MARKED
#                                 `attendance_unverified` and says so on stderr:
#                                 a broken guard must not silently drop every
#                                 decision an attended session makes, and a hung
#                                 one must not spend the hook's whole budget. A
#                                 marked decision is never PROPOSED by
#                                 `DecisionRecall`, so it can inform a reader but
#                                 can never be auto-assumed.
#
# Unset, every answer is recorded, as before.
# Set to `true` only when a CONFIGURED guard could not answer. An absent guard
# is not an unverified answer — nobody asked for an attendance check.
attendance_unverified=false

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
      # Still recorded — a broken or slow guard must not silently drop every
      # decision an attended session made. But it is MARKED, because the
      # fail-open leaves a real cost it cannot itself address: an unattended
      # session's auto-selected answer would otherwise enter the operator's
      # decision history as a decision he made, and come back from
      # `recall_decision` as a confident prior that settles a fork he never saw.
      #
      # `DecisionRecall` keeps a marked decision in `past_decisions` (it is real
      # context) and excludes it from the proposal, so it can inform but can
      # never be auto-assumed. Operator ruling 2026-10-26, taken over reversing
      # the fail-open, so both properties hold at once.
      attendance_unverified=true
      echo "memory-mirror: capture guard ${guard} could not decide (exit ${guard_rc}); recording the answer, marked attendance-unverified" >&2
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

# The question-sweep receipt for this session, if one exists. An ASKED question
# reaches Engram through this hook, not through record-sweep-decisions.sh (which
# records the assumed tier only, so one answer is not two votes in
# `DecisionRecall.confidence/2`'s agreement fraction). Without reading it here,
# `axis`, `engram_confidence`, `model_recommendation` and `agreed_with_model`
# would be lost for exactly the questions the operator actually answered — which
# is where `agreed_with_model` is most valuable, since it is what marks an axis
# worth keeping in the battery. Reviewed on PR #7496.
sweep_receipt=""
if [ -n "${sid:-}" ]; then
  case "$sid" in
    *[!A-Za-z0-9_-]*) ;;
    *)
      _root="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$_root" ] || _root="${cwd:-$PWD}"
      [ -f "${_root}/tmp/.question-sweep-${sid}.json" ] &&
        sweep_receipt="${_root}/tmp/.question-sweep-${sid}.json"
      ;;
  esac
fi

# sweep_for <question> — the receipt's sweep fields for that question, or "null".
#
# `has()` rather than `//` throughout: jq treats `false` exactly like absent, so
# `(.agreed_with_model // null)` turns a recorded `false` into `null` — dropping
# precisely the high-value signal (the operator answered AGAINST the model)
# while keeping every `true`. `engram_confidence: 0` would vanish the same way.
sweep_for() {
  [ -n "$sweep_receipt" ] || { printf 'null'; return 0; }
  jq -c --arg q "$1" '
    [(.questions // [])[]? | select(type == "object" and (.question == $q))] | .[0] as $e
    | if $e == null then null
      else {
        axis: (if ($e|has("axis")) then $e.axis else null end),
        tier: (if ($e|has("tier")) then $e.tier else null end),
        engram_confidence: (if ($e|has("engram_confidence")) then $e.engram_confidence else null end),
        model_recommendation: (if ($e|has("model_recommendation")) then $e.model_recommendation else null end),
        agreed_with_model: (if ($e|has("agreed_with_model")) then $e.agreed_with_model else null end),
        round: (if ($e|has("round")) then $e.round else null end)
      } end' -- "$sweep_receipt" 2>/dev/null || printf 'null'
}

# One POST per answered question; rejected options resolved from tool_input.
echo "$pairs" | jq -c '.[]?' 2>/dev/null | while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  sweep="$(sweep_for "$(printf '%s' "$pair" | jq -r '.question' 2>/dev/null)")"
  [ -n "$sweep" ] || sweep="null"

  body="$(jq -cn --argjson pair "$pair" --argjson input "$input" \
    --argjson sweep "$sweep" \
    --arg project "$project" --arg sid "$sid" \
    --arg repo "$repo" --arg path "$path" --arg source_project "$source_project" \
    --argjson attendance_unverified "$attendance_unverified" '
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
    | (if $path == "" and $repo == "" then . else . + {path: $path} end)
    | (if $attendance_unverified then . + {attendance_unverified: true} else . end)
    | (if $sweep == null then . else . + {sweep: $sweep} end)' 2>/dev/null || true)"
  # Synchronous (not backgrounded): a backgrounded curl can be SIGHUP-killed when
  # the hook process exits. The POST is sub-second and the hook timeout is 6s.
  [ -n "$body" ] && mm_post "/api/memory/decisions" "$body" 3
done

exit 0
