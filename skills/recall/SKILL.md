---
description: >-
  Search and retrieve from the user's Memory Mirror. Use when the user asks to
  recall something, search their memory, find a past decision, or asks
  "do you remember...", "what did we decide about...", "have I seen this before"
---

# Recall Memories

Search the user's Memory Mirror for past decisions, conversations, and knowledge.

## Instructions

1. Parse the user's query to understand what they're looking for
2. Call `search_memories` from the memory-mirror MCP server with relevant search terms
3. If the query is about a specific past conversation or session, also call `find_similar_conversations` with the query
4. If results are sparse, try `get_context` for a broader view of recent activity
5. Present findings clearly with when each memory was stored and from which source app

## When NOT to use

- For "what did I work on today/this week" questions, use `/memory-mirror:what-happened` instead
- For saving new memories, use `/memory-mirror:remember` instead
