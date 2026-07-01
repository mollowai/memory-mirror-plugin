# Memory Mirror — Claude Code Plugin

Cross-platform AI memory by [Mollow](https://mollow.ai). Remembers your decisions, preferences, and work patterns across Claude Code, Claude.ai, ChatGPT, and every AI you use. Private. Portable. Tamper-proof.

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
| `/memory-mirror:import-local-memories` | Import your local Claude Code memory files (`~/.claude/projects/<project>/memory/`) into Mollow, with full provenance |
| `/memory-mirror:what-happened` | Show your recent activity across all connected AI apps |
| `/memory-mirror:status` | Check connection health and memory stats |
| `/memory-mirror:sync` | Manually checkpoint the current session |
| `/memory-mirror:verify` | Prove which local memory files are present in Mollow (read-only diff), and repair what's missing |
| `/memory-mirror:connect` | Switch between production, staging, and local dev environments |

## Hooks

The plugin automatically handles session lifecycle:

- **SessionStart** — loads your memory context (skills, recent sessions, project memories), and syncs this project's local Claude Code memory files into Mollow when they change (silently if a `mol_*` API key is configured, otherwise it nudges you to run `/memory-mirror:import-local-memories`)
- **PreCompact** — saves unsaved decisions before context compression
- **Stop** — saves a session summary when you're done

Claude Code's own file-based memories (`~/.claude/projects/<project>/memory/*.md` and `MEMORY.md`) become first-class Mollow memories — searchable across every AI you use — with their original kind, description, and source preserved. Re-importing an edited memory supersedes the older version.

## How it works

The plugin connects to the Memory Mirror MCP server, which stores and retrieves your memories. All 40+ MCP tools are available to Claude — the skills above are shortcuts for the most common workflows.

Memory Mirror learns from your conversations across platforms:

1. **Noted quietly** — a pattern appears once and Mollow notes it in the background
2. **Surfaced** — the pattern shows up again and Mollow surfaces it as something it's noticing
3. **Established** — it keeps showing up, so Mollow treats it as established and adds it to your Mirror

## Environments

The plugin connects to production by default. To switch environments:

```
/memory-mirror:connect staging
/memory-mirror:connect dev
/memory-mirror:connect production
```

This writes a project-level `.mcp.json` override. Restart Claude Code after switching.

## Verifying & repairing local sync

The SessionStart hook records a project as `synced` on HTTP success, keyed by
`(env, project)` — but if you want to *prove* your local memory files reached
Mollow (e.g. before shrinking or deleting them), use the `memory-sync` tool
directly. It diffs local content against `GET /api/memory/export`, so it reports
what's actually in the cloud rather than trusting local state.

```bash
# Is everything, across every project, present in the current target env?
python3 plugins/memory-mirror/scripts/memory_sync.py --all verify

# Where am I pointed, and do the three config sources agree?
python3 plugins/memory-mirror/scripts/memory_sync.py status

# Push only the entries verify found missing (scope with --dir/--project/--all).
python3 plugins/memory-mirror/scripts/memory_sync.py --all push --repair
```

`verify` is read-only and exits non-zero when anything is missing (usable in a
hook or CI). `push` is idempotent — the server dedups. Target resolution
precedence: `--env` > injected `$MOLLOW_MEMORY_URL`/`$MOLLOW_MEMORY_API_KEY` >
`~/.mollow/selected-env` + keyfile > prod.

**Note:** every local memory currently syncs. Per-project / per-memory opt-out
(so business/financial notes can stay local) is tracked in MOL-2708.

To switch which env everything reports to — `selected-env`, `.envrc`, the
workers, and `~/.claude.json`'s `mollow-memory` MCP URL, all at once — use
`scripts/fleet-target.sh <dev|staging|prod>`.

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
