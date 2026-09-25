#!/usr/bin/env bash
# UserPromptSubmit: supply mode dogfood (MOL-5857, Phase 3).
#
# Grounds THIS prompt from the whole register via POST /seam/v1/ground in
# `facts` mode, injects the returned facts as additionalContext, and writes a
# per-turn receipt the Stop hook (supply-stop.sh) posts back. Claude Code owns
# composition (step 4 of the host flow) and calls Anthropic with the user's own
# credential (step 5) — Mollow sits only at step 3, never in the model call.
#
# This is the register-wide sibling of recall-decisions.sh, which runs the same
# UserPromptSubmit pattern against the decision store alone. Both run so either
# can be disabled without the other.
#
# ── Blast radius ─────────────────────────────────────────────────────────────
# This hook loads into EVERY Claude Code session on this machine. So it makes NO
# network call unless the local opt-in `MOLLOW_SUPPLY_MODE` is set — that guard
# is the first thing here, before stdin, before mm_ready, before any curl,
# because the 2s budget is spent whether or not the server answers, and the
# server-side `supply_mode` flag only 404s AFTER the request is made.
#
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
# Fail-open, silently: every path exits 0. A miss, a timeout, a malformed
# response — the turn proceeds ungrounded and nothing is surfaced.

# Strict mode: -u (unset vars error) and pipefail ON; -e deliberately OFF — a
# non-zero command mid-hook must not abort before the closing `exit 0`, which is
# the fail-open contract (matches recall-decisions.sh; _common.sh sets the same).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

# Opt-in guard FIRST — before reading stdin, mm_ready, or any curl.
mm_supply_enabled || exit 0
mm_ready || exit 0

input="$(cat)"
prompt="$(printf '%s' "$input" | jq -r '.prompt // empty' 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
# Blank-once-trimmed counts as empty. `[ -z ]` alone passes a whitespace-only
# prompt, which the server then trims and refuses with 422 query_required — so
# the hook spent its 2s budget to be told there was nothing to ground. Caught by
# Greptile on #6251 via the hint that misattributed that 422 to pointer_mode.
[ -z "${prompt//[[:space:]]/}" ] && exit 0

# Never prompt mode: Claude Code composes the request itself and will not accept a
# prompt-mode body it did not build. So this asks for `facts` (content inline) or,
# behind its own opt-in, `pointer` (hash + locator, NO content — the model reads
# the bytes itself off the user's own disk or database).
#
# The two are different enough downstream that the mode is carried in a variable
# rather than re-derived: the wire shape, the dedupe key, the injected wording and
# the receipt all branch on it, and re-reading the env var at each of those points
# is how they drift apart.
mode="facts"
mm_supply_pointer_enabled && mode="pointer"

# Limit is server-capped; keep it small to respect the per-turn budget and the
# injected context size.
limit="${MOLLOW_SUPPLY_LIMIT:-5}"
body="$(jq -cn --arg m "$mode" --arg q "$prompt" --argjson n "$limit" '{mode: $m, query: $q, limit: $n}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Hard 2s cap (harder than anything relay mode faces). A miss drops the grounding
# and the turn proceeds ungrounded — empty output keeps it snappy.
raw="$(mm_seam_post_read "/seam/v1/ground" "$body" 2)"
status="$(mm_seam_split_status "$raw")"
resp="$(mm_seam_split_body "$raw")"

# MOL-5978: a definite HTTP error is SAID, once, rather than dropped. Before
# this, every non-200 exited 0 with no output and the operator saw a turn that
# was not grounded — indistinguishable from an empty register, and
# actively misleading, because the note tells the reader an empty grounding
# means the wrong workspace.
#
# This fires only on a real HTTP code. A `000` (timeout, connection refused) is
# transient and stays silent: the hook is time-boxed at 2s, and a line in front
# of the operator on every slow turn is its own defect.
#
# It is emitted as additionalContext rather than written to stderr because that
# is the only channel this hook has that reaches a person, and it exits
# immediately after — a turn that could not ground has nothing else to say.
hint="$(mm_grounding_status_hint "$status" "$resp")"
if [ -n "$hint" ]; then
  mm_emit_context "UserPromptSubmit" "$hint"
  exit 0
fi

[ -z "$resp" ] && exit 0

grounding_id="$(printf '%s' "$resp" | jq -r '.grounding_id // empty' 2>/dev/null || true)"
[ -z "$grounding_id" ] && exit 0

# ── Repeat suppression (structural, MOL-3755) ────────────────────────────────
# A top-ranked fact stays top-ranked for as long as the conversation is about it,
# so without this the same text is injected every turn. The register is larger
# than the decision store, so this matters more here than in recall-decisions.sh.
#
# Dedupe on `message_hash` — a digest OVER THE FACT'S CONTENT, the stable
# identifier the wire carries and the same one the post-back cites — never on a
# row id. Keyed by env label so a fleet-target switch re-surfaces once, matching
# recall-decisions.sh and import-local-memories.sh. Per-machine "seen here", not
# "dismissed": acceptable for an advisory that never blocks.
seen_file="${HOME}/.mollow/supply-seen.json"
seen_key="$(mm_env_label)"
seen_ids='[]'
if [ -f "$seen_file" ]; then
  seen_ids="$(jq -c --arg k "$seen_key" '.[$k] // []' "$seen_file" 2>/dev/null || echo '[]')"
fi

# The dedupe key is the wire's own citation identifier, which DIFFERS by mode:
# `message_hash` for a facts-mode fact (a digest over its content) and
# `citation_key` for a pointer fact (the registry record id). Both are stable per
# citeable fact and both are what the post-back cites, which is the property that
# matters — keying on anything else would suppress the wrong thing and cite the
# wrong thing. Neither is a row id.
#
# `citation_key` is read FIRST so a pointer fact is never keyed by a stray
# `message_hash`: a pointer fact carries none today, and if one ever appeared it
# would be the etch digest of a fact whose content Mollow does not hold.
fresh="$(printf '%s' "$resp" | jq -c --argjson seen "$seen_ids" '
  [ .facts[]?
    | select(((.citation_key // .message_hash) // "") as $h
             | $h != "" and (($seen | index($h)) | not)) ]
  ' 2>/dev/null || echo '[]')"

fresh_count="$(printf '%s' "$fresh" | jq 'length' 2>/dev/null || echo 0)"
# Nothing new to inject. The server still recorded a supply for this grounding_id,
# but we injected nothing this turn, so there is nothing to measure the usage of —
# no receipt, no post-back. Keeps the measurement honest (supplied = injected).
[ "$fresh_count" -gt 0 ] || exit 0

# ── The injected wording IS the deliverable in pointer mode ──────────────────
# plan-hash-pointer-demo.md §8 lists "model does not call the fetch tool" as a
# rehearsal failure whose only remedy is "the prompt names the tool". So these
# tool names are load-bearing text, not packaging, and each is spelled as the
# model actually sees it:
#
#   mcp__fetch-files__fetch_file            host_agent/lib/host_agent/mcp/fetch_files.ex
#   mcp__fetch-rows__fetch_row              host_agent/lib/host_agent/mcp/fetch_rows.ex
#   mcp__mollow-memory__verify_fetched_bytes  webapp/lib/mollow/mcp/pointer_tools.ex
#
# ## The sql_row lane named `mcp__fetch-postgres__execute_sql` until MOL-6023
#
# It was replaced because step 2 below was UNSATISFIABLE through it, not because
# a Mollow-owned server is tidier. Two reasons, and neither needed anything to
# differ between the two sides:
#
#   * `execute_sql` returns a RESULT SET, not bytes. `sql-row-text-v1` hashes a
#     JSON array of the row's column values, so producing what
#     `verify_fetched_bytes` needs WAS the re-encoding step 2 forbids. There was
#     no reading of the instruction a model could follow on that lane.
#   * The column list, its order, and the `::text` cast on each are a contract.
#     The REGISTERING side is handed it by `GET /api/host-node/pointer-sources`;
#     the model was handed a uri carrying a prefix and a row key and no columns
#     at all. It had to independently arrive at all three, and without the casts
#     `numeric` and `timestamptz` come back as JSON numbers, which the form
#     refuses as `cannot_canonicalize: non_text_value`.
#
# `fetch_row` takes the POINTER and issues the statement the source prescribes,
# so its `bytes` ARE the canonical form and step 2's wording is now true here.
# `fetch-postgres` is still configured for ad-hoc exploration; it is no longer
# what a pointer is read through.
#
# Each entry pairs its OWN uri with its OWN hash on one line. Listing uris and
# hashes as two collections invites pairing entry A's hash with entry B's bytes,
# which reports a mismatch that is not real — the worst possible output here,
# because it reads as "the content was altered" about content that was not.
#
# `verify_fetched_bytes` is named with hash + canonical_form + bytes (MOL-5979).
# The disambiguator this comment used to wait on landed as #6226, and #6240 then
# rewrote the parameter's own description to lead with "Pass the `canonical_form`
# from the same pointer you fetched" rather than calling it optional — because
# OMITTING it is the dangerous path, not a neutral default.
#
# Omitted, the tool answers with the strongest outcome across every record that
# hash resolves to, globally. So a model grounded through this hook could be told
# `match` by a stranger's record registered under a different form while the
# operator's own file had in fact changed — a false all-clear on the one question
# the demo exists to answer.
#
# The form is added HERE AND TO THE ENTRY LINES TOGETHER, which is the coupling
# rule at the top of this file: an instruction asking the model to mention
# something is a change to the matcher's input. Naming the form in the wording
# while the entries do not carry it would instruct the model to pass a value it
# was never given — the partial-mirror failure MOL-5948 was, arriving from the
# other direction.
if [ "$mode" = "pointer" ]; then
  # Only the kinds actually present are named. Naming a fetch tool for a kind not
  # in this response is at best noise and at worst an instruction to call a server
  # the session does not have: resolve-mcp-host.sh DROPS fetch-files when the
  # corpus root is unset or not a real directory, and fetch-postgres without a DSN
  # (Greptile, #6228). The absence line turns an unusable instruction into a
  # diagnosable one rather than leaving the model to improvise a fetch.
  #
  # It says SKIP, not stop. A mixed response plus one missing tool would otherwise
  # discard the pointers the session CAN fetch and lose the grounding for the whole
  # turn — a worse outcome than the partial one, and a regression this hook
  # introduced while fixing the tool-naming finding above it.
  #
  # `plan-hash-pointer-demo.md` §5 makes two sources deliberate partly so a wedged
  # Postgres MCP "does not end the demo". Stop-the-turn converted a missing tool
  # into exactly that. And the mixed case is the DEFAULT, not an edge: the p7
  # rehearsal measured resolve-mcp-host.sh dropping fetch-postgres outright when
  # POINTER_FETCH_PG_URL is unset, so one-tool-present is the state of any session
  # whose operator exported one env var and not the other.
  #
  # It also has to NAME what it skipped. A silent skip plus a partial answer is the
  # same shape as a citation count that looks like use: the turn appears to have
  # worked while quietly grounding on less than it was handed.
  ctx="$(printf '%s' "$fresh" | jq -r '
    ([ .[] | (.locator.kind) // "unknown" ] | unique) as $kinds
    | "Mollow supply mode handed you POINTERS, not content. Each entry names where the content lives and the digest it was registered under. Mollow keeps no copy — read the bytes yourself, then check them. Use what applies; ignore the rest.\n\n"
    + "For each entry you use:\n"
    + "1. FETCH it. "
    + ( ( (if ($kinds | index("file")) then ["A `file` locator: call mcp__fetch-files__fetch_file with that entry'"'"'s uri."] else [] end)
        + (if ($kinds | index("sql_row")) then ["A `sql_row` locator: call mcp__fetch-rows__fetch_row with that entry'"'"'s uri. Do NOT write SQL for these — that tool issues the statement the row was registered with, which is why its answer can match. Its `bytes` field is the content; pass that value through unchanged."] else [] end)
        ) | join(" ") )
    + " If a tool named here is not available in this session, skip ONLY the entries needing that tool and keep going with the ones you can fetch. NAME the entries you skipped and why, in your answer: an entry you cannot fetch is one you cannot check, and an unchecked pointer is retrieval with extra latency. A silent skip makes a partial answer look like a complete one.\n"
    + "2. CHECK it. Call mcp__mollow-memory__verify_fetched_bytes with that same entry'"'"'s hash, that same entry'"'"'s canonical_form, and the bytes exactly as they came back — do not trim, re-indent or re-encode them. For a `file` that is the file'"'"'s content; for a `sql_row` it is the fetch tool'"'"'s `bytes` field. Both already carry the form they were hashed in, so reshaping either reports a mismatch on content nobody altered.\n"
    + "Pass canonical_form every time. Leaving it out does not fail — it widens the check to every record sharing that hash anywhere, so it can report a match from a record that is not yours while your own entry does not match.\n"
    + "Keep the hash, the canonical_form and the bytes from the SAME entry. Pairing one entry'"'"'s hash with another'"'"'s bytes reports a mismatch that is not real.\n\n"
    + "Entries:\n"
    + ([ .[]
         | "- " + (.title // "entry")
           + " [" + ((.locator.kind) // "unknown") + "]"
           + " uri=" + ((.locator.uri) // "")
           + " hash=" + ((.hash) // "")
           # The token is OMITTED, never emitted empty, when an entry carries no
           # form. `canonical_form=` with nothing after it reads as a value and
           # the model passes "", which the tool refuses outright
           # ({:error, {:unknown_canonical_form, _}}) — strictly worse than
           # omitting the argument, which is merely wider. `list_pointers/2`
           # excludes formless records, so this is a backstop rather than a path
           # anything reaches today.
           + (if ((.locator.canonical_form) // "") == ""
              then ""
              else " canonical_form=" + (.locator.canonical_form) end)
       ] | join("\n"))
    ' 2>/dev/null || true)"
else
  ctx="$(printf '%s' "$fresh" | jq -r '
    "Facts from your memory that may bear on this request (surfaced by Mollow supply mode — use them if they apply, otherwise ignore):\n"
    + ([ .[] | "- " + (.title // "fact") + ": " + (.content // "") ] | join("\n"))
    ' 2>/dev/null || true)"
fi

mm_emit_context "UserPromptSubmit" "$ctx"

# ── Receipt (what the Stop hook posts back) ──────────────────────────────────
# Persist grounding_id plus each injected fact's message_hash and content — the
# hashes are what the post-back sends, the content is what the Stop hook matches
# the answer against locally. relevance is kept for per-turn forensics; it is not
# needed for the post-back. Keyed by grounding_id (unique per ground call) under
# a per-session dir, so the Stop hook finds this turn's supply without parsing
# the transcript. Requires a session id we can safely turn into a path.
#
# The receipt holds the fact CONTENT (the user's own memory text), so it is
# written owner-only: `umask 077` makes the dirs 0700 and the file 0600, and the
# chmods re-harden a base dir a prior process may have created with looser perms
# — otherwise another local user could read supplied memory under the predictable
# shared temp path before the Stop hook deletes it (Greptile, PR #6160). Atomic
# via a private temp + rename so a reader never sees a half-written file.
if mm_safe_component "$session_id" && mm_safe_component "$grounding_id"; then
  receipt_root="${TMPDIR:-/tmp}/mollow-supply"
  receipt_dir="${receipt_root}/${session_id}"
  # The receipt is normalised to ONE shape across both modes, so supply-stop.sh
  # has a single matcher rather than two that can drift:
  #
  #   citation_key  what the post-back sends (message_hash | citation_key)
  #   match_text    what the answer is matched against LOCALLY
  #
  # In facts mode `match_text` is the fact's content, as before. In pointer mode
  # Mollow never held the content — the model fetched it — so there is nothing to
  # match verbatim; the locator uri is used instead. It is weaker evidence and the
  # matcher treats it as such (see supply-stop.sh). `mode` is recorded so the Stop
  # hook does not have to infer which kind it is holding.
  receipt="$(printf '%s' "$fresh" | jq -c \
    --arg gid "$grounding_id" --arg mode "$mode" --argjson ts "$(date +%s)" '
    { grounding_id: $gid, grounded_at: $ts, mode: $mode,
      facts: [ .[]
               | { citation_key: (.citation_key // .message_hash),
                   match_text: (if (.citation_key // null) != null
                                then ((.locator.uri) // "")
                                else (.content // "") end),
                   verify_hash: (.hash // null),
                   relevance: (.relevance // null) } ] }' 2>/dev/null || true)"
  if [ -n "$receipt" ]; then
    (
      umask 077
      mkdir -p "$receipt_dir" 2>/dev/null || exit 0
      # Re-harden ONLY our own session dir — never the shared receipt_root, whose
      # chmod could restrict another user's temp files if the path ever resolved
      # up a level. umask 077 already made a freshly-created session dir 0700.
      chmod 700 "$receipt_dir" 2>/dev/null || true
      tmp="${receipt_dir}/.${grounding_id}.$$.json"
      if printf '%s' "$receipt" >"$tmp" 2>/dev/null; then
        chmod 600 "$tmp" 2>/dev/null || true
        mv -f "$tmp" "${receipt_dir}/${grounding_id}.json" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
      fi
    )
  fi
fi

# Record what was shown so the next turn suppresses it. Best-effort and last: a
# failure here must never cost the turn its context. See mm_seen_add in
# _common.sh for the lock and retry budget.
# Same key the freshness filter used, or the next turn re-injects what it just
# showed. `citation_key` first, for the reason stated at the filter above.
shown="$(printf '%s' "$fresh" | jq -c '[ .[] | (.citation_key // .message_hash) // empty ]' 2>/dev/null || echo '[]')"
if [ "$shown" != "[]" ]; then
  mm_seen_add "$seen_file" "$seen_key" "$shown" || true
fi

exit 0
