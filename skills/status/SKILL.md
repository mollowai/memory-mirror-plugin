---
description: >-
  Check Memory Mirror connection and stats. Use when the user asks about their
  memory status, connection health, memory count, or wants to verify memory is
  working. Triggers on "memory status", "is memory connected", "how many memories"
---

# Memory Mirror Status

Check the connection and status of the user's Memory Mirror.

## Instructions

1. Call `memory_stats` from the memory-mirror MCP server to get record counts
2. Call `check_mcp_connection_status` from the memory-mirror MCP server
3. Call `list_connected_sources` from the memory-mirror MCP server
4. Present a summary:
   - Connection status
   - Total memories stored (by type)
   - Connected AI sources (Claude Code, Claude.ai, ChatGPT, etc.)
