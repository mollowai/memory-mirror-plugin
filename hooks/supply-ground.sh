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
[ -z "$prompt" ] && exit 0

# facts mode only: Claude Code composes the request itself and will not accept a
# prompt-mode body it did not build. Limit is server-capped; keep it small to
# respect the per-turn budget and the injected context size.
limit="${MOLLOW_SUPPLY_LIMIT:-5}"
body="$(jq -cn --arg q "$prompt" --argjson n "$limit" '{mode: "facts", query: $q, limit: $n}' 2>/dev/null || true)"
[ -z "$body" ] && exit 0

# Hard 2s cap (harder than anything relay mode faces). A miss drops the grounding
# and the turn proceeds ungrounded — empty output keeps it snappy.
resp="$(mm_seam_post_read "/seam/v1/ground" "$body" 2)"
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

fresh="$(printf '%s' "$resp" | jq -c --argjson seen "$seen_ids" '
  [ .facts[]?
    | select((.message_hash // "") as $h | $h != "" and (($seen | index($h)) | not)) ]
  ' 2>/dev/null || echo '[]')"

fresh_count="$(printf '%s' "$fresh" | jq 'length' 2>/dev/null || echo 0)"
# Nothing new to inject. The server still recorded a supply for this grounding_id,
# but we injected nothing this turn, so there is nothing to measure the usage of —
# no receipt, no post-back. Keeps the measurement honest (supplied = injected).
[ "$fresh_count" -gt 0 ] || exit 0

ctx="$(printf '%s' "$fresh" | jq -r '
  "Facts from your memory that may bear on this request (surfaced by Mollow supply mode — use them if they apply, otherwise ignore):\n"
  + ([ .[] | "- " + (.title // "fact") + ": " + (.content // "") ] | join("\n"))
  ' 2>/dev/null || true)"

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
  receipt="$(printf '%s' "$fresh" | jq -c \
    --arg gid "$grounding_id" --argjson ts "$(date +%s)" '
    { grounding_id: $gid, grounded_at: $ts,
      facts: [ .[] | {message_hash, content, relevance} ] }' 2>/dev/null || true)"
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
shown="$(printf '%s' "$fresh" | jq -c '[ .[].message_hash // empty ]' 2>/dev/null || echo '[]')"
if [ "$shown" != "[]" ]; then
  mm_seen_add "$seen_file" "$seen_key" "$shown" || true
fi

exit 0
