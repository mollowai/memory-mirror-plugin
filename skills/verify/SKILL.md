---
description: >-
  Verify that the local Claude Code memory files are actually present in the
  user's Mollow instance, and repair any that are missing. Use when the user
  asks "did my memories sync", "are my memories in prod/staging", "verify memory
  sync", "what's missing from Mollow", or before shrinking/deleting local memory
  files. Read-only by default.
argument-hint: "[status|verify|push] [--env prod|staging|dev] [--all]"
---

# Verify local memory sync

Prove which local Claude Code memories (`~/.claude/projects/<slug>/memory/*.md`)
are — and are not — present in the user's Mollow instance, and push the missing
ones on request. This is the trustworthy answer to "is everything synced?": it
diffs local content against the cloud, rather than trusting the hook's local
`synced` fingerprint (which records HTTP success, not confirmed remote presence).

## Tool

`plugins/memory-mirror/scripts/memory_sync.py` — dependency-free, curl-backed.

| Command | Effect |
|---|---|
| `status`  | Target env, config agreement across the 3 sources of truth (selected-env / injected env / `.claude.json` MCP), remote counts, local entry count. |
| `verify`  | **Read-only.** Diff local entries vs `GET /api/memory/export` by content. Prints `N local / M present / K missing` (+ names). Exit 1 if anything is missing; **exit 3 if the scope routes to a Space**, which this export cannot see. |
| `push`    | Import local entries via `POST /api/memory/import` (server dedups). `--repair` pushes only what `verify` found missing, and takes `--dir` (one project, unrouted) — not `--all`, which uploads every project, and not `--project`, which exits 3. Use `--project` with a plain `push` to route to a Space. See below. |

Target is resolved by precedence: `--env` > injected `$MOLLOW_MEMORY_URL`/`$MOLLOW_MEMORY_API_KEY` > `~/.mollow/selected-env` + keyfile > prod.

Scope flags (all commands): `--project <path>` (default cwd), `--dir <memory/ dir>` (unambiguous), `--all` (every project).

**Only a single-project scope can route a push.** `repo` is the destination map's
key and is stamped on every extracted entry, so `--all` (every project) and
`--dir` (a memory dir whose slug cannot be inverted to its project) have no single
right answer. Rather than route another project's memories into this repo's
shared Space, `push` sends them unrouted — they land in the **private workspace**
— and prints a `routing:` line saying so. Read that line: `count: {ok, deduped,
error}` looks identical either way. `verify --all` is unaffected, because its diff
keys on `content`. (MOL-6187; before it, `push` never passed `--repo` at all.)

## Instructions

1. Run the requested command from the repo root, e.g.:

   ```bash
   python3 plugins/memory-mirror/scripts/memory_sync.py --all verify
   ```

   Default to `verify --all` when the user asks "is everything synced?".

2. Report the numbers plainly: how many local, how many present, how many
   missing — and name the missing ones.

3. If entries are missing, **do not silently push**. Some memories (e.g. a
   `financials`/business project) may be intentionally local — sending them to the
   cloud is the user's call.

   **Before repairing anything, establish that the project does not route to a
   Space.** `verify`'s "missing" cannot distinguish *absent* from *present in a
   Space*: `/api/memory/export` is workspace-scoped
   (`memory_export_controller.ex:174-178`) and does not return Space channels. So
   repairing a routed project's apparent absence imports fresh copies with no
   `repo` — a second, **private** copy beside the Space one. It repairs a phantom.

   The tool cannot check this for you and says so on every `--repair` run. `--dir`'s
   slug is not invertible, so the project cannot be identified to ask whether it
   routes, and the destination map is not exposed to clients regardless.

   | If the project… | do this |
   |---|---|
   | does **not** route (maps to no Space) | `--dir <that project's memory dir> push --repair` — one project, unrouted, so the export reads exactly where the entries land |
   | **does** route to a Space | **there is no repair path today.** Confirm individual entries with `verify_stored_memory`, using a hash from the file every `push` now writes (see below) |

   Never pair `--repair` with `--all` (uploads every project, so it cannot honour
   an approval) or with `--project` (routes, so it exits 3).

   On a routed `push`, read the `routing:` line it prints: `resolved —
   github.com/owner/name` means the entries carry their destination key, and no
   count in the response body distinguishes that from a private landing.

   **Reading one back.** Every `push` writes the per-entry hashes the import returned
   under `~/.mollow/` and prints the absolute path (the `HASHES_PATH` constant in
   `plugins/memory-mirror/scripts/memory_sync.py`):

   ```
     hashes: 48 written to <path printed here>
             pass any `message_hash` to verify_stored_memory to confirm that row landed
   ```

   Pass one to `mcp__mollow-memory__verify_stored_memory`. **Be precise about what
   that answers:**

   | it establishes | it does NOT establish |
   |---|---|
   | the row exists in Mollow, with its content intact | **where the row landed** |

   The lookup is **global by hash and deliberately unscoped** — `get_message_by_hash/1`
   is documented "globally (NOT channel-scoped)" (`webapp/lib/mollow/etch.ex:1603-1613`),
   because provenance verification is a third-party operation. So `verified: true` is
   returned just the same for an entry that fell back to the private workspace as for
   one that reached its Space. It is a presence-and-integrity check, not a placement
   check.

   **To confirm placement there is one check, and it only works in one direction.**
   With a **Space-scoped credential** (a Space `mol_*` key, or an OAuth token carrying
   `space:<uuid>`), `search_memories` "searches that Space's memory channel only"
   (`webapp/lib/mollow/mcp/memory_tools.ex:278`) and each result carries a
   `message_hash` (`:2596`). A result whose hash matches one from the push is
   **positive evidence the row is in that Space**.

   A miss is **not** evidence of absence: measured 2026-09-26, a known-landed row came
   back absent from `search_memories`. Its silence says nothing, so treat only a hash
   match as informative. Read the `routing:` line as "the entries carried a `repo`",
   never as "they arrived".

   **Query with the author's own words** — not because the search is literal-only, but
   because that is the one phrasing both legs can match. Space search is hybrid,
   `vector ∪ literal` (`search_memories_space/2`,
   `webapp/lib/mollow/mcp/memory_tools.ex:4531`, MOL-4777), so a paraphrase normally
   reaches the corpus — but the vector leg is not guaranteed: on an embedding failure
   `Mollow.Spaces.search_messages/5` degrades to the literal leg rather than to empty
   (`webapp/lib/mollow/spaces.ex:2838-2851`, *"A dead embedding leg degrades to the
   literal leg rather than to empty"*), silently. A paraphrase can therefore miss a row
   that is present, which makes literal wording the safer input for a check whose only
   informative outcome is a match.

   The `search_memories` *tool description* at `:278` still claims literal-only matching
   and that a paraphrase "returns nothing there". That text predates MOL-4777 and is
   stale — right about the degraded case by accident, wrong about the normal one.

   With a workspace-scoped credential there is no placement check at all — and that is
   the same gap that makes `--repair` unsafe for a routed project: the import does not
   report the destination it chose, and the destination map is not exposed. Closing it
   properly needs a server change.

   The hashes file is overwritten by the next `push`, so read it before re-running.

4. To change which env is the target, use `scripts/fleet-target.sh <env>` — it
   keeps `selected-env`, `.envrc`, the workers, and `~/.claude.json` in sync.

## Notes

- Read-only `verify` never writes; `push` is idempotent (dedup is server-side).
- Which memories *should* sync is not yet user-configurable — that's MOL-2708.
