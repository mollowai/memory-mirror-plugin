---
description: >-
  Manually sync the current session to Memory Mirror. Use when the user says
  "sync session", "save session", "checkpoint", "persist this session",
  "upload session summary"
---

# Sync Session

Manually save the current session's context to Memory Mirror.

## Instructions

1. Analyze the current conversation for:
   - Summary of work completed
   - Key decisions made (with rationale)
   - Files changed
   - Lessons learned or gotchas encountered
   - Next steps or open questions
2. Generate a session_id from the current project directory name and date
3. Call `sync_session_context` from the memory-mirror MCP server with the structured summary
4. Confirm what was synced

## Note

This happens automatically when a session ends (via the Stop hook), but users can
trigger it manually at any point to checkpoint their progress mid-session.
