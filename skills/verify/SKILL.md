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
| `verify`  | **Read-only.** Diff local entries vs `GET /api/memory/export` by content. Prints `N local / M present / K missing` (+ names). Exit 1 if anything is missing. |
| `push`    | Import local entries via `POST /api/memory/import` (server dedups). `--repair` pushes only what `verify` found missing. |

Target is resolved by precedence: `--env` > injected `$MOLLOW_MEMORY_URL`/`$MOLLOW_MEMORY_API_KEY` > `~/.mollow/selected-env` + keyfile > prod.

Scope flags (all commands): `--project <path>` (default cwd), `--dir <memory/ dir>` (unambiguous), `--all` (every project).

## Instructions

1. Run the requested command from the repo root, e.g.:

   ```bash
   python3 plugins/memory-mirror/scripts/memory_sync.py --all verify
   ```

   Default to `verify --all` when the user asks "is everything synced?".

2. Report the numbers plainly: how many local, how many present, how many
   missing — and name the missing ones.

3. If entries are missing, **do not silently push**. Some memories (e.g. a
   `financials`/business project) may be intentionally local — sending them to
   the cloud is the user's call. Confirm scope, then run `push --repair`
   (optionally scoped with `--dir`/`--project`) for the ones they approve.

4. To change which env is the target, use `scripts/fleet-target.sh <env>` — it
   keeps `selected-env`, `.envrc`, the workers, and `~/.claude.json` in sync.

## Notes

- Read-only `verify` never writes; `push` is idempotent (dedup is server-side).
- Which memories *should* sync is not yet user-configurable — that's MOL-2708.
