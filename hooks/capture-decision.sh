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
engram_proposal=""
if [ -n "${sid:-}" ]; then
  case "$sid" in
    *[!A-Za-z0-9_-]*) ;;
    *)
      _root="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$_root" ] || _root="${cwd:-$PWD}"
      [ -f "${_root}/tmp/.question-sweep-${sid}.json" ] &&
        sweep_receipt="${_root}/tmp/.question-sweep-${sid}.json"
      # The proposal `recall-decisions.sh` stashed for this turn, if any. It is
      # written only when the recall returned a real `proposed_answer`, and
      # cleared at the start of every prompt — so its presence means "Engram had
      # a view on this turn" and its absence means "it did not", never "the file
      # is stale".
      [ -f "${_root}/tmp/.engram-proposal-${sid}.json" ] &&
        engram_proposal="${_root}/tmp/.engram-proposal-${sid}.json"
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
    # LAST match, not first. The receipt is keyed by session and a session can
    # run /ask-first more than once; a second sweep APPENDS its entries, so a
    # repeated question appears twice. Taking .[0] recorded the proposal and
    # confidence from the EARLIER sweep against the answer given to the later
    # one — a prediction made in a different round, at a different confidence,
    # attributed to an answer never given against it. Entries are appended in
    # order, so the last belongs to the sweep currently asking.
    # (No apostrophes in this block: it sits inside a single-quoted jq program.)
    [(.questions // [])[]? | select(type == "object" and (.question == $q))] | .[-1] as $e
    | if $e == null then null
      else {
        axis: (if ($e|has("axis")) then $e.axis else null end),
        engram_proposed: (if ($e|has("engram_proposed")) then $e.engram_proposed else null end),
        tier: (if ($e|has("tier")) then $e.tier else null end),
        engram_confidence: (if ($e|has("engram_confidence")) then $e.engram_confidence else null end),
        model_recommendation: (if ($e|has("model_recommendation")) then $e.model_recommendation else null end),
        agreed_with_model: (if ($e|has("agreed_with_model")) then $e.agreed_with_model else null end),
        round: (if ($e|has("round")) then $e.round else null end)
      } end' -- "$sweep_receipt" 2>/dev/null || printf 'null'
}


# The calibration pair: what Engram proposed for this turn, at what confidence,
# and whether the operator picked it.
#
# This is the only evidence that can ever move `/ask-first`'s auto-assume
# threshold or `DecisionRecall.confidence/2`'s 0.6/0.3/0.1 weights off the
# numbers somebody chose by hand. It was computed on every prompt and discarded.
#
# ONE QUESTION ONLY, and this is the load-bearing restriction. The stash is
# PROMPT-scoped: `recall-decisions.sh` calls recall with the whole user prompt as
# the question, so the proposal answers "what would they pick in a situation like
# this prompt". On a 4-question card it is not question 3's proposal, and
# attaching it to each question would manufacture three agreement facts out of
# one prompt-level guess — the same error as reading `unmapped_top_choice` as an
# answer, committed against the dataset built to detect that error. A
# multi-question card therefore records nothing here, and what is recorded
# carries `engram_scope: "prompt"` so a later reader cannot mistake it for
# per-question calibration.
#
# `engram_proposed_confidence`, not `engram_confidence`: the receipt already uses
# the latter for /ask-first's own PER-QUESTION recall, which is the better
# number. Sharing the key would overwrite it with the weaker one, silently.
# Two further guards, both of which exist because the single-question test above
# bounds the wrong axis. It is INTRA-card; AskUserQuestion is a tool, so the model
# can raise several cards inside one turn with no UserPromptSubmit between them,
# and the stash is cleared per PROMPT. Measured without these: one prompt-level
# proposal produced a legitimate verdict on card 1, a false `true` on an
# unrelated card 2 whose answer label happened to match, and a false `false` on a
# card 3 that did not offer the proposed option at all.
#
#   * THE PROPOSAL MUST BE AMONG THIS CARD'S OWN OPTION LABELS. A proposal the
#     card does not offer can never be chosen, so attaching it records a
#     guaranteed disagreement — which fabricates, with the opposite sign, the
#     exact `unmapped_top_choice` "no usable view" case recall-decisions.sh
#     refuses to stash. A non-matching card does NOT consume the stash, so an
#     unrelated card arriving first cannot swallow a proposal that fits a later
#     one.
#   * IT IS CONSUMED ON READ. Presence then means "this turn's proposal, not yet
#     spent" instead of "this turn had one", so at most one card per turn can
#     carry a verdict.
#
# What survives both: a single card whose option labels coincidentally include a
# proposal about something else — the labels are short ("Yes", "Proceed"), so
# this is ordinary, not exotic. It is irreducible on this rail, because the
# proposal is prompt-scoped by construction. The fix for it is per-question
# recall in the sweep receipt, not a sharper test here.
engram_cal='null'
question_count="$(jq -r '(.tool_input.questions // []) | length' <<<"$input" 2>/dev/null || echo 0)"

# Does the RECEIPT already name a proposal for this card's single question? If
# so the prompt stash is not read at all — not merely ignored. Reading it would
# consume it, and it would then be unavailable to a later card in this turn that
# the receipt does not cover.
# A multiSelect card is skipped entirely, on BOTH rails.
#
# Its answer renders as a comma-joined list of labels ("A, B, C"), measured
# against real transcripts, so comparing one proposed option to `chosen` yields
# a guaranteed `false` even when the proposal was among the things selected. The
# option-membership test does not catch it either: that tests the PROPOSAL's
# membership, and the proposal is a real label.
#
# Skipped rather than scored, because agreement has no defined meaning here —
# "selected alongside three others" is neither the agreement nor the
# disagreement this dataset counts. Greptile P1 on PR #7522.
card_multiselect="$(jq -r '
  ((.tool_input.questions // [])[0].multiSelect // false) | tostring' <<<"$input" 2>/dev/null || echo true)"
case "$card_multiselect" in
  true) question_count=0 ;;
esac

receipt_covers=false
if [ "$question_count" = "1" ] && [ -n "$sweep_receipt" ]; then
  _q1="$(jq -r '(.tool_input.questions // [])[0].question // empty' <<<"$input" 2>/dev/null || true)"
  if [ -n "$_q1" ] &&
    [ "$(printf '%s' "$(sweep_for "$_q1")" | jq -r '(.engram_proposed // "") != ""' 2>/dev/null)" = "true" ]; then
    receipt_covers=true
  fi
fi

case "$question_count" in
  1)
    if [ -n "$engram_proposal" ] && [ "$receipt_covers" = false ]; then
      # Resolved into the card's own option labels, not compared raw. A stored
      # label and a card label for the same choice differ by the
      # "(Recommended)" suffix the model writes into whichever one it
      # recommended that day, so raw equality reports a disagreement for the
      # same answer. `DecisionRecall.map_to_candidate_option/2` is the repo's
      # rule for this and its docstring names this exact pair, so its mapping
      # is reproduced here rather than a second one invented: case-insensitive
      # containment, either direction, first match wins. Recording the RESOLVED
      # label also keeps the dedup key in one stable vocabulary.
      engram_cal="$(jq -c --argjson input "$input" '
        def resolve($p; $labels):
          if (($p // "") == "") then null
          else ($p | ascii_downcase) as $d
            # EXACT first. Containment alone returns the first match in label
            # ORDER, not the best one: with ["Plan", "Plan mode"] and a proposal
            # of "Plan mode", "plan mode" contains "plan", so the earlier and
            # shorter label wins. That is wrong both ways at once — choosing
            # "Plan mode" then reads as a disagreement, choosing "Plan" as an
            # agreement.
            | [$labels[] | select((. | ascii_downcase) == $d)] as $exact
            | if ($exact | length) > 0 then $exact[0]
              else
                # Containment is the suffix case ("(Recommended)"), and it may
                # resolve only when it is UNAMBIGUOUS. Two candidates and no
                # exact match is not resolvable, and guessing one is how the
                # ordering bug above arose.
                [$labels[] | . as $l | ($l | ascii_downcase) as $lo
                 | select(($lo | contains($d)) or ($d | contains($lo)))] as $c
                | if ($c | length) == 1 then $c[0] else null end
              end
          end;
        ($input.tool_input.questions[0].options // [] | map(.label)) as $labels
        | resolve(.option; $labels) as $resolved
        | if $resolved == null then null
          else {
            engram_proposed: $resolved,
            engram_proposed_confidence: (if has("confidence") then .confidence else null end),
            engram_scope: "prompt"
          } end' -- "$engram_proposal" 2>/dev/null || printf 'null')"
      [ -n "$engram_cal" ] || engram_cal='null'
      # Consumed only when it was actually used for this card.
      [ "$engram_cal" = "null" ] || rm -f "$engram_proposal" 2>/dev/null || true
    fi
    ;;
esac

# One POST per answered question; rejected options resolved from tool_input.
echo "$pairs" | jq -c '.[]?' 2>/dev/null | while IFS= read -r pair; do
  [ -z "$pair" ] && continue
  sweep="$(sweep_for "$(printf '%s' "$pair" | jq -r '.question' 2>/dev/null)")"
  [ -n "$sweep" ] || sweep="null"

  body="$(jq -cn --argjson pair "$pair" --argjson input "$input" \
    --argjson sweep "$sweep" --argjson engram_cal "$engram_cal" \
    --arg project "$project" --arg sid "$sid" \
    --arg repo "$repo" --arg path "$path" --arg source_project "$source_project" \
    --argjson attendance_unverified "$attendance_unverified" '
    def resolve($p; $labels):
      if (($p // "") == "") then null
      else ($p | ascii_downcase) as $d
        # EXACT first. Containment alone returns the first match in label
        # ORDER, not the best one: with ["Plan", "Plan mode"] and a proposal
        # of "Plan mode", "plan mode" contains "plan", so the earlier and
        # shorter label wins. That is wrong both ways at once — choosing
        # "Plan mode" then reads as a disagreement, choosing "Plan" as an
        # agreement.
        | [$labels[] | select((. | ascii_downcase) == $d)] as $exact
        | if ($exact | length) > 0 then $exact[0]
          else
            # Containment is the suffix case ("(Recommended)"), and it may
            # resolve only when it is UNAMBIGUOUS. Two candidates and no
            # exact match is not resolvable, and guessing one is how the
            # ordering bug above arose.
            [$labels[] | . as $l | ($l | ascii_downcase) as $lo
             | select(($lo | contains($d)) or ($d | contains($lo)))] as $c
            | if ($c | length) == 1 then $c[0] else null end
          end
      end;
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
    | ($sweep // {}) as $sw
    | ($opts | map(.label)) as $labels
    | (($input.tool_input.questions // [] | map(select(.question == $q)) | .[0].multiSelect) // false) as $multi
    # The PER-QUESTION rail first: the receipt named a proposal for this exact
    # question, so the attribution is a measurement rather than a proxy, and it
    # holds for a card of any size. Resolved into the option labels of THIS
    # question by the same rule as the prompt rail; an entry naming an option
    # the card no longer offers resolves to null and yields no verdict, rather
    # than a guaranteed disagreement.
    # (No apostrophes in this block: it sits inside a single-quoted jq program,
    # where one would close the quote and hand the rest to the shell.)
    | (if $multi then null else resolve($sw.engram_proposed; $labels) end) as $q_resolved
    | (if $q_resolved != null
       then {
         engram_proposed: $q_resolved,
         engram_proposed_confidence:
           (if ($sw|has("engram_confidence")) then $sw.engram_confidence else null end),
         agreed_with_engram: ($q_resolved == $pair.chosen),
         engram_scope: "question"
       }
       elif ($engram_cal != null and ($multi | not))
       then $engram_cal + {agreed_with_engram: ($engram_cal.engram_proposed == $pair.chosen)}
       else {} end) as $cal
    | ($sw + $cal) as $sw2
    | (if ($sw2 | length) == 0 then . else . + {sweep: $sw2} end)' 2>/dev/null || true)"
  # Synchronous (not backgrounded): a backgrounded curl can be SIGHUP-killed when
  # the hook process exits. The POST is sub-second and the hook timeout is 6s.
  [ -n "$body" ] && mm_post "/api/memory/decisions" "$body" 3
done

exit 0
