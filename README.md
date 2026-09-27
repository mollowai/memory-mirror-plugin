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

## What the plugin writes, and where

The hooks read your files and add context to Claude's prompt. They write nothing into your working tree: no hook creates or changes a file or directory in your repository, so installing the plugin leaves `git status` as it was. The one exception is removal of files an earlier version left behind, described at the end of this section.

What the plugin keeps on disk lives in your home directory or the system temp directory:

- `~/.mollow/` — sync state (which local memory files have been sent), which advisories have already been shown, and a per-session marker at `~/.mollow/tdd-armed/<repo>/<session>.json` when your Mollow memory records a test-first preference. A marker no session has used for 14 days is deleted when a new session arms.
- The system temp directory (`$TMPDIR`, else `/tmp`) — session sync state under `mollow-memory-sync/`, and grounding receipts under `mollow-supply/<session>/` when supply mode is on.

One file in your repository changes what the plugin does, and only if you create it:

- `tmp/.skip-tdd` — from the repository root, create it (`mkdir -p tmp && touch tmp/.skip-tdd`) to let edits through the test-first check. The plugin reads it and never creates or deletes it.

**Earlier versions wrote into the repository.** Versions before 1.1.0 created `tmp/.tdd-armed-<session>.json`, and `tmp/` itself when it was absent. At session start the current version deletes such a file only when all of these hold: git does not track it, it is a regular file rather than a symlink, and its content is exactly the marker those versions wrote. It never follows a `tmp/` that is a symlink. It deletes `tmp/` only when it removed a marker and that left the directory empty. Your own files in `tmp/`, including `.skip-tdd`, are left alone.

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

This edits the plugin's own `.mcp.json` in the plugin's install directory, not a file in your project. Restart Claude Code after switching.

## Verifying & repairing local sync

The SessionStart hook records a project as `synced` on HTTP success, keyed by
`(env, project)` — but if you want to *prove* your local memory files reached
Mollow (e.g. before shrinking or deleting them), use the `memory-sync` tool
directly. It diffs local content against `GET /api/memory/export`, so it reports
what's actually in the cloud rather than trusting local state.

```bash
# Is everything, across every project, present in the current target env?
python3 plugins/memory-mirror/scripts/memory_sync.py --all verify

# Where am I pointed, do the three config sources agree, and will entries route?
python3 plugins/memory-mirror/scripts/memory_sync.py status

# Repair ONE project that you know does NOT route to a Space. Read the section below
# before running this — on a routed project it creates private duplicates.
python3 plugins/memory-mirror/scripts/memory_sync.py \
  --dir ~/.claude/projects/-Users-me-dev-myrepo/memory push --repair

# Route this project's memories to its Space. No --repair — see below.
python3 plugins/memory-mirror/scripts/memory_sync.py --project "$(git rev-parse --show-toplevel)" push
```

### `--repair` has a precondition the tool cannot check

`/api/memory/export` is **workspace-scoped**
(`memory_export_controller.ex:174-178`), so it does not return Space channels. That
means `verify`'s "missing" cannot distinguish *absent* from *present in a Space* —
and repairing a routed project's apparent absence imports fresh copies carrying no
`repo`, landing a second **private** copy beside the Space one. It repairs a phantom.

Nothing client-side can rule this out: `--dir`'s slug is not invertible, so the
project cannot be identified to ask whether it routes, and the destination map is not
exposed. So `--repair` prints the precondition on every run instead of implying it
holds.

| If the project… | do this |
|---|---|
| does **not** route to a Space | `--dir <its memory dir> push --repair`. One project, unrouted, so the export reads exactly where the entries land |
| **does** route | **no repair path today**, and no placement check either — see below |

Every `push` writes the per-entry hashes the import returned under `~/.mollow/` and
**prints the absolute path** (the `HASHES_PATH` constant in
`plugins/memory-mirror/scripts/memory_sync.py`). Pass one to `verify_stored_memory`:
`verified: true` means that row **exists in Mollow with its content intact**.

**It does not mean the row reached its Space.** The lookup is global by hash and
deliberately unscoped — `get_message_by_hash/1` is documented "globally (NOT
channel-scoped)" (`webapp/lib/mollow/etch.ex:1603-1613`), since provenance
verification is a third-party operation — so it returns `verified: true` just the same
for an entry that fell back to the private workspace. Presence and integrity, not
placement.

**One placement check exists, and only in one direction.** With a **Space-scoped
credential** (a Space `mol_*` key, or an OAuth token carrying `space:<uuid>`),
`search_memories` "searches that Space's memory channel only"
(`webapp/lib/mollow/mcp/memory_tools.ex:278`) and each result carries a `message_hash`
(`:2596`) — so a result matching a hash from the push is **positive evidence the row is
in that Space**.

A miss proves nothing: measured 2026-09-26, a known-landed row came back absent from
`search_memories`. Treat only a match as informative.

**Query with the author's own words** — not because the search is literal-only, but
because that is the phrasing both legs can match. Space search is hybrid, `vector ∪
literal` (`search_memories_space/2`, `webapp/lib/mollow/mcp/memory_tools.ex:4531`,
MOL-4777), so a paraphrase normally reaches the corpus — but the vector leg is not
guaranteed: on an embedding failure `Mollow.Spaces.search_messages/5` degrades to the
literal leg rather than to empty (`webapp/lib/mollow/spaces.ex:2838-2851`), silently. So
a paraphrase can miss a row that is present.

The `search_memories` *tool description* at `:278` still says literal-only and that a
paraphrase "returns nothing there"; that text predates MOL-4777 and is stale — right
about the degraded case by accident, wrong about the normal one.

With a workspace-scoped credential there is no placement check at all. Read the
`routing:` line as "the entries carried a `repo`", never as "they arrived". Closing the
gap properly needs the import to report the destination it chose — the same change that
would make `--repair` safe for a routed project.

The hashes file is overwritten by the next `push`.

Never pair `--repair` with `--all` (uploads every project, so it cannot honour an
approval) or `--project` (routes, so it exits 3). Closing the gap properly needs the
import to report the destination it chose; that is not built.

`verify` is read-only and exits non-zero when anything is missing (usable in a
hook or CI). `push` is idempotent — the server dedups. Target resolution
precedence: `--env` > injected `$MOLLOW_MEMORY_URL`/`$MOLLOW_MEMORY_API_KEY` >
`~/.mollow/selected-env` + keyfile > prod.

### Push per project, or the entries land in the private workspace

**Only a single-project scope can route.** `repo` is the destination map's key,
and `--repo` is stamped on *every* extracted entry — so `--all` (which spans
every project under the root) and `--dir` (which names a memory directory whose
slug cannot be inverted to its project) have no single right answer. Rather than
guess and route another project's memories into this repo's shared, undeletable
Space, `push` sends them with no `repo` and **says so**:

```
routing: unresolved — --all spans every project, so no single `repo` can be
  stamped; entries land in the private workspace. Re-run per project
  (--project <repo-checkout>) to route them
```

Read that line. It is the one thing about a push the response body cannot tell
you — `count: {ok, deduped, error}` looks identical whether the rows reached
their Space or the private workspace. Until MOL-6187 `push` never passed `--repo`
at all, so *every* entry it had ever sent landed private while reporting success.

`--all verify` is unaffected: its diff keys on `content`, which `--repo` never
touches.

### `verify` and `--repair` refuse a routed scope

`GET /api/memory/export` is **workspace-scoped** —
`memory_export_controller.ex:174-178` filters `where: c.workspace_id ==
^workspace_id`. A routed entry lands in a Space channel that query cannot return,
so diffing against the export would report every correctly-routed entry as
missing, and `--repair` would re-send the whole corpus on every run.

So both refuse, with **exit 3** (distinct from `1` = genuinely missing and `0` =
all present, because a confident wrong number is the thing being avoided):

```
memory-sync: cannot repair a routed scope.
  Entries carry repo=github.com/mollowai/monorepo, so they land in that project's Space, but
  GET /api/memory/export is WORKSPACE-scoped …
```

A plain `push` (no `--repair`) is unaffected — the import routes on `repo` and needs
no read-back. Read-back for a routed entry needs `verify_stored_memory` with a
`message_hash` the import returned.

**The refusal is deliberately conservative.** A resolved `repo` means the entries
*can* route, not that they do: `memory_destinations` is keyed `(user_id, repo)` and
most projects have no row, so an unmapped project's entries land in the private
workspace where the export would have seen them. Nothing client-side can tell the
two apart — the destination map is not exposed and the import response does not say
where a row went. So the trade is a false refusal against a false "N missing", and
only the latter gets acted on by `--repair`. Use `--all` if you need the export path
for such a project. Narrowing it properly needs the server to report the
destination it chose; that is not built.

### A timed-out chunk

A push whose chunks time out prints `reposted: N`. A gateway 524 means the proxy
stopped waiting, not that nothing landed (measured: a 524 at 125 s, and a re-post
returned `deduped`), so each chunk is re-posted once.

**What the re-post establishes is that the rows are present now** — not which
attempt landed them. `deduped` only says the content hash is already stored, which
an earlier sync could equally explain, so it cannot be read as proof the timed-out
call committed.

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
