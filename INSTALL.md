# Installing Memory Mirror on a customer machine

This plugin ships one authored **coding doctrine** into your Claude Code dev loop.
The doctrine runs **locally** — as advisory guardrail warnings on your tool calls —
and needs **no Mollow account and no API key**. (The cross-platform Memory features
are optional and layer on top; see the end.)

## What you receive

A single archive, `memory-mirror-plugin-<version>.tgz`, produced by Mollow's
packaging step (`scripts/package-plugin.sh`). It is a self-contained Claude Code
plugin *marketplace*:

```
memory-mirror-plugin/
  .claude-plugin/marketplace.json     ← the marketplace manifest
  memory-mirror/                       ← the plugin
    .claude-plugin/plugin.json
    hooks/…                            ← deterministic, offline guardrail hooks
    hooks/guardrail-predicates.json    ← the active authored doctrine (local)
    skills/…
```

The **local doctrine** path needs **no Mollow account, key, or URL**, and the
bundle carries **no credential and no monorepo-specific content** — the packaging
step strips the internal predicate file and the internal test fixtures and
sanitizes the shipped doctrine (see "The doctrine file" below). The optional
Memory features ship alongside it, so some of their code does reference Mollow's
MCP URL (`mollow.ai`); that path stays inert until you connect a Mollow account
(see the end).

## Prerequisites

- [Claude Code](https://claude.ai/code) 2.1.x or later.
- **`jq`** (a command-line JSON processor) on your `PATH`. The local doctrine gate
  parses your tool calls with `jq`; **without it the gate silently does nothing** —
  install still "succeeds", but you will never see a doctrine warning. Check first:

  ```bash
  command -v jq || echo "jq NOT found — the local doctrine gate will be inert until you install it"
  ```

  If it is missing, install it (`brew install jq`, `apt-get install jq`,
  `choco install jq`, …) before you rely on the doctrine warnings.

## Install

```bash
# 1. Unpack wherever you keep tools (not inside your project repo).
tar xzf memory-mirror-plugin-<version>.tgz
cd memory-mirror-plugin

# 2. Register this folder as a local marketplace.
claude plugin marketplace add .

# 3. Install the plugin from it.
claude plugin install memory-mirror@mollow
```

Restart Claude Code. From then on, when you run a tool call that trips a doctrine
rule (e.g. a force-push without a lease), Claude Code shows a short advisory note
and **proceeds** — the local doctrine is warn-only and never blocks your work.

### Verify it is live

```bash
echo '{"tool_name":"Bash","tool_input":{"command":"deploy --no-verify now"},"session_id":"check","cwd":"'"$PWD"'"}' \
  | bash memory-mirror/hooks/guardrails-gate.sh
```

You should see a JSON object with `additionalContext` naming the `--no-verify`
rule, and the command should exit `0`. No network call is made and no key is read.

## The doctrine file (`hooks/guardrail-predicates.json`)

This is the whole doctrine, as data. Each entry is a rule:

```json
{
  "id": "no-verify",
  "applies_to": ["Bash"],
  "target": "command",
  "pattern": "(^|\\s)--no-verify(\\s|$)",
  "message": "--no-verify bypasses your git hooks",
  "fix": "Let the pre-commit / pre-push checks run; skip them only deliberately."
}
```

- `applies_to`: `Bash`, `Write`, `Edit`, `MultiEdit`
- `target`: `command` | `file_path` | `content`
- `pattern`: a regular expression matched against the target text
- All rules are **warn-only** (advisory).

To change the doctrine, edit this file and restart Claude Code. To turn one rule
off, delete its entry. The gate reads the file on every tool call; a malformed or
missing file degrades to no local warnings — it never breaks the session.

You can also point the gate at a doctrine file elsewhere:

```bash
export MOLLOW_PORTABLE_PREDICATES_FILE=/path/to/your-doctrine.json
```

## Optional: cross-platform Memory

The plugin also carries skills and hooks for Mollow Memory — your memory of what
you have done across every AI you use. Those features need a free
[Mollow](https://mollow.ai) account. Until you connect one they do nothing
useful, though some may still surface an advisory reminder to save to Mollow
Memory (for example, a nudge at the end of a session); none of them block your
work, and the local doctrine above runs with no account regardless. See
`README.md` for the Memory feature set.

---

### For Mollow maintainers: building the bundle

```bash
# Stage + sanitize + validate structure, no tarball:
bash plugins/memory-mirror/scripts/package-plugin.sh --dry-run

# Build the shippable tarball:
bash plugins/memory-mirror/scripts/package-plugin.sh --out ./dist
```

The packaging step strips the monorepo-specific predicate shell
(`guardrail-predicates-mollow.sh`, per MOL-2182), activates the portable doctrine
(`guardrail-predicates.sample.json` → `guardrail-predicates.json`, unless a real
authored file from MOL-7974 is already staged there), runs the MOL-2182 sanitizer
as a hard release gate, and aborts the build on any violation.
