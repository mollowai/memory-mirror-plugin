---
description: >-
  Explicitly save something to the user's Memory Mirror. Use when the user says
  "remember this", "save this for later", "note that", "I want to remember",
  "store this preference", or asks you to persist any information
argument-hint: <what to remember>
---

# Remember

Save information to the user's Memory Mirror for use across future sessions and AI apps.

## Instructions

1. Parse what the user wants to remember from $ARGUMENTS or conversation context
2. Classify each item as one of: `knowledge`, `insight`, or `preference`
3. If multiple items, use `remember_batch` from the memory-mirror MCP server (more efficient)
4. If a single item, use `remember` from the memory-mirror MCP server
5. Confirm what was saved

## Classification

- **knowledge** — facts, decisions, architectural choices, how-tos, gotchas, constraints
- **insight** — patterns noticed, lessons learned, hypotheses, conclusions from debugging
- **preference** — user preferences for tools, style, workflow, communication, formatting
