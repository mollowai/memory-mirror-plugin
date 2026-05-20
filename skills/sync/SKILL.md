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
2. Generate a session_id using the format: `{project_dir_name}-{YYYY-MM-DD}-{unix_timestamp}`
3. Call `sync_session_context` from the memory-mirror MCP server with a structured summary containing:
   - session_id (string)
   - summary (string): overview of work completed
   - decisions (array): key decisions with rationale
   - files_changed (array): list of modified files
   - lessons_learned (string): gotchas or insights
   - next_steps (string): open questions or future work
4. Confirm what was synced
5. If the sync fails (MCP server unreachable, auth required, or API error):
   - Inform the user of the failure reason
   - Suggest running `/connect` to configure the MCP connection
   - Offer to retry once the connection is established

## Note

This happens automatically when a session ends (via the Stop hook), but users can
trigger it manually at any point to checkpoint their progress mid-session.
