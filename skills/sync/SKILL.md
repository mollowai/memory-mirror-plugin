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
2. Use this session's own id as session_id: the value of `$CLAUDE_CODE_SESSION_ID`
   (`echo "$CLAUDE_CODE_SESSION_ID"`). It is the id the transcript is ingested under,
   so a sync under it replaces any background summary the server already wrote for
   this session (MOL-7196). Only when it is unset, generate one as
   `{project_dir_name}-{YYYY-MM-DD}-{unix_timestamp}`. Save durable findings with
   `remember` before this call.
3. Call `sync_session_context` from the memory-mirror MCP server with a structured summary containing:
   - project (string): the project directory **basename** (`monorepo`), the same value
     `get_session_context(project:)` takes — never the repo URL. This is the scope the
     summary is filed under; dedupe is on `session_id`, so re-syncing the same summary
     does not move one filed at the wrong scope (MOL-5842). A changed summary replaces
     your earlier one (MOL-7196). Pass the repo identity as `repo` only
     when the project routes to a Space.
   - session_id (string)
   - summary (string): overview of work completed
   - decisions (array): key decisions with rationale
   - files_changed (array): list of modified files
   - lessons_learned (string): gotchas or insights
   - next_steps (string): open questions or future work
4. Confirm what was synced, quoting the `scope`, `destination` and `read_back_with` the response carries — the return value says the write landed and says nothing about whether it can be read back. `read_back_with` differs by container (a Space-routed summary is not in the workspace), so repeat the field rather than assuming the workspace call
5. If the sync fails (MCP server unreachable, auth required, or API error):
   - Inform the user of the failure reason
   - Suggest running `/connect` to configure the MCP connection
   - Offer to retry once the connection is established

## Note

This happens automatically when a session ends (via the Stop hook), but users can
trigger it manually at any point to checkpoint their progress mid-session.
