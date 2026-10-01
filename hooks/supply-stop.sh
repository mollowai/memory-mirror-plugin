#!/usr/bin/env bash
# Stop: supply mode outcome post-back (MOL-5857, Phase 3).
#
# The TRIGGER for the outcome post-back, not a transcript parser. The receipt
# supply-ground.sh wrote at UserPromptSubmit already holds what was supplied
# (grounding_id + each fact's message_hash), so the post-back needs nothing
# parsed out of the transcript. POSTs POST /grounding/v1/outcome for each pending
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
# ── Which COPY of this file runs, before you edit it ─────────────────────────
# Launcher-dependent, and both readings fail with the same symptom: you edit,
# re-run, and see the old behaviour. `supply-ground.sh`'s header of the same name
# holds the measured rule; `preflight-supply.sh` answers it for a given session.
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
#
# NOTHING MAY REACH `ls` HERE, and the reason is not style (MOL-6325).
# `"$receipt_dir"/*.json` is ONE word: a quoted prefix joined to an unquoted
# glob. Under nullglob a glob that matches nothing removes the ENTIRE word,
# quoted prefix included — it does not fall back to the prefix. So on the
# ordinary "dir exists, no pending receipt" turn, `ls -t "$receipt_dir"/*.json`
# became a bare `ls -t`, which lists the CURRENT DIRECTORY. This hook's cwd is
# the worktree root, so `receipts` filled with the bare filenames of the user's
# own files, the non-empty guard below passed on them, and the two `rm -f` sites
# further down deleted every tracked root file of every worktree on the machine,
# once per turn. (Directories survived `rm` without `-r`; dotfiles were never
# listed by `ls` without `-a`. That is the whole of MOL-6199/6255/6271.)
#
# So the array is built by glob expansion, which cannot silently retarget, and
# the newest is picked with bash's own `-nt` rather than by parsing `ls -t`.
shopt -s nullglob
receipts=("$receipt_dir"/*.json)
shopt -u nullglob
[ "${#receipts[@]}" -gt 0 ] || exit 0

# Newest by mtime. `-nt` is a builtin file test, so there is no command to
# expand arguments for, no output to parse, and no cwd to fall back to.
newest="${receipts[0]}"
for f in "${receipts[@]}"; do
  [ "$f" -nt "$newest" ] && newest="$f"
done

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
  local receipt="$1" ans="$2" tools="${3:-}" # tools: verified hashes, one per line
  # $ans can be arbitrarily large: facts mode now reads the WHOLE turn
  # (uncapped — see the window comment above), and a long agentic turn's
  # combined assistant text can exceed the OS's single-argument/exec limit.
  # `--arg` puts it on jq's argv, so an oversized answer made jq fail to even
  # start, and the `2>/dev/null` fallback silently dropped every citation in
  # the turn (Greptile, #6483).
  #
  # Below this threshold, stay on `--arg` as before: no new dependency on a
  # writable TMPDIR for the ordinary turn, and pointer mode's typically-tiny
  # $tools never touches disk — unconditionally writing a temp file gave
  # EVERY match a new failure mode (a full/unwritable TMPDIR) that never
  # existed before, and one this small never needs (Greptile, #6483 round 3).
  # 65536 is comfortably under the OS single-argument limit (1MiB+ on every
  # platform this hook runs on) with room for jq's other argv/environment.
  local jq_prog='
    def norm: ascii_downcase | gsub("[^a-z0-9]+"; " ") | ltrimstr(" ") | rtrimstr(" ");
    ($answer | norm) as $a
    # Tags are matched on the LOWERCASED RAW answer, not the normalised one:
    # `norm` strips the brackets, and without them `fact-1` is a prefix of
    # `fact-12` — the whole bracketed token is what makes the match exact.
    | ($answer | ascii_downcase) as $araw
    | (.mode // "facts") as $mode
    # How many entries carry each hash. Two pointer records with identical bytes
    # at different locators legitimately SHARE one hash and keep separate citation
    # keys — that case is exactly why p9 keys membership on the record id. Keying
    # the matcher on the hash collapsed them again: verifying one credited both
    # (Greptile, #6228). An ambiguous hash credits NEITHER, because the transcript
    # cannot say which record the model actually read.
    | ( reduce (.facts[]? | .verify_hash // "") as $h ({}; .[$h] = ((.[$h] // 0) + 1)) ) as $hcount
    # `message_hash` / `content` are the receipt field names from BEFORE the
    # normalisation to `citation_key` / `match_text`. A turn whose
    # UserPromptSubmit ran the old hook and whose Stop runs this one holds that
    # shape, and reading only the new names dropped its citations (Greptile,
    # #6414). Same precedence the ground hook writes with: the new name first.
    | ($tools | split("\n") | map(select(. != ""))) as $verified
    | [ .facts[]?
        | (.citation_key // .message_hash) as $mh
        | ((.match_text // .content) // "") as $raw
        | (.verify_hash // "") as $vh
        # Bound HERE, not read inline below: inside `$araw | contains(...)` the
        # argument is evaluated against $araw (a string), so `.label` there
        # raises and the whole matcher returns [] — the same scoping trap as the
        # `$ok | index(.id)` note further down.
        | ((.label // "") | ascii_downcase) as $lbl
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
            # Why the hash and not the uri (Greptile, #6228): at the time, the uri
            # only appeared in a FILE fetch. `mcp__fetch-postgres__execute_sql`
            # received SQL rather than the `pg://` locator, so uri matching
            # credited files and never rows — a blind spot for half the sources,
            # not a small bias.
            #
            # MOL-6023 changed that half: `mcp__fetch-rows__fetch_row` takes the
            # locator, so both kinds now pass a uri. The hash is still what this
            # keys on, for the reason below rather than that one — it is the
            # stronger signal, and it is the same signal for both kinds, which a
            # uri is not (a `pg://` prefix collides across sibling row sources the
            # way a file path collides across a corpus).
            #
            # And it is STRONGER evidence than a fetch. A fetch that failed —
            # unreadable, oversized, refused — still passes the uri to the tool, so
            # uri matching credited fetches that returned no bytes. A verify call
            # carrying the hash means bytes came back AND were checked, which is the
            # only use this mechanism is trying to count. An unverified fetch is
            # deliberately NOT credited: per plan-hash-pointer-demo.md §1 that is
            # retrieval with extra latency, not a checked use.
            #
            # MEMBERSHIP, not a substring. `$verified` is the exact `hash`
            # argument of each verify that came back `match`. Searching the joined
            # tool inputs for the hash credited any hash that appeared ANYWHERE in
            # them — inside the `bytes` of a verify of a different entry, or in a
            # tool that is not a verify at all (Greptile, #6414).
            (($vh // "") as $h
             | if $h == "" then empty
               elif (($hcount[$h] // 0) > 1) then empty
               elif ($verified | index($h)) != null then $mh
               else empty end)
          # Facts mode, explicit citation: the model wrote the tag this fact was
          # shown under (supply-ground.sh). Checked before the verbatim run and
          # credited on its own — a cited tag is the model saying it used the
          # fact, which is what this count means. A receipt from before tags
          # existed has no `label`, so a tag in the answer credits nothing there.
          elif $lbl != "" and ($araw | contains("[" + $lbl + "]")) then $mh
          elif $n == 0 then empty
          elif $n < 8 then
            (if $a | contains($w | join(" ")) then $mh else empty end)
          else
            ([ range(0; $n - 7) | $w[.:.+8] | join(" ") ] as $sh
             | if any($sh[]; . as $s | $a | contains($s)) then $mh else empty end)
          end ]
    | unique
    '
  # BYTES, not characters: `${#ans}` counts characters under a UTF-8 locale,
  # but the exec/kernel per-argument limit this threshold guards against is a
  # byte limit. A turn built from enough multi-byte characters (CJK, emoji,
  # accents) could stay under a character-counted threshold while its byte
  # size was well over it, silently reintroducing the argv-limit failure round
  # 2 fixed (Greptile, #6483 round 4). `wc -c` counts bytes regardless of
  # locale.
  local ans_bytes tools_bytes
  ans_bytes="$(printf '%s' "$ans" | wc -c | tr -d ' ')"
  tools_bytes="$(printf '%s' "$tools" | wc -c | tr -d ' ')"
  if [ $((ans_bytes + tools_bytes)) -le 65536 ]; then
    printf '%s' "$receipt" | jq -c --arg answer "$ans" --arg tools "$tools" "$jq_prog" 2>/dev/null || printf '[]'
    return
  fi

  # Oversized: fall back to a file per value, read with `--rawfile` (no argv
  # limit). A RETURN trap — not just the explicit `rm` below — covers a
  # trappable interruption (SIGTERM/SIGINT) between here and the end of this
  # function; nothing can save it from SIGKILL, an inherent limit of any
  # temp-file use and no different from the rest of this codebase (Greptile,
  # #6483 round 3).
  local ans_file tools_file out rc
  ans_file="$(mktemp "${TMPDIR:-/tmp}/mm-supply-answer.XXXXXX" 2>/dev/null)" || { printf '[]'; return; }
  tools_file="$(mktemp "${TMPDIR:-/tmp}/mm-supply-tools.XXXXXX" 2>/dev/null)" || {
    rm -f "$ans_file"
    printf '[]'
    return
  }
  trap 'rm -f "$ans_file" "$tools_file"' RETURN
  printf '%s' "$ans" >"$ans_file"
  printf '%s' "$tools" >"$tools_file"
  out="$(printf '%s' "$receipt" | jq -c --rawfile answer "$ans_file" --rawfile tools "$tools_file" "$jq_prog" 2>/dev/null)"
  rc=$?
  if [ $rc -eq 0 ]; then printf '%s' "$out"; else printf '[]'; fi
}

now="$(date +%s)"

# Discard every stale receipt (turns whose Stop never fired) without posting: no
# reliable answer- or latency-correlation exists for them, and a misattributed
# citation or a multi-turn latency would poison exactly the measurement this
# feeds. Dropping a voluntary post-back is the benign outcome; faking one is not.
for stale in "${receipts[@]}"; do
  [ "$stale" = "$newest" ] && continue
  rm -f "$stale" 2>/dev/null || true
done

# The current turn's receipt (newest). Consume it up front so a mid-path failure
# still leaves no receipt to be re-matched against a later turn's answer.
current="$newest"
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

# ── Verified hashes of THIS turn (pointer mode's evidence) ───────────────────
# The tail spans turns, so it has to be cut where this turn began: a hash
# verified three turns ago would otherwise credit this receipt when the model
# did nothing this turn (Greptile, #6228).
#
# The cut is `transcript_offset` — the transcript's size in bytes when
# supply-ground.sh wrote the receipt, i.e. before this turn wrote anything.
# Everything past it is this turn's; nothing before it is. It replaced
# `grounded_at` as the bound because `grounded_at` is whole seconds and the
# transcript's fractions had to be stripped to compare, so a verify in the same
# second as the prompt — the end of the previous turn — passed `>=` (Greptile,
# #6414). An offset past the end of the file means the file is not the one the
# offset was taken on; nothing in it can be placed, so nothing is credited.
#
# A receipt with no offset (written before it existed, or with no transcript
# path at prompt time) falls back to `grounded_at`, STRICTLY after: a line in
# the grounding second cannot be put on either side of the prompt, so it is
# dropped. That under-counts a verify made within a second of the prompt,
# which is the direction this matcher is allowed to be wrong in. A line with no
# parseable timestamp is dropped for the same reason.
#
# Lines are parsed one at a time (`fromjson?`), so one unparseable line — a
# partial write at the boundary — costs that line, not the whole turn.
verified_hashes=""
transcript_offset="$(printf '%s' "$receipt" | jq -r '.transcript_offset // "" | tostring' 2>/dev/null || true)"
case "$transcript_offset" in *[!0-9]*) transcript_offset="" ;; esac
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  window=""
  since=-1
  if [ -n "$transcript_offset" ]; then
    size="$(wc -c <"$transcript_path" 2>/dev/null | tr -d ' ' || echo 0)"
    if [ "$transcript_offset" -le "${size:-0}" ]; then
      # No `tail -n 500` here: the offset already bounds this to exactly this
      # turn, so capping the line count on top of it drops the START of a long
      # agentic turn instead of old turns. An early assistant message citing a
      # fact fell outside that cap and was silently omitted from
      # used_fact_ids even though it was cited this turn (Greptile, #6483).
      window="$(tail -c +$((transcript_offset + 1)) "$transcript_path" 2>/dev/null || true)"
    fi
  elif [ "$grounded_at" -gt 0 ]; then
    window="$(tail -n 500 "$transcript_path" 2>/dev/null || true)"
    since="$grounded_at"
  fi
  if [ -n "$window" ]; then
    verified_hashes="$(printf '%s\n' "$window" | jq -Rrn --argjson since "$since" '
      [ inputs | fromjson? | objects
        | select( $since < 0
                  or ((((.timestamp? // "") | tostring | sub("\\.[0-9]+Z$"; "Z"))
                       | try fromdateiso8601 catch -1) > $since) )
        # Every block in the window, assistant and user alike: the tool_use
        # lives on the assistant message and its tool_result on the following
        # user message, so a filter on assistant-only never sees an outcome.
        | ((.message.content // .content) // empty)
        | if type == "array" then .[] else empty end ] as $blocks
      # A verify whose RESULT did not come back `match` is not evidence of use:
      # the hash is in its INPUT either way, so reading inputs alone credited a
      # pointer the check REFUTED (Greptile, #6228). Correlated by tool_use_id.
      #
      # The result is PARSED and its top-level `outcome` read. A quoted-substring
      # test for `"match"` also matched a MISMATCH, whose
      # `dissenting_canonical_forms` carry `"outcome":"match"` for each form that
      # did reproduce the digest (pointer_tools.ex render/1) — and matched any
      # tool at all whose body said "match" (Greptile, #6414).
      | ( [ $blocks[] | select((.type? // "") == "tool_result")
            | select((.is_error? // false) | not)
            # `content` comes back BOTH ways in the same transcript — a string
            # and an array of text blocks (measured: 33 string, 1 array in one
            # tail). Joining the array text first keeps the array shape
            # parseable (Greptile, #6228).
            | ( (.content? // "")
                | if type == "array" then ([ .[]? | (.text? // "") ] | join("\n"))
                  else tostring end ) as $rc
            | select(($rc | try fromjson catch null) as $j
                     | ($j | type) == "object" and $j.outcome == "match")
            | (.tool_use_id? // "") ] | map(select(. != "")) ) as $ok
      # Only the Mollow verify tool, and only the `hash` argument of that call.
      # The full name, not the `__verify_fetched_bytes` suffix: a suffix let a
      # same-named tool on another MCP server earn credit without the Mollow
      # verifier running (Greptile, #6449). supply-ground.sh instructs this
      # exact name, and `mollow-memory` is the server name every launcher
      # injects. (No apostrophes in here: this is a single-quoted jq program.)
      | [ $blocks[] | select((.type? // "") == "tool_use")
          | select((.name? // "") == "mcp__mollow-memory__verify_fetched_bytes")
          # `.id` is bound BEFORE the index call: inside `$ok | index(.id)` the
          # argument is evaluated against $ok, not against the block, so it
          # yields null and nothing ever matches — silently, with an empty result.
          | (.id? // "") as $tid
          | select(($ok | index($tid)) != null)
          | (.input.hash? // empty) | select(type == "string" and . != "") ]
      | unique | join("\n")
      ' 2>/dev/null || true)"
  fi
fi

# Which signal counts depends on the mode: facts mode reads the answer (the text
# is Mollow's own, so a verbatim run is real evidence), pointer mode reads this
# turn's tool calls (the bytes are the customer's, so only a verify call is).
receipt_mode="$(printf '%s' "$receipt" | jq -r '.mode // "facts"' 2>/dev/null || echo facts)"

# ── Facts mode reads the WHOLE turn, not only its last message ───────────────
# An agentic turn cites a fact mid-turn — before a tool call — and ends on a
# summary. Reading only the last assistant message missed those citations; it
# was the other half of the 7-in-239. So when this turn's start is known by
# byte offset (the same `window` the pointer path reads above), every assistant
# text block past it is the answer. Only the offset bounds it: the whole-second
# `grounded_at` fallback cannot place a line in the prompt's own second, so with
# no offset the last-message read above stands.
if [ "$receipt_mode" != "pointer" ] && [ -n "${window:-}" ] && [ "${since:-0}" -lt 0 ]; then
  turn_answer="$(printf '%s\n' "$window" | jq -Rrn '
    [ inputs | fromjson? | objects
      | select((.type? // .role? // "") == "assistant")
      | ((.message.content // .content) // "")
      | if type == "string" then .
        elif type == "array" then ([ .[]? | select((.type? // "") == "text") | (.text? // "") ] | join("\n"))
        else "" end ]
    | join("\n")
    ' 2>/dev/null || true)"
  [ -n "$turn_answer" ] && answer="$turn_answer"
fi
if [ "$receipt_mode" = "pointer" ]; then evidence="$verified_hashes"; else evidence="$answer"; fi

used='[]'
if [ -n "$evidence" ]; then
  used="$(match_used "$receipt" "$answer" "$verified_hashes")"
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
[ -n "$payload" ] && mm_seam_post_read "/grounding/v1/outcome" "$payload" 2 >/dev/null 2>&1 || true

exit 0
