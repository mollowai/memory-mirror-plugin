#!/usr/bin/env bash
# recall-batch.sh — ask Engram for its view on a whole battery of questions.
#
# Reads a JSON array of {id, question, options[]} on stdin, POSTs it to
# /api/memory/decisions/recall_batch, and prints the results array on stdout.
#
# Used by the `/ask-first` skill, which needs Engram's prior on every question in
# a plan's battery BEFORE asking the user any of them — that is what lets a
# confident prior become a stated assumption instead of a question, and what puts
# Engram's recommendation beside the model's on the ones still worth asking.
#
# Unlike the hooks that share this directory, this is called deliberately by a
# skill rather than fired on an event, so it is allowed a longer budget and it
# reports failure instead of silently no-opping: a sweep that believes Engram had
# no opinion, when in fact the request failed, would quietly stop showing the
# second recommendation and nobody would notice.
#
# Exit codes:
#   0  results printed on stdout (a JSON array, possibly empty)
#   1  memory is not reachable/configured — caller should proceed model-only
#   2  usage
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

# Each question costs an embedding plus a vector search, served sequentially, so
# a full 30-question battery needs far more headroom than the 2s the event hooks
# in this directory run on. A timeout here loses EVERY view in the battery, not
# one — the caller cannot tell a slow server from an absent opinion.
TIMEOUT="${RECALL_BATCH_TIMEOUT:-45}"
SCOPE=""

# A flag given as the FINAL argument has no value to consume, and a bare
# `shift 2` there exits 1 under `set -e` — aborting before mm_ready runs, so the
# caller would read a usage error as "memory unavailable" and silently fall back
# model-only. Fail as usage (exit 2) instead.
require_value() {
  [ "$1" -ge 2 ] || {
    echo "recall-batch: $2 requires a value" >&2
    exit 2
  }
}

while [ $# -gt 0 ]; do
  case "$1" in
    --scope)
      require_value "$#" "--scope"
      # A JSON object of scope dimensions, e.g. '{"repo":"github.com/o/r"}'.
      # Unknown dimensions are rejected by the server rather than ignored.
      SCOPE="${2:-}"
      shift 2
      ;;
    --timeout)
      require_value "$#" "--timeout"
      TIMEOUT="${2:-$TIMEOUT}"
      shift 2
      ;;
    *)
      echo "usage: recall-batch.sh [--scope <json>] [--timeout <secs>] < questions.json" >&2
      exit 2
      ;;
  esac
done

if ! mm_ready; then
  echo "recall-batch: memory not configured or unreachable" >&2
  exit 1
fi

QUESTIONS="$(cat)"
[ -n "$QUESTIONS" ] || {
  echo "[]"
  exit 0
}

# Validate before sending. A malformed array would come back as a 400 the caller
# would have to interpret; failing here says which side was wrong.
if ! printf '%s' "$QUESTIONS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "recall-batch: stdin must be a JSON array of {id, question, options}" >&2
  exit 2
fi

if [ -n "$SCOPE" ] && ! printf '%s' "$SCOPE" | jq -e 'type == "object"' >/dev/null 2>&1; then
  echo "recall-batch: --scope must be a JSON object" >&2
  exit 2
fi

BODY="$(jq -cn --argjson qs "$QUESTIONS" --argjson sc "${SCOPE:-null}" \
  '{questions: $qs} + (if $sc == null then {} else {scope: $sc} end)')"

RESP="$(mm_post_read "/api/memory/decisions/recall_batch" "$BODY" "$TIMEOUT")"

if [ -z "$RESP" ] || ! printf '%s' "$RESP" | jq -e '.ok == true' >/dev/null 2>&1; then
  # The body is NOT logged. A failed call can still carry a partial Engram
  # payload — past decision text and the questions themselves — and this stderr
  # lands in session transcripts, which are themselves ingested. Size plus the
  # server's own error string (short, ours, no user content) is enough to tell
  # "unreachable" from "rejected"; set RECALL_BATCH_DEBUG=1 to see the body when
  # actually debugging.
  detail="$(printf '%s' "$RESP" | jq -r 'if type == "object" then (.error // .message // empty) else empty end' 2>/dev/null || true)"
  if [ -n "${RECALL_BATCH_DEBUG:-}" ]; then
    echo "recall-batch: request failed (${#RESP} bytes): ${RESP}" >&2
  else
    echo "recall-batch: request failed (${#RESP} bytes)${detail:+: $detail}" >&2
  fi
  exit 1
fi

printf '%s' "$RESP" | jq -c '.results // []'
