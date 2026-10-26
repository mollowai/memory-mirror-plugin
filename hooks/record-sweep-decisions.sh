#!/usr/bin/env bash
# record-sweep-decisions.sh — turn a completed question sweep into decision
# memory, mechanically, at the end of the session.
#
# ## Why this is a hook and not an instruction
#
# `/ask-first` Phase 7 asks the model to call `record_decision` for every
# assumption the operator confirmed or corrected. That is the one step the whole
# learning loop depends on, and it was the step most likely to be skipped: the
# skill itself records that the closing confirm question is NOT captured by
# `capture-decision.sh`, so without a voluntary call the confident priors never
# gain corroboration and the wrong ones never gain counterweight. An instruction
# that is skipped silently is indistinguishable from a sweep that had nothing to
# record.
#
# The receipt already holds the authoritative list — Phase 7 writes it for the
# ExitPlanMode gate — so this reads that file instead of asking the model to
# remember. Deterministic, and it runs even when the session ends abruptly.
#
# ## What it records: the ASSUMED tier only
#
# One decision per receipt entry whose `tier` is `assumed`, carrying both a
# question and a chosen answer, each with the sweep signal in `sweep`:
#
#     {axis, tier: asked|assumed, engram_confidence, model_recommendation,
#      agreed_with_model, round}
#
# `asked` entries are deliberately excluded. They went out through
# `AskUserQuestion`, which `capture-decision.sh` already records on
# PostToolUse — so recording them here makes ONE answer two rows. They would not
# even dedup: this recorder writes its own `rationale`, so the content hash
# differs from the hook's and the private path lets both through; the Space path
# has no dedup at all. Two rows for one answer are two votes in
# `DecisionRecall.confidence/2`'s agreement fraction, which raises confidence
# with no new evidence — the exact inflation this whole branch guards against
# elsewhere. The assumed tier is the gap that needed closing: the skill's own
# text records that the Phase 6 confirm is NOT captured by `capture-decision.sh`.
#
# Nothing reads that signal yet, by design. It has to accumulate before "which
# axes earn their place in the battery" or "where should the assume threshold
# sit" can be answered from evidence rather than from a guess — and the
# threshold is deliberately an operator dial (`scripts/ask-first-threshold.sh`)
# precisely because there is no evidence behind it yet. Recording is the
# prerequisite, and it is the half that never shipped: `agreed_with_model` and
# `engram_confidence` existed only in two prose files.
#
# ## Fail-open, and resumable per ENTRY
#
# No receipt, no jq, no credentials, malformed JSON: exit 0 silently.
#
# The `.recorded` sibling records which entries have been posted, one key per
# line, appended only AFTER each successful post. It used to be a single marker
# claimed before the loop, which lost data: the hook has a 6s budget and each
# request is bounded at 3s, so a twenty-entry receipt can run out of time even
# when every request is fast — and because the marker was already written, every
# later `Stop` skipped the remaining entries forever.
#
# Per-entry keys fix both directions at once. An entry already recorded is never
# posted twice (which matters because the Space write path has no dedup at all —
# MOL-4692), and an entry not yet recorded is still pending, so the next `Stop`
# finishes the job. The loop also stops itself before the hook budget rather
# than being killed mid-write.

set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_common.sh
source "${DIR}/_common.sh" 2>/dev/null || exit 0

mm_ready || exit 0
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat 2>/dev/null || true)"
[ -n "$input" ] || exit 0

sid="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
[ -n "$sid" ] || exit 0
[ -n "$cwd" ] || cwd="$PWD"

# Only [A-Za-z0-9_-]; the id is interpolated into a path below.
case "$sid" in
  "" | *[!A-Za-z0-9_-]*) exit 0 ;;
esac

# The receipt is anchored at the repository root, matching where the
# ExitPlanMode gate resolves it from.
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="${cwd%/}"

receipt="${root}/tmp/.question-sweep-${sid}.json"
[ -f "$receipt" ] || exit 0

# A LEDGER of posted entries, one key per line, appended after each success.
ledger="${receipt}.recorded"
mkdir -p "$(dirname "$ledger")" 2>/dev/null || exit 0
touch "$ledger" 2>/dev/null || exit 0

# entry_key <entry-json> — stable per (question, chosen), so the ledger survives
# a receipt rewrite that reorders entries.
entry_key() {
  printf '%s' "$1" \
    | jq -r '[(.question // ""), ((.chosen // .answer) // "")] | @tsv' 2>/dev/null \
    | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null || cksum; } \
    | cut -c1-24 | tr -cd 'A-Za-z0-9'
}

# Stop before the hook budget rather than being killed mid-write: an entry
# posted but not yet in the ledger would be re-posted next time, and on the
# Space path that appends a duplicate.
deadline=$(( $(date +%s) + ${MM_SWEEP_RECORD_BUDGET_S:-5} ))

project="$(mm_project_of "$cwd")"
repo="$(mm_repo_of "$cwd")"

# One compact line per recordable entry.
entries="$(jq -c '
  (.questions // [])
  | if type != "array" then [] else . end
  | map(select(type == "object"))
  | map(select((.question // "") != "" and (.chosen // .answer // "") != ""))
  # assumed ONLY: an `asked` entry already reached Engram through
  # AskUserQuestion -> capture-decision.sh, and recording it again makes one
  # answer two votes in the agreement fraction.
  | map(select(.tier == "assumed"))
  | .[]
' -- "$receipt" 2>/dev/null || true)"

[ -n "$entries" ] || exit 0

while IFS= read -r entry <&3; do
  [ -n "$entry" ] || continue

  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "memory-mirror: sweep recorder out of budget; $(( $(printf '%s\n' "$entries" | grep -c . ) )) entry(ies) in this receipt, remainder left for the next Stop" >&2
    break
  fi

  key="$(entry_key "$entry")"
  if [ -n "$key" ] && grep -qxF "$key" "$ledger" 2>/dev/null; then
    continue
  fi

  body="$(jq -cn --argjson e "$entry" --arg project "$project" --arg repo "$repo" '
    {
      question: $e.question,
      chosen: ($e.chosen // $e.answer),
      rationale: "Settled in an up-front question sweep (/ask-first).",
      # `//` is NOT usable here. jq treats `false` and `null` alike as the
      # left-hand side being absent, so `($e.agreed_with_model // null)` turns a
      # recorded `false` into `null` — losing precisely the high-value signal
      # (the operator answered AGAINST the model) while keeping every `true`.
      # `engram_confidence: 0` would vanish the same way. Same family as
      # `false && true` in shell: a falsey value read as missing.
      sweep: {
        axis: (if ($e | has("axis")) then $e.axis else null end),
        tier: (if ($e | has("tier")) then $e.tier else null end),
        engram_confidence: (if ($e | has("engram_confidence")) then $e.engram_confidence else null end),
        model_recommendation: (if ($e | has("model_recommendation")) then $e.model_recommendation else null end),
        agreed_with_model: (if ($e | has("agreed_with_model")) then $e.agreed_with_model else null end),
        round: (if ($e | has("round")) then $e.round else null end)
      }
    }
    | (if $project == "" then . else . + {project: $project} end)
    | (if $repo == "" then . else . + {repo: $repo} end)
  ' 2>/dev/null || true)"

  # `mm_post_ok`, NOT `mm_post`. `mm_post` ends in `|| true` and so returns 0
  # after a timeout or an HTTP 4xx/5xx — gating the ledger on it marked entries
  # saved that the server never accepted, and the ledger then stopped any later
  # `Stop` from retrying them. `mm_post_ok` uses curl `-f` and returns its real
  # status; its own comment in _common.sh says it exists for exactly this, to
  # gate follow-up state on successful delivery.
  if [ -n "$body" ] && mm_post_ok "/api/memory/decisions" "$body" 3; then
    # Appended only after a CONFIRMED delivery. A key written before, or on a
    # swallowed failure, loses the entry permanently.
    [ -n "$key" ] && printf '%s\n' "$key" >>"$ledger" 2>/dev/null
  fi
done 3<<EOF
$entries
EOF

exit 0
