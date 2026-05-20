# Memory Mirror — Claude Code Plugin

Cross-platform AI memory by [Mollow](https://mollow.ai). Remembers your decisions, preferences, and work patterns across Claude Code, Claude.ai, ChatGPT, and every AI you use.

## What it does

Memory Mirror gives Claude Code persistent memory that works across sessions and across every AI app you connect. When you install this plugin:

- **Session lifecycle is automatic** — your memory context loads at the start of every session, and a summary is saved when you're done
- **Context compression is safe** — before Claude compresses old messages, important decisions and insights are saved to your memory
- **Your past work is searchable** — ask "what did I work on yesterday?" and get answers from every AI app you've used, not just the current session

## Install

```
/plugin install memory-mirror
```

On first use, Claude Code will open your browser to sign in to your Mollow account. After that, authentication is automatic.

## Skills

| Skill | What it does |
|-------|-------------|
| `/memory-mirror:recall` | Search your memory for past decisions, conversations, and knowledge |
| `/memory-mirror:remember` | Explicitly save something for future sessions |
| `/memory-mirror:what-happened` | Show your recent activity across all connected AI apps |
| `/memory-mirror:status` | Check connection health and memory stats |
| `/memory-mirror:sync` | Manually checkpoint the current session |
| `/memory-mirror:connect` | Switch between production, staging, and local dev environments |

## Hooks

The plugin automatically handles session lifecycle:

- **SessionStart** — loads your memory context (skills, recent sessions, project memories)
- **PreCompact** — saves unsaved decisions before context compression
- **Stop** — saves a session summary when you're done

## How it works

The plugin connects to the Memory Mirror MCP server, which stores and retrieves your memories. All 40+ MCP tools are available to Claude — the skills above are shortcuts for the most common workflows.

Memory Mirror learns from your conversations across platforms:

1. **Observations** — patterns detected in your conversations
2. **Hypotheses** — repeated patterns elevated for validation
3. **Skills** — confirmed patterns that inform future sessions

## Environments

The plugin connects to production by default. To switch environments:

```
/memory-mirror:connect staging
/memory-mirror:connect dev
/memory-mirror:connect production
```

This writes a project-level `.mcp.json` override. Restart Claude Code after switching.

## Requirements

- [Claude Code](https://claude.ai/code) installed
- A [Mollow](https://mollow.ai) account (free to create)

## Development

Test locally during development:

```bash
claude --plugin-dir ./memory-mirror-plugin
```

Validate the plugin structure:

```bash
claude plugin validate
```

## License

MIT
