#!/usr/bin/env bash
# install.sh — enable the memory-mirror Claude Code hooks for the current user.
#
# One command for a teammate to turn on Memory grounding: merges the NO-GATE
# recall / grounding / capture / sync hooks into ~/.claude/settings.json,
# preserving any hooks already there. Idempotent — re-running adds only what is
# missing. Pass --with-gates to ALSO install the PreToolUse guardrails gate
# (blocking citation-discipline enforcement); the default is gate-free.
#
# Usage:
#   bash plugins/memory-mirror/install.sh [--with-gates]
#
# After it runs: restart Claude Code (hooks load at startup).
set -euo pipefail

WITH_GATES=0
case "${1:-}" in
  --with-gates) WITH_GATES=1 ;;
  "") ;;
  *) echo "usage: install.sh [--with-gates]" >&2; exit 2 ;;
esac

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOKS_DIR="$ROOT/plugins/memory-mirror/hooks"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"

command -v python3 >/dev/null 2>&1 || { echo "python3 is required" >&2; exit 1; }

# --- advisory key check (never blocks the install) ---
if ( set -a; [ -f "$ROOT/.envrc" ] && . "$ROOT/.envrc" >/dev/null 2>&1 || true; set +a
     . "$HOOKS_DIR/_common.sh" >/dev/null 2>&1; mm_ready >/dev/null 2>&1 ); then
  echo "✓ memory key found in this shell."
  echo "  NOTE: the hooks run inside Claude Code's OWN environment, not this shell. If you"
  echo "  launched Claude Code without these exports loaded (no direnv / .envrc sourced), the"
  echo "  hooks will silently no-op. After restart, confirm with the check in the skill."
else
  echo "⚠ MOLLOW_MEMORY_API_KEY not resolving yet — the hooks will no-op until it is set."
  echo "  Add YOUR OWN personal-workspace key to your env (e.g. $ROOT/.envrc):"
  echo "    export MOLLOW_MEMORY_URL=https://mollow.ai/mcp/v2"
  echo "    export MOLLOW_MEMORY_API_KEY=<your mol_ workspace key>"
fi

python3 - "$SETTINGS" "$HOOKS_DIR" "$WITH_GATES" <<'PY'
import json, os, shlex, sys, time

settings_path, hooks_dir, with_gates = sys.argv[1], sys.argv[2], sys.argv[3] == "1"

def cmd(script):
    # Quote the path so a checkout under a directory with spaces still works.
    return f"bash {shlex.quote(os.path.join(hooks_dir, script))}"

# (event, matcher-or-None, [(script, timeout_seconds), ...]) — the NO-GATE set.
groups = [
    ("SessionStart", None, [("load-decision-profile.sh", 6), ("import-local-memories.sh", 10)]),
    ("UserPromptSubmit", None, [("recall-decisions.sh", 20), ("supply-ground.sh", 20)]),
    ("PostToolUse", "AskUserQuestion", [("capture-decision.sh", 6)]),
    ("PostToolUse", "mcp__mollow__get_session_context", [("grounding-receipt.sh", 5)]),
    ("Stop", None, [("sync-session.sh", 5), ("supply-stop.sh", 5),
                    ("record-sweep-decisions.sh", 6), ("grounding-engagement.sh", 5)]),
]
if with_gates:
    groups += [
        ("SessionStart", None, [("arm-guardrails.sh", 6)]),
        ("PreToolUse", "Bash|Write|Edit|MultiEdit", [("guardrails-gate.sh", 5)]),
    ]

try:
    with open(settings_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    print("settings.json is not a JSON object — aborting, nothing changed", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})

def present(event, script):
    for grp in hooks.get(event, []):
        for h in grp.get("hooks", []):
            if script in h.get("command", ""):
                return True
    return False

added = []
for event, matcher, scripts in groups:
    # Idempotent PER SCRIPT: add only the scripts not already wired on this event,
    # so a partial prior install is completed rather than skipped wholesale.
    missing = [(s, t) for s, t in scripts if not present(event, s)]
    if not missing:
        continue
    hook_list = [{"type": "command", "command": cmd(s), "timeout": t} for s, t in missing]
    group = {"matcher": matcher, "hooks": hook_list} if matcher is not None else {"hooks": hook_list}
    hooks.setdefault(event, []).append(group)
    label = event + (f"[{matcher}]" if matcher else "") + ": " + ", ".join(s for s, _ in missing)
    added.append(label)

if not added:
    print("✓ already installed — no changes.")
    sys.exit(0)

if os.path.exists(settings_path):
    bak = f"{settings_path}.bak-{time.strftime('%Y%m%d-%H%M%S')}"
    with open(settings_path) as f, open(bak, "w") as b:
        b.write(f.read())
    print(f"  (backup written: {bak})")
else:
    d = os.path.dirname(settings_path)
    if d:
        os.makedirs(d, exist_ok=True)

with open(settings_path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")

print("✓ installed memory-mirror hooks" + (" (with gates)" if with_gates else " (no gates)") + ":")
for a in added:
    print("   + " + a)
print("→ restart Claude Code to activate. Decision recall, decision-capture and session")
print("  sync are live on restart. (supply-ground is installed too, but only grounds when")
print("  supply mode is enabled via ~/.mollow/supply-mode — it no-ops otherwise.)")
PY
