#!/usr/bin/env bash
# Stop: supply mode outcome post-back (MOL-5857, Phase 3).
#
# The TRIGGER for the outcome post-back, not a transcript parser. The receipt
# supply-ground.sh wrote at UserPromptSubmit already holds what was supplied
# (grounding_id + each fact's message_hash), so the post-back needs nothing
# parsed out of the transcript. POSTs POST /seam/v1/outcome for each pending
# receipt of the session that just stopped.
#
# The one thing that DOES need the transcript is `used_fact_ids`: the answer text
# is read here, locally, only to decide which supplied facts were cited. Only the
# matched message_hash list leaves for Mollow — never the answer text. If the
# answer can't be read or matched reliably, the post-back goes WITHOUT
# used_fact_ids (the field is optional precisely so a weak signal is omitted, not
# faked).
#
# ── Blast radius / posture ───────────────────────────────────────────────────
# Loads into every Claude Code session. Opt-in guard first; fail-open, silent;
# exits 0 on every path.
#
# Stop fires on EVERY natural stop, not once per session, so this correlates
# per-TURN: it wants the re-entrancy guard (a stop-hook-triggered stop must not
# loop) but explicitly NOT the once-per-session marker sync-session.sh uses — an
# easy thing to copy wrong.

# Strict mode: -u (unset vars error) and pipefail ON; -e deliberately OFF — a
# non-zero command mid-hook must not abort before the closing `exit 0`, which is
# the fail-open contract (matches recall-decisions.sh; _common.sh sets the same).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

# Opt-in guard FIRST.
mm_supply_enabled || exit 0

input="$(cat)"

# Re-entrancy guard: a Stop hook re-fires after Claude responds to it. If this
# stop was itself triggered by a stop hook, end instead of looping. (No
# once-per-session marker — every turn's supply must be posted back.)
if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)" = "true" ]; then
  exit 0
fi

mm_ready || exit 0

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"

# No safely-pathable session id ⇒ no receipts to find. mm_safe_component rejects
# `.`/`..`/`..`-sequences too, so the receipt dir can never resolve up a level.
mm_safe_component "$session_id" || exit 0

receipt_dir="${TMPDIR:-/tmp}/mollow-supply/${session_id}"
[ -d "$receipt_dir" ] || exit 0

# Pending receipts for this session, NEWEST FIRST. Normally exactly one — this
# turn. More than one means an earlier turn's Stop hook did not fire and left a
# receipt behind. A stale receipt must NOT be attributed to this turn: its facts
# were never in this turn's context, and its latency would span multiple turns
# (Greptile, PR #6160). So only the newest is correlated with this turn's answer
# and posted; the rest are discarded, not matched against the wrong answer.
shopt -s nullglob
receipts=()
while IFS= read -r f; do receipts+=("$f"); done < <(ls -t "$receipt_dir"/*.json 2>/dev/null)
shopt -u nullglob
[ "${#receipts[@]}" -gt 0 ] || exit 0

# ── Answer text of the just-completed turn (for used_fact_ids only) ──────────
# The last assistant message. Handle BOTH shapes the transcript permits: content
# as a bare string, and content as an array of blocks. `map` (or `.content[]`)
# over a string is a hard jq error that would abort and silently disable the
# reader — so the type is checked before iterating. Bounded to the tail; the last
# assistant message is near the end of the JSONL. Any failure ⇒ empty answer ⇒
# post back without used_fact_ids.
answer=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  answer="$(tail -n 500 "$transcript_path" 2>/dev/null | jq -rs '
    [ .[] | select((.type? // .role? // "") == "assistant") ] as $msgs
    | if ($msgs | length) == 0 then ""
      else
        ($msgs | last) as $m
        | ($m.message.content // $m.content // "") as $c
        | if ($c | type) == "string" then $c
          elif ($c | type) == "array" then
            [ $c[]? | select((.type? // "") == "text") | (.text? // "") ] | join("\n")
          else "" end
      end
    ' 2>/dev/null || true)"
fi

# used_fact_ids matcher: conservative by design (precision over recall). A fact
# counts as cited only if an 8-word verbatim run of its content appears in the
# answer — strong evidence of actual use, and it never fires on paraphrase, so it
# undercounts rather than over-claims. Short facts (<8 words) must appear whole.
# Emits the message_hash list. Output "[]" on any trouble.
match_used() {
  local receipt="$1" ans="$2"
  printf '%s' "$receipt" | jq -c --arg answer "$ans" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    ($answer | norm) as $a
    | [ .facts[]?
        | .message_hash as $mh
        | ((.content // "") | norm | split(" ") | map(select(length > 0))) as $w
        | ($w | length) as $n
        | if ($mh == null) or ($n == 0) then empty
          elif $n < 8 then
            (if $a | contains($w | join(" ")) then $mh else empty end)
          else
            ([ range(0; $n - 7) | $w[.:.+8] | join(" ") ] as $sh
             | if any($sh[]; . as $s | $a | contains($s)) then $mh else empty end)
          end ]
    | unique
    ' 2>/dev/null || printf '[]'
}

now="$(date +%s)"

# Discard every stale receipt (turns whose Stop never fired) without posting: no
# reliable answer- or latency-correlation exists for them, and a misattributed
# citation or a multi-turn latency would poison exactly the measurement this
# feeds. Dropping a voluntary post-back is the benign outcome; faking one is not.
for stale in "${receipts[@]:1}"; do
  rm -f "$stale" 2>/dev/null || true
done

# The current turn's receipt (newest). Consume it up front so a mid-path failure
# still leaves no receipt to be re-matched against a later turn's answer.
current="${receipts[0]}"
receipt="$(cat "$current" 2>/dev/null || true)"
rm -f "$current" 2>/dev/null || true
[ -n "$receipt" ] || exit 0

grounding_id="$(printf '%s' "$receipt" | jq -r '.grounding_id // empty' 2>/dev/null || true)"
[ -n "$grounding_id" ] || exit 0

# latency_ms is required and must be >= 0. We cannot observe the model call
# (Claude Code makes it with the user's credential; Mollow is never in it), so
# this is the turn's wall-clock — UserPromptSubmit to Stop — the closest thing
# the hook can measure. Clamp a backwards clock to 0.
grounded_at="$(printf '%s' "$receipt" | jq -r '.grounded_at // 0' 2>/dev/null || echo 0)"
latency_ms=$(((now - grounded_at) * 1000))
[ "$latency_ms" -ge 0 ] || latency_ms=0

used='[]'
if [ -n "$answer" ]; then
  used="$(match_used "$receipt" "$answer")"
fi

# Omit used_fact_ids entirely when we have no reliable signal (unreadable
# transcript, or nothing matched) — rather than send an empty list that reads
# as "supplied, cited nothing" when we could not tell either way.
if [ -n "$answer" ] && [ "$used" != "[]" ]; then
  payload="$(jq -cn --arg gid "$grounding_id" --argjson lat "$latency_ms" --argjson used "$used" \
    '{grounding_id: $gid, status: "ok", latency_ms: $lat, used_fact_ids: $used}' 2>/dev/null || true)"
else
  payload="$(jq -cn --arg gid "$grounding_id" --argjson lat "$latency_ms" \
    '{grounding_id: $gid, status: "ok", latency_ms: $lat}' 2>/dev/null || true)"
fi

# Fire-and-forget: post back best-effort. The receipt is already consumed above.
[ -n "$payload" ] && mm_seam_post_read "/seam/v1/outcome" "$payload" 2 >/dev/null 2>&1 || true

exit 0
