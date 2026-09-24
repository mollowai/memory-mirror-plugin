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
#
# ── The wording and the matcher are ONE mechanism ────────────────────────────
# Changing the injected text in supply-ground.sh changes what appears in the
# transcript, which changes what supply-stop.sh can see. They move together or
# one of them is briefly wrong.
#
# That is not theoretical. MOL-5936 p6 took FIVE review rounds and every round
# found a real defect in the previous round's fix, always across this seam:
#
#   name only reachable tools  ->  "say so and stop" ended the turn
#   "skip, don't stop"         ->  "NAME what you skipped" made a skipped entry
#                                  creditable, because naming was the evidence
#   credit on the fetch        ->  sql_row uncreditable; a failed fetch credited
#   credit on the hash         ->  a failed verify credited; a shared hash
#                                  credited both records
#
# Before changing either file, ask what the other now sees. In particular: any
# instruction that asks the model to MENTION something is a change to the
# matcher's input.
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
# In POINTER mode the evidence is necessarily weaker, and the reason is structural
# rather than a shortcut: Mollow never held the content. The model fetched the
# bytes itself, so there is no stored text to find an 8-word run of, and the only
# thing both sides know is the locator uri. So a pointer fact counts as cited when
# its uri appears in the answer.
#
# That is a real signal — a uri is distinctive enough that incidental occurrence is
# unlikely — but it is weaker than the content run in one specific way worth
# naming: the uri was PUT IN FRONT OF THE MODEL by this hook's own injected
# context, so a model that echoes the pointer list without fetching anything would
# match. It over-counts in that direction where the content matcher under-counts.
# Recorded here rather than silently, because `supplied_used_count` means slightly
# different things in the two modes and a reader comparing them should know.
#
# AND THE SERVER CANNOT CORRECT ANY OF THIS. `Outcome.do_record!/2` is
# `used = Enum.uniq(params.used_fact_ids)` followed by a MapSet membership test
# against what was supplied (outcome.ex:105-107 on main) — there is no text
# matching server-side at all. So it catches a PHANTOM key (an id never supplied)
# and nothing else: every key in this array is taken verbatim as "the model used
# this". Posting the whole supplied list having fetched nothing yields
# supplied_used_count == N, phantom_used_count == 0 and a stored receipt that
# looks perfect and establishes nothing — measured by the p7 rehearsal.
#
# Which makes THIS function the only thing standing between an honest count and a
# flattering one. That is why it is conservative in facts mode and why the uri is
# matched whole here, and why the count must never be read as evidence that bytes
# were fetched: that evidence is the fetch tool call and verify_fetched_bytes
# returning `match`, neither of which this hook can see.
#
# The uri is matched WHOLE, not as an 8-word run: a path chopped into word runs
# matches any sibling path sharing a prefix, which is most of a corpus.
match_used() {
  local receipt="$1" ans="$2" tools="${3:-}"
  printf '%s' "$receipt" | jq -c --arg answer "$ans" --arg tools "$tools" '
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    ($answer | norm) as $a
    | (.mode // "facts") as $mode
    # How many entries carry each hash. Two pointer records with identical bytes
    # at different locators legitimately SHARE one hash and keep separate citation
    # keys — that case is exactly why p9 keys membership on the record id. Keying
    # the matcher on the hash collapsed them again: verifying one credited both
    # (Greptile, #6228). An ambiguous hash credits NEITHER, because the transcript
    # cannot say which record the model actually read.
    | ( reduce (.facts[]? | .verify_hash // "") as $h ({}; .[$h] = ((.[$h] // 0) + 1)) ) as $hcount
    | [ .facts[]?
        | .citation_key as $mh
        | (.match_text // "") as $raw
        | (.verify_hash // "") as $vh
        | ($raw | norm) as $t
        | ($t | split(" ") | map(select(length > 0))) as $w
        | ($w | length) as $n
        | if $mh == null then empty
          elif $mode == "pointer" then
            # NOTE the guard order. An empty `match_text` must NOT disqualify a
            # pointer fact: its uri is not the evidence any more, and folding it
            # into the shared `$n == 0` check silently refused to credit an entry
            # whose hash verified. The emptiness that matters here is the HASH.
            # The HASH of this entry in a tool input, not its uri, not the prose.
            #
            # Why the hash and not the uri (Greptile, #6228): the uri only appears
            # in a FILE fetch. `mcp__fetch-postgres__execute_sql` receives SQL, not
            # the `pg://` locator, so uri matching credited files and never rows —
            # a blind spot for half the sources, not a small bias. The hash reaches
            # `verify_fetched_bytes` whatever the kind.
            #
            # And it is STRONGER evidence than a fetch. A fetch that failed —
            # unreadable, oversized, refused — still passes the uri to the tool, so
            # uri matching credited fetches that returned no bytes. A verify call
            # carrying the hash means bytes came back AND were checked, which is the
            # only use this mechanism is trying to count. An unverified fetch is
            # deliberately NOT credited: per plan-hash-pointer-demo.md §1 that is
            # retrieval with extra latency, not a checked use.
            (($vh // "") as $h
             | if $h == "" then empty
               elif (($hcount[$h] // 0) > 1) then empty
               elif ($tools | contains($h)) then $mh
               else empty end)
          elif $n == 0 then empty
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

# ── Tool calls of THIS turn (pointer mode's evidence) ────────────────────────
# Bounded by `grounded_at`, because the tail spans turns: a hash verified three
# turns ago would otherwise credit this receipt when the model did nothing this
# turn (Greptile, #6228). Transcript timestamps are ISO with fractional seconds,
# which `fromdateiso8601` rejects, so the fraction is stripped before parsing.
# A line with no parseable timestamp is DROPPED rather than kept: keeping it
# restores the unbounded behaviour on exactly the lines we cannot place.
tool_inputs=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ] && [ "$grounded_at" -gt 0 ]; then
  tool_inputs="$(tail -n 500 "$transcript_path" 2>/dev/null | jq -rs --argjson since "$grounded_at" '
    # Every block in the window, assistant and user alike: the tool_use lives on
    # the assistant message and its tool_result on the following user message, so
    # a filter on assistant-only never sees an outcome.
    [ .[]
      | select( (((.timestamp? // "") | tostring | sub("\\.[0-9]+Z$"; "Z"))
                 | try fromdateiso8601 catch -1) >= $since )
      | ((.message.content // .content) // empty)
      | if type == "array" then .[] else empty end ] as $blocks
    # A verify whose RESULT did not come back `match` is not evidence of use: the
    # hash is in its INPUT either way, so reading inputs alone credited a pointer
    # the check REFUTED (Greptile, #6228). Correlated by tool_use_id.
    #
    # `"match"` is tested WITH its quotes on purpose. Bare `match` is a substring
    # of `mismatch`; `"match"` is not, because the quote lands on the `s`.
    | ( [ $blocks[] | select((.type? // "") == "tool_result")
          | select((.is_error? // false) | not)
          # `content` comes back BOTH ways in the same transcript — a string and
          # an array of text blocks (measured: 33 string, 1 array in one tail).
          # `tostring` on the array escapes the inner quotes, so testing the
          # stringified array misses every array-shaped result and silently drops
          # a verified pointer (Greptile, #6228).
          | ( (.content? // "")
              | if type == "array" then ([ .[]? | (.text? // "") ] | join("\n"))
                else tostring end ) as $rc
          | select($rc | contains("\"match\""))
          | (.tool_use_id? // "") ] | map(select(. != "")) ) as $ok
    | [ $blocks[] | select((.type? // "") == "tool_use")
        # `.id` is bound BEFORE the index call: inside `$ok | index(.id)` the
        # argument is evaluated against $ok, not against the block, so it yields
        # null and nothing ever matches — silently, with an empty result.
        | (.id? // "") as $tid
        | select(($ok | index($tid)) != null)
        | (.input? // {} | tostring) ] | join("\n")
    ' 2>/dev/null || true)"
fi

# Which signal counts depends on the mode: facts mode reads the answer (the text
# is Mollow's own, so a verbatim run is real evidence), pointer mode reads this
# turn's tool calls (the bytes are the customer's, so only a verify call is).
receipt_mode="$(printf '%s' "$receipt" | jq -r '.mode // "facts"' 2>/dev/null || echo facts)"
if [ "$receipt_mode" = "pointer" ]; then evidence="$tool_inputs"; else evidence="$answer"; fi

used='[]'
if [ -n "$evidence" ]; then
  used="$(match_used "$receipt" "$answer" "$tool_inputs")"
fi

# Omit used_fact_ids entirely when we have no reliable signal (unreadable
# transcript, or nothing matched) — rather than send an empty list that reads
# as "supplied, cited nothing" when we could not tell either way.
if [ -n "$evidence" ] && [ "$used" != "[]" ]; then
  payload="$(jq -cn --arg gid "$grounding_id" --argjson lat "$latency_ms" --argjson used "$used" \
    '{grounding_id: $gid, status: "ok", latency_ms: $lat, used_fact_ids: $used}' 2>/dev/null || true)"
else
  payload="$(jq -cn --arg gid "$grounding_id" --argjson lat "$latency_ms" \
    '{grounding_id: $gid, status: "ok", latency_ms: $lat}' 2>/dev/null || true)"
fi

# Fire-and-forget: post back best-effort. The receipt is already consumed above.
[ -n "$payload" ] && mm_seam_post_read "/seam/v1/outcome" "$payload" 2 >/dev/null 2>&1 || true

exit 0
