#!/usr/bin/env bash
set -euo pipefail
# Stop: the ingestion-backfill leg. Summarizing a whole session inherently needs
# the model, so this nudges Claude to call sync_session_context via the in-session
# mollow-memory MCP server. The deterministic capture-decision hook already
# persisted the discrete AskUserQuestion decisions in real time; this catches the
# free-form ones (lessons, rejected approaches) the real-time hook can't see.
#
# Stop hooks have no `additionalContext` channel (that's SessionStart/UserPrompt
# only). The way to hand the model an instruction at stop time is the root-level
# `decision: "block"` + `reason`: blocking the stop feeds `reason` back to Claude.
#
# (Raw-transcript upload for fully model-free server-side extraction is a Phase-5
# follow-up.)

input=$(cat)

# Re-entrancy guard: a blocking Stop hook re-fires after Claude responds. If this
# stop was itself triggered by a stop hook, let the session end instead of looping.
if command -v jq >/dev/null 2>&1; then
  if [ "$(printf '%s' "$input" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
    exit 0
  fi
else
  # Dependency-free fallback if jq is somehow absent.
  case "$input" in
    *'"stop_hook_active":true'* | *'"stop_hook_active": true'*) exit 0 ;;
  esac
fi

reason="Before ending this session: call sync_session_context from the mollow-memory MCP server with a structured summary — what was accomplished, key decisions (with rationale), files changed, and lessons learned — using the current project directory name + date as session_id. This backfills decisions the real-time capture hook could not see."

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg reason "$reason" '{decision: "block", reason: $reason}'
else
  printf '{"decision":"block","reason":"%s"}\n' "$reason"
fi
exit 0
