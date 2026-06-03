#!/usr/bin/env bash
set -euo pipefail
# Stop: the ingestion-backfill leg. Summarizing a whole session inherently needs
# the model, so this nudges Claude to call sync_session_context via the in-session
# mollow-memory MCP server. The deterministic capture-decision hook already
# persisted the discrete AskUserQuestion decisions in real time; this catches the
# free-form ones (lessons, rejected approaches) the real-time hook can't see.
#
# (Raw-transcript upload for fully model-free server-side extraction is a Phase-5
# follow-up.)

cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"Before ending this session: call sync_session_context from the mollow-memory MCP server with a structured summary — what was accomplished, key decisions (with rationale), files changed, and lessons learned — using the current project directory name + date as session_id. This backfills decisions the real-time capture hook could not see."}}
JSON
exit 0
