#!/usr/bin/env bash
set -euo pipefail
# Stop: the ingestion-backfill leg. Summarizing a whole session inherently needs
# the model, so this nudges Claude to call sync_session_context via the in-session
# mollow-memory MCP server. The deterministic capture-decision hook already
# persisted the discrete AskUserQuestion decisions in real time; this catches the
# free-form ones (lessons, rejected approaches) the real-time hook can't see.
#
# This is a NON-BLOCKING reminder: it emits a top-level `systemMessage` and exits
# 0, so the stop is never blocked (no "Stop hook error" framing). The reminder is
# surfaced to the user, not fed back to the model, so the sync is no longer forced
# — Claude calls sync_session_context only when it chooses to.
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

# Nudge at most ONCE per session. A Stop hook runs on every natural stop, so without
# state this would surface the reminder on every single turn. After we nudge once we
# drop a per-session marker; later stops for the same session see it and stay quiet.
# We can't tell
# whether the model actually called sync_session_context (a bash hook can't see MCP
# calls), so "nudged once" is the contract — one reminder, then out of the way.
session_id=""
state_dir=""
marker=""
if command -v jq >/dev/null 2>&1; then
  session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
fi
# Only dedupe on a session id we can safely turn into a filename (path-traversal
# guard). Without a usable id, fall back to always-nudge rather than going silent.
if [ -n "$session_id" ] && [[ "$session_id" =~ ^[A-Za-z0-9._-]+$ ]]; then
  state_dir="${TMPDIR:-/tmp}/mollow-memory-sync"
  marker="${state_dir}/${session_id}.nudged"
  [ -f "$marker" ] && exit 0
fi

reason="Reminder: call sync_session_context (mollow-memory MCP) before ending — summarize what was accomplished, key decisions, files changed, and lessons, using the project dir name + date as session_id."

# Record the nudge before emitting it so a follow-up stop won't repeat it. Best-
# effort: if the marker can't be written we still nudge (a repeat reminder beats
# a dropped one), staying true to the fail-safe contract.
if [ -n "$marker" ]; then
  mkdir -p "$state_dir" 2>/dev/null && : >"$marker" 2>/dev/null || true
fi

if command -v jq >/dev/null 2>&1; then
  jq -cn --arg reason "$reason" '{systemMessage: $reason}'
else
  printf '{"systemMessage":"%s"}\n' "$reason"
fi
exit 0
