---
description: >-
  Switch the Memory Mirror MCP server environment. Use when the user says
  "connect to staging", "use local", "switch to production", "connect to dev",
  or "memory mirror connect"
argument-hint: [environment: production, staging, or dev]
disable-model-invocation: true
---

# Connect to Memory Mirror

Switch which Memory Mirror environment this project connects to.

## Environments

| Name | URL |
|------|-----|
| `production` (default) | `https://mollow.ai/mcp/v2` |
| `staging` | `https://staging.mollow.ai/mcp/v2` |
| `dev` / `local` | `http://localhost:4000/mcp/v2` |

## Instructions

1. Parse the environment from $ARGUMENTS. If not provided, default to **production**:
   - **production** — live Memory Mirror (default for the plugin)
   - **staging** — staging environment
   - **dev** / **local** — local development server at localhost:4000

2. Find the plugin's own `.mcp.json` file. The skill's base directory is inside the plugin — resolve the plugin root by going up from the skill directory. The plugin `.mcp.json` is at `<plugin-root>/.mcp.json` (two levels up from this skill file: `../../.mcp.json` relative to the skill directory).

3. Read the plugin's `.mcp.json` and update the `memory-mirror` server URL to the chosen environment:
   ```json
   {
     "mcpServers": {
       "memory-mirror": {
         "type": "http",
         "url": "<chosen URL>"
       }
     }
   }
   ```

4. Tell the user to restart Claude Code for the change to take effect.

5. If the user chose `production`, restore the default URL (`https://mollow.ai/mcp/v2`). Mention that this is the plugin default.

## Important

- This edits the plugin's own `.mcp.json`, not the project-level one — plugin MCP servers are namespaced separately and cannot be overridden by project config
- The plugin directory may be a local path (during development via `--plugin-dir`) or inside Claude Code's plugin cache (after `plugin install`)
- After switching, the user will need to re-authenticate via OAuth for the new environment
