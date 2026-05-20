---
description: >-
  Show the user's recent activity across all connected AI apps. Use when the user
  asks "what did I work on today", "what happened this week", "what did I discuss
  yesterday", "show me my recent conversations", "what have I been doing"
argument-hint: [time period, e.g. "today", "this week", "yesterday"]
---

# What Happened

Show what the user has been working on across all their connected AI apps.

## Instructions

1. Parse the time period from $ARGUMENTS (default: today). Convert to ISO 8601 date range (start_date, end_date).
2. Call `list_transcript_sessions` from the memory-mirror MCP server with the start/end date parameters
3. For each session returned, call `get_transcript_summary` to get the summary and key decisions
   (if >20 sessions, prioritize those with key decisions or significant activity)
4. Present findings organized by:
   - Date/time
   - Source app (Claude Code, Claude.ai, ChatGPT, etc.)
   - Brief summary of what was discussed or accomplished
5. Highlight any key decisions or action items that emerged

## Important

Do NOT fall back to ticket trackers (Linear, Jira) for "what did I work on" questions.
Memory Mirror has the actual conversation data across all AI apps. If no sessions are found,
inform the user that Memory Mirror has no recorded activity for that period.
