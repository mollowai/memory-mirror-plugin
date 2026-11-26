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
sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
project="$(mm_project_of "$cwd")"

# The proposal stash this turn may write, resolved and CLEARED before anything
# can exit early.
#
# Clearing up front is the load-bearing half. The write below is reached only on
# the happy path — an empty prompt, a malformed body and a recall timeout all
# exit before it — so a turn that produces no proposal would otherwise leave the
# PREVIOUS turn's proposal on disk, and the card raised in this turn would read
# it as a proposal about its own question. That is silent false attribution: the
# file is well-formed, fresh-looking, and about a different prompt. So absence
# is established first and presence is earned per turn.
stash_file=""
if [ -n "${sid:-}" ]; then
  case "$sid" in
    *[!A-Za-z0-9_-]*) ;;
    *)
      _root="$(git -C "${cwd:-$PWD}" rev-parse --show-toplevel 2>/dev/null || true)"
      [ -n "$_root" ] || _root="${cwd:-$PWD}"
      stash_file="${_root}/tmp/.engram-proposal-${sid}.json"
      rm -f "$stash_file" 2>/dev/null || true
      ;;
  esac
fi

[ -z "$prompt" ] && exit 0

body="$(jq -cn --arg q "$prompt" --arg p "$project" '{question: $q, project: $p, limit: 3}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Hard 2s cap; empty output on timeout/failure keeps the turn snappy.
#
# MOL-8256: read the STATUS, not just the body. This hook used to call
# `mm_post_read`, which returns the body alone — so a 403 from a wrong-scoped
# key, a 500, and a 2s timeout were ONE indistinguishable empty string, and all
# three exited 0 with no output. From inside the session that is identical to
# "recall ran and matched nothing", which is the whole defect: a turn that lost
# its memory cannot say so, and will re-derive a decision already settled.
raw="$(mm_post_read_status "/api/memory/decisions/recall" "$body" 2)"
status="$(mm_seam_split_status "$raw")"
resp="$(mm_seam_split_body "$raw")"

# A DEFINITE error is said once, in context. Same split supply-ground.sh has
# used since MOL-5978, and the same channel: additionalContext is the only one
# this hook has that reaches a person, and it exits immediately after.
#
# Deliberately ONE line naming the code, not grounding's per-status advice tree.
# That tree exists because its statuses need OPPOSITE operator actions (a
# workspace id versus a key versus the edge). Recall has no such split to make,
# and inventing per-status prose here would be advice with nothing behind it.
if mm_definite_http_failure "$status"; then
  mm_emit_context "UserPromptSubmit" \
    "Mollow memory: the decision-recall request was refused (HTTP ${status}), so this turn carries no recalled decisions. That is a failure to reach memory, NOT a memory with nothing in it — do not read the absence as 'nothing was decided before'."
  # Recorded too (MOL-9571), under its own reason, so the ledger accounts for
  # every call. Never as `recall_unreachable`: it was SAID above, and the
  # close's unreachable count is for the silent misses only.
  mm_supply_note "recall_refused:http${status}" "${sid:--}" "-" "$(mm_seam_split_detail "$raw")"
  exit 0
fi

# A TRANSIENT miss (000, or a 200 whose body never arrived) stays OUT of
# context, on the operator's call of 2026-11-17: a line on every slow turn is
# its own defect, which is why `mm_grounding_status_hint` already keeps `000`
# quiet. It is recorded instead, so the close can report that N prompts this
# session went ungrounded — visible where it is acted on rather than in front of
# every prompt.
#
# Recorded ONLY here, never on the 200-with-no-decisions path below. Those two
# produce the same absent injection, and conflating them would make the record
# say "unreachable" about a working rail that had nothing to offer.
#
# MOL-9571: the record now says WHICH miss it was — `recall_unreachable:timeout`
# against `:dns`, `:refused`, `:timeout_mid_body` — with curl's exit code, the
# HTTP code it saw and the elapsed seconds beside it, because tuning the 2s cap
# on 1,213 indistinguishable records was a guess. A streak of them becomes one
# line in context (`mm_rail_outcome`), never one per miss.
if [ -z "$resp" ]; then
  mm_rail_outcome recall "${sid:-}" UserPromptSubmit unreachable "$raw"
  exit 0
fi
# Which legs of the answer are MISSING, as the server itself reported them
# (MOL-9707). `:contradictions` runs under its own deadline and, when it
# expires, the response carries `contradictions: []` with
# `degraded: ["contradictions"]` — `[]` because nothing was computed, not
# because nothing was found. Measured at ~249 a day in production, on the hook
# that fires on every prompt of every session.
#
# Read here, before anything renders or records, because both of those were
# wrong without it: the turn was told there were no contradictions, and the call
# was written to the ledger as a clean success.
#
# Absent, `null` and `[]` all yield the empty string, so an older server and
# every undegraded response take exactly the path they took before.
# A `degraded` that is PRESENT but not a list of leg names is reported as
# `unknown_shape` rather than as nothing. `[]` for a non-array would restore
# this exact defect silently — the server could ship a map of leg → reason and
# the hook would go back to recording `recall_ok` on a half-answer — so an
# unreadable field is counted as a miss whose legs are unknown, and no notice is
# rendered, because which lookup is missing cannot be read from it.
degraded_legs="$(printf '%s' "$resp" | jq -r '
  (.degraded // [])
  | if type != "array" then "unknown_shape"
    else
      [ .[] | select(type == "string" and . != "") ] as $legs
      | if ($legs | length) > 0 then ($legs | join(","))
        elif (length) > 0 then "unknown_shape"
        else "" end
    end
  ' 2>/dev/null || true)"

# Not a bare success: `mm_rail_outcome` downgrades a body that is not a JSON
# object to `recall_unreachable:unparseable`, and the jq reads below then find
# nothing and exit silently — the same silence, now on the record.
#
# A degraded response is recorded as `recall_degraded:<legs>` rather than as
# `recall_ok`. It is a partial answer, and MOL-9571's ledger exists to count
# memory-rail misses: logging a dropped lookup as a success makes the one
# instrument that should detect this class of failure report it as healthy. It
# is not `unreachable` either — see `mm_rail_outcome` for why that would be a
# different claim about a working rail.
if [ -n "$degraded_legs" ]; then
  mm_rail_outcome recall "${sid:-}" UserPromptSubmit degraded "$raw" "$degraded_legs"
else
  mm_rail_outcome recall "${sid:-}" UserPromptSubmit ok "$raw"
fi

# Whether the contradiction lookup is one of the missing legs. Matched as a
# whole element — the join is comma-separated, so the commas on both ends are
# what stop a future `contradictions_v2` from reading as this one.
contradictions_skipped=false
case ",${degraded_legs}," in
  *,contradictions,*) contradictions_skipped=true ;;
esac

# Seen-state (MOL-3755). A finding stays the top-ranked result for as long as the
# conversation is about it, so without this the same warning is injected into
# EVERY turn. Keyed by env so a fleet-target switch re-surfaces once, matching
# import-local-memories.sh. Per-machine by design: this is "seen here", not
# "dismissed" — acceptable for an advisory, and one reason this never blocks.
#
# Dedupe on `.key` (the unordered claim pair), NEVER on `.id`. The nightly sweep
# re-detects the same contradiction and writes a fresh row with a fresh id each
# run — 6,130 rows over 1,289 pairs across 46 runs on production — so an id key
# would make "seen" last exactly one night.
seen_file="${HOME}/.mollow/contradiction-seen.json"
seen_key="$(mm_env_label)"
seen_ids='[]'
if [ -f "$seen_file" ]; then
  seen_ids="$(jq -c --arg k "$seen_key" '.[$k] // []' "$seen_file" 2>/dev/null || echo '[]')"
fi

# Drop anything already shown, before rendering or recording.
#
# This read is NOT under the write lock, so two hooks that start together can both
# see the finding as unseen and both show it once. That is deliberate, not an
# oversight. Closing it means claiming the key before rendering — and then a hook
# that dies between claiming and emitting marks a contradiction seen that the user
# never saw, suppressing it forever. For an advisory that never blocks, showing it
# twice across two simultaneous sessions is the benign failure and silently
# swallowing it is the harmful one, so the race is left open in that direction.
resp="$(printf '%s' "$resp" | jq -c --argjson seen "$seen_ids" '
  if (.contradictions | type) == "array" then
    .contradictions |= map(select((.key // "") as $k | $k != "" and (($seen | index($k)) | not)))
  else . end' 2>/dev/null || printf '%s' "$resp")"

# Two independent blocks: past decisions (MOL-2334) and any contradiction the
# nightly sweep already judged (MOL-3755). Either may be absent; jq emits only
# what is present, and a malformed response yields empty output.
ctx="$(printf '%s' "$resp" | jq -r --argjson cskipped "$contradictions_skipped" '
  [
    ( .proposed_answer as $p
      | if $p == null then empty
        else
          "Engram proposes \"" + ($p.option // "?") + "\" here"
          + (if $p.confidence then " (confidence " + ($p.confidence | tostring) else " (" end)
          + (if (.count // 0) > 1 then ", from " + ((.count) | tostring) + " similar past decisions)"
             elif (.count // 0) == 1 then ", from 1 similar past decision)"
             else ")" end)
          + ". That is the historical preference on record, not a settled answer. If your own"
          + " reading of this request disagrees with it, say so and show BOTH voices rather than"
          + " collapsing them: a surfaced disagreement is worth more than a single recommendation."
        end ),
    ( .unmapped_top_choice as $u
      | if ($u == null or $u == "") then empty
        else
          "Engram found a nearby past decision, \"" + $u + "\", but it maps onto none of the"
          + " options here, so it is NOT an answer to this question and carries no"
          + " recommendation. It is a decision about a different question; treat Engram as"
          + " having no usable view."
        end ),
    ( (.past_decisions // []) as $ds
      | if ($ds | length) == 0 then empty
        else
          "Relevant past decisions for this request:\n"
          + ([ $ds[]
                | "- " + (.question // "decision") + " -> chose " + (.chosen // "?")
                  + (if .rationale then " (" + .rationale + ")" else "" end) ]
             | join("\n"))
        end ),
    ( (.contradictions // []) as $cs
      | if ($cs | length) > 0 then
          "Possible contradiction in the memory this touches — surfaced for awareness, not a blocker. Both sides may be legitimate (a changed mind reads the same as an error). Mention it only if it bears on the request:\n"
          + ([ $cs[] | "- " + (.rationale // "") ] | join("\n"))
        elif $cskipped then
          # Findings present outrank the skip notice: the server sends `[]` with
          # this leg degraded, so the two cannot both be true — and if they ever
          # are, dropping real findings to report a skip is the worse failure.
          # Says WHAT happened and not WHY. `degraded` is reported for a leg
          # that missed its deadline AND for one that raised — a failed query
          # reaches the response the same way — and the body does not say
          # which. Naming a timeout here would point the reader at one of two
          # causes on evidence that cannot distinguish them (Greptile P2 on
          # #8788). NO APOSTROPHE IN THIS COMMENT: the jq program is shell
          # single-quoted, so one would end the quote and the program with it —
          # which fails as 11 unrelated assertions, not as a syntax error.
          "Contradiction check DID NOT COMPLETE on this turn: the server reported this lookup as"
          + " degraded, so it returned no usable result; the response does not say why. Nothing was"
          + " checked, so this is a MISSING result and not an empty one. Do not read it as \"there"
          + " are no contradictions\" — memory may hold one that bears on this request, and nothing"
          + " looked. If a contradiction would change the answer here, say the check did not run"
          + " rather than treating the memory as clean."
        else empty
        end )
  ] | join("\n\n")
  ' 2>/dev/null || true)"

mm_emit_context "UserPromptSubmit" "$ctx"

# Record what was actually shown. Best-effort and last: a failure here must never
# cost the turn its context. `mm_seen_add` takes a lock, retries briefly under a
# bounded budget, and caps the file — many sessions run on one machine, so these
# writes genuinely overlap, and a one-shot attempt dropped keys. See its comment
# in _common.sh for what the budget buys and what it does not.
shown="$(printf '%s' "$resp" | jq -c '[(.contradictions // [])[] | .key // empty]' 2>/dev/null || echo '[]')"
if [ "$shown" != "[]" ] && [ -n "$ctx" ]; then
  mm_seen_add "$seen_file" "$seen_key" "$shown" || true
fi

# Stash the proposal for answer time (MOL-7985 follow-on).
#
# This is the only calibration signal we have — "when Engram proposed X at
# confidence C, did the operator pick X?" — and it was computed on every prompt
# and discarded. `capture-decision.sh` is where the answer arrives, and it
# cannot recall for itself: it runs on PostToolUse inside a 6s budget, and the
# recall for this turn already happened here.
#
# Written ONLY when a proposal exists. An `unmapped_top_choice` is deliberately
# not stashed: the server separates those two cases on purpose, and stashing a
# nearest-neighbour as a proposal would manufacture agreement data about a
# question Engram had no view on.
#
# The proposal is PROMPT-scoped, not per-question — `recall` is called with the
# whole prompt as the question. The reader is responsible for not presenting it
# as a per-question verdict; it records `engram_scope: "prompt"` so the
# limitation travels with the data rather than living in a comment here.
if [ -n "$stash_file" ]; then
  _proposal="$(printf '%s' "$resp" | jq -c '
    .proposed_answer as $p
    | if ($p == null or ($p.option // "") == "") then empty
      else {
        option: $p.option,
        confidence: (if ($p|has("confidence")) then $p.confidence else null end),
        count: (if has("count") then .count else null end)
      } end' 2>/dev/null || true)"
  if [ -n "$_proposal" ]; then
    mkdir -p "$(dirname "$stash_file")" 2>/dev/null &&
      printf '%s\n' "$_proposal" >"$stash_file" 2>/dev/null || true
  fi
fi
exit 0
