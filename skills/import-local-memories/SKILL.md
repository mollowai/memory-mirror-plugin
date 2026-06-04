---
description: >-
  Import this project's local Claude Code memories (the ~/.claude memory files)
  into the user's Mollow memory. Use when the user says "import my local
  memories", "sync my Claude Code memories", "pull in my memory files", or asks
  to get their file-based memories into Mollow / etch / engram.
argument-hint: "[--all] [--skip-ephemeral]"
---

# Import local Claude Code memories

Bring the user's local, file-based Claude Code memories
(`~/.claude/projects/<project>/memory/*.md` and `MEMORY.md`) into their Mollow
memory with full provenance, so they're searchable across every AI they use.

## Instructions

1. Run the bundled extractor to parse the local memory files into entries.
   Pass through any flags from `$ARGUMENTS` (e.g. `--all`, `--skip-ephemeral`):

   ```bash
   python3 "${CLAUDE_PLUGIN_ROOT}/scripts/extract-local-memories.py" --verbose $ARGUMENTS
   ```

   - Default: just this project. `--all` imports every project's memories.
   - `--skip-ephemeral` drops host-specific facts (IPs, socket paths, localhost ports).
   - stdout is a JSON array of entries; stderr is a one-line summary.

2. If the array is empty, tell the user there's nothing to import and stop.

3. Call the **`import_claude_memories`** tool from the `mollow-memory` MCP server,
   passing the parsed objects as `entries`. Each object already has its `content`
   and `type` set — **pass them through unchanged** (do not re-classify). If there
   are more than 50 entries, split into chunks of 50 and call the tool once per
   chunk.

4. Report a short summary from the tool results: how many were imported, how many
   were already saved (`deduped`), and how many superseded an earlier version.

## Notes

- **Idempotent**: re-running only adds new or changed memories; duplicates are
  skipped server-side.
- **Edits**: changing a memory file and re-importing supersedes the older version,
  so recall returns only the latest.
- The `import-local-memories` **hook** runs this automatically each session; this
  skill is the manual / on-demand path (and the one the hook nudges you to run
  when no API key is configured).
