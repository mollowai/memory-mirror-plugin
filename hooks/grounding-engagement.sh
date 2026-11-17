#!/usr/bin/env bash
# Stop (fires every turn): score THIS turn's engagement with each grounded
# artifact and post it to POST /api/memory/grounding/engagement, one row per
# artifact, keyed {emission_id, fact_kind, citation_key, turn_ref}.
#
# Reads the receipt grounding-receipt.sh wrote after get_session_context. With
# no receipt this exits 0 before any network call — so a session that never
# hydrated, or hydrated against a server without grounding capture, costs a
# stat() per turn and nothing else.
#
# ── The five signals (operator-approved, Tacit ieSIrEUcEuGF) ────────────────
#   turn_seen          true on every posted row — the denominator.
#   tool_invoked       a skill's step tool ran this turn. EXACT: the tool_use
#                      name equals a step tool, or equals it once the
#                      `mcp__<server>__` prefix is stripped.
#   edit_count         Edit/Write/MultiEdit/NotebookEdit calls this turn
#                      (turn-level, the same on every row).
#   term_match         LOOSE: one of the artifact's terms appears as a whole
#                      token in this turn's assistant text or tool inputs,
#                      tokenized the way the server derived the terms
#                      (lowercase, split on [^a-z0-9_]+).
#   decision_recorded  this turn called a `*__record_decision` tool or
#                      AskUserQuestion (which capture-decision.sh records as a
#                      decision). Turn-level.
# Only booleans and a count leave this machine — never transcript text, the
# same privacy posture as supply-stop.sh's used_fact_ids.
#
# ── Windows: which bytes are "this turn" ────────────────────────────────────
# The receipt carries `offset` (end of what was last scored) and the current
# turn's `turn_ref` (Claude Code's prompt_id) with its `turn_start`. A Stop
# whose prompt_id equals turn_ref re-scores from turn_start — that is a stop-
# hook continuation of the same turn, or the grounding turn itself, whose
# turn_start is where the grounding arrived — and the server's upsert replaces
# the row with the fuller turn. Any other prompt_id is a new turn and starts at
# offset. Either way offset advances to the end of the transcript.
#
# ── Latency ──────────────────────────────────────────────────────────────────
# Up to 200 artifacts means up to 200 posts per turn, which cannot fit a Stop
# budget serially. The posts run in a detached background job, 8 at a time, each
# capped at 3s; the hook itself returns as soon as the receipt is updated.
# MOLLOW_GROUNDING_ENGAGEMENT_SYNC=1 runs them in the foreground (the tests).
#
# Opt-out: MOLLOW_GROUNDING_ENGAGEMENT=0 (or off/false/no).

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

case "$(printf '%s' "${MOLLOW_GROUNDING_ENGAGEMENT:-}" | tr '[:upper:]' '[:lower:]')" in
  0 | off | false | no) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
mm_safe_component "$session_id" || exit 0

receipt_root="${TMPDIR:-/tmp}/mollow-grounding"
receipt_dir="${receipt_root}/${session_id}"
receipt_file="$receipt_dir/receipt.json"
[ -f "$receipt_file" ] || exit 0
# Read and write only beneath directories this user owns (mm_private_dir): a
# receipt planted by another local user would otherwise be posted under this
# user's key, and a swapped directory would take this hook's writes.
mm_private_dir "$receipt_root" || exit 0
mm_private_dir "$receipt_dir" || exit 0
[ ! -L "$receipt_file" ] && [ -O "$receipt_file" ] || exit 0
receipt="$(cat "$receipt_file" 2>/dev/null || true)"
[ -n "$receipt" ] || exit 0

transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
[ -n "$transcript_path" ] && [ -f "$transcript_path" ] || exit 0
prompt_id="$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null || true)"

read_num() {
  local v
  v="$(printf '%s' "$receipt" | jq -r "$1 // 0 | tostring" 2>/dev/null || echo 0)"
  case "$v" in '' | *[!0-9]*) v=0 ;; esac
  printf '%s' "$v"
}
offset="$(read_num .offset)"
turn_start="$(read_num .turn_start)"
stored_ref="$(printf '%s' "$receipt" | jq -r '.turn_ref // empty' 2>/dev/null || true)"

size="$(wc -c <"$transcript_path" 2>/dev/null | tr -d ' ')"
case "$size" in '' | *[!0-9]*) exit 0 ;; esac

if [ -n "$prompt_id" ] && [ "$prompt_id" = "$stored_ref" ]; then
  start="$turn_start"
  turn_ref="$prompt_id"
else
  start="$offset"
  turn_ref="${prompt_id:-off-${offset}}"
fi
# A transcript shorter than the recorded offset is a different file than the one
# the offset was measured against; score it from the beginning.
[ "$start" -le "$size" ] || start=0

# Advance the receipt before any network work, so the next turn's window starts
# here whether or not the posts land.
tmp="$(mktemp "$receipt_dir/.receipt.XXXXXX" 2>/dev/null)" || exit 0
printf '%s' "$receipt" | jq -c --argjson off "$size" --arg ref "$turn_ref" --argjson ts "$start" \
  '. + {offset: $off, turn_ref: $ref, turn_start: $ts}' >"$tmp" 2>/dev/null &&
  mv -f "$tmp" "$receipt_file" 2>/dev/null
rm -f "$tmp" 2>/dev/null || true

[ "$start" -lt "$size" ] || exit 0

emission_id="$(printf '%s' "$receipt" | jq -r '.emission_id // empty' 2>/dev/null || true)"
mm_safe_component "$emission_id" || exit 0
mm_safe_component "$turn_ref" || exit 0

# One JSON payload per artifact, one per line.
payloads="$(tail -c +$((start + 1)) "$transcript_path" 2>/dev/null | jq -Rcn \
  --slurpfile r "$receipt_file" --arg turn_ref "$turn_ref" '
  $r[0] as $receipt
  | [ inputs | fromjson? | objects
    | select((.isSidechain? // false) | not)
    | select((.type? // "") == "assistant")
    | (.message.content? // [])
    | if type == "array" then .[] | select(type == "object") else empty end ] as $blocks
  | [ $blocks[] | select((.type? // "") == "tool_use") ] as $uses
  | if ($blocks | length) == 0 then empty else
      ($uses | map(.name? // "" | tostring)) as $names
      | ($names | map(sub("^mcp__.*?__"; ""))) as $short
      # A synthesized skill stores its step tool as `server.tool`
      # (Engram.StepSynthesizer.to_step/1); the transcript names the same call
      # `mcp__server__tool`. Compare in that dotted form too.
      | ($names | map(if startswith("mcp__")
                      then ((.[5:] | split("__")) as $p
                            | if ($p | length) >= 2 then $p[0] + "." + ($p[1:] | join("__")) else . end)
                      else . end)) as $dotted
      | ([ $names[] | select(. == "Edit" or . == "Write" or . == "MultiEdit" or . == "NotebookEdit") ] | length) as $edits
      | (any($names[]; test("__record_decision$") or . == "AskUserQuestion")) as $decided
      | ( [ ($blocks[] | select((.type? // "") == "text") | (.text? // "")),
            ($uses[] | (.input? // {}) | tostring) ]
          | join(" ") | ascii_downcase
          | [ splits("[^a-z0-9_]+") | select(length > 0) ]
          | map({key: ., value: true}) | from_entries ) as $tokens
      | $receipt.artifacts[]?
      | . as $a
      | { emission_id: $receipt.emission_id,
          fact_kind: $a.kind,
          citation_key: $a.ref,
          turn_ref: $turn_ref,
          signals: {
            turn_seen: true,
            tool_invoked: any(($a.tools // [])[]; . as $t
                              | ($names | index($t)) != null or ($dotted | index($t)) != null
                              or ($short | index($t)) != null),
            edit_count: $edits,
            term_match: any(($a.terms // [])[]; $tokens[.] == true),
            decision_recorded: $decided
          } }
    end
  ' 2>/dev/null || true)"

[ -n "$payloads" ] || exit 0
mm_ready || exit 0

# ── Ordering: the newest window for a turn is the one that lands ────────────
# A stop-hook continuation re-scores the same turn_ref, and the server's upsert
# keeps whichever post arrives LAST. Two independent background batches could
# land out of order and replace the fuller window with the partial one
# (Greptile, PR #8370). So every batch takes a per-session lock, and a batch
# that finds a newer batch registered for its turn posts nothing — the newer
# window covers the whole turn, because it re-scores from turn_start.
# Stop hooks for one session run one at a time, so the counter below is bumped
# without a race; only the posting runs concurrently.
seq_file="$receipt_dir/seq"
seq="$(cat "$seq_file" 2>/dev/null || echo 0)"
case "$seq" in '' | *[!0-9]*) seq=0 ;; esac
seq=$((seq + 1))
write_private() { # <file> <content> — non-zero when the write did not land
  local t rc=0
  t="$(mktemp "$receipt_dir/.w.XXXXXX" 2>/dev/null)" || return 1
  { printf '%s' "$2" >"$t" && mv -f "$t" "$1"; } 2>/dev/null || rc=1
  rm -f "$t" 2>/dev/null || true
  return "$rc"
}
write_private "$seq_file" "$seq" || exit 0
latest_file="$receipt_dir/latest-${turn_ref}"
write_private "$latest_file" "$seq" || exit 0
lock_dir="$receipt_dir/post.lock"

post_all() {
  local n=0 line waited=0
  # Wait for the lock; a holder that has had 90s is past its own worst case
  # (200 posts, 8 at a time, 3s each = 75s) and is treated as gone.
  until mkdir "$lock_dir" 2>/dev/null; do
    if [ "$waited" -ge 450 ]; then
      rmdir "$lock_dir" 2>/dev/null || true
      waited=0
      continue
    fi
    sleep 0.2
    waited=$((waited + 1))
  done
  if [ "$(cat "$latest_file" 2>/dev/null)" != "$seq" ]; then
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mm_post "/api/memory/grounding/engagement" "$line" 3 &
    n=$((n + 1))
    if [ $((n % 8)) -eq 0 ]; then wait; fi
  done
  wait
  [ "$(cat "$latest_file" 2>/dev/null)" = "$seq" ] && rm -f "$latest_file" 2>/dev/null
  rmdir "$lock_dir" 2>/dev/null || true
}

if mm_truthy "${MOLLOW_GROUNDING_ENGAGEMENT_SYNC:-}"; then
  printf '%s\n' "$payloads" | post_all
else
  (printf '%s\n' "$payloads" | post_all) </dev/null >/dev/null 2>&1 &
  disown 2>/dev/null || true
fi
exit 0
