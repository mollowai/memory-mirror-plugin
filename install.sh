#!/usr/bin/env bash
# install.sh — enable the mollow-claude Claude Code hooks for the current user.
#
# One command for a teammate to turn on Memory grounding: merges the NO-GATE
# recall / grounding / capture / sync hooks into ~/.claude/settings.json,
# preserving any hooks already there. Idempotent — re-running adds only what is
# missing. Pass --with-gates to ALSO install the PreToolUse guardrails gate
# (blocking citation-discipline enforcement); the default is gate-free.
#
# Usage:
#   bash plugins/mollow-claude/install.sh [--with-gates]
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
HOOKS_DIR="$ROOT/plugins/mollow-claude/hooks"
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

# --- stage the Slack register gate OUTSIDE the checkout ------------------------
#
# Every other hook here is registered by its path inside this checkout, which is
# correct for them: they are useful exactly when you are working in this
# repository. The register gate is not. Its whole purpose is to hold on a
# checkout whose branch does not carry it — the case that created it is a
# long-lived branch thousands of commits behind main, where the gate file is
# absent and the registered command resolves to nothing. A hook
# whose command is missing does not fail loudly; it does nothing, which is
# indistinguishable from a post that passed.
#
# So this one is COPIED to a user-owned directory and registered from there.
# Layout is preserved on purpose: the gate finds its library at lib/ beside it,
# and the library finds the channel register one level up from itself.
#
# The trade is staleness — the copy does not follow the checkout, so re-run this
# installer to refresh it. That is the right way round for a gate: a slightly
# old rule still runs, where a missing one is silence.
STAGE_DIR="${MOLLOW_HOOK_STAGE_DIR:-$HOME/.mollow/claude-hooks/messages-to-humans}"
STAGED_HOOKS_DIR=""
if [ -f "$HOOKS_DIR/slack-register-gate.sh" ] && [ -f "$HOOKS_DIR/lib/slack-register-decision.sh" ]; then
  if mkdir -p "$STAGE_DIR/lib" 2>/dev/null      && cp "$HOOKS_DIR/slack-register-gate.sh" "$STAGE_DIR/" 2>/dev/null      && cp "$HOOKS_DIR/lib/slack-register-decision.sh" "$STAGE_DIR/lib/" 2>/dev/null; then
    # The register is optional and is not shipped publicly. Copy it when this
    # checkout has one; its absence leaves the gate with no opinion by design.
    if [ -f "$HOOKS_DIR/channel-register.json" ]; then
      cp "$HOOKS_DIR/channel-register.json" "$STAGE_DIR/" 2>/dev/null || true
    fi
    chmod +x "$STAGE_DIR/slack-register-gate.sh" 2>/dev/null || true
    STAGED_HOOKS_DIR="$STAGE_DIR"
    echo "✓ staged the messages-to-humans gate at $STAGE_DIR"
    echo "  It runs from there, so switching this checkout's branch cannot remove it."
    echo "  Re-run this installer after pulling to refresh the copy."
  else
    echo "⚠ could not stage the messages-to-humans gate — registering it from the checkout"
    echo "  instead, which means it stops running on a branch that does not carry it."
  fi
fi

python3 - "$SETTINGS" "$HOOKS_DIR" "$WITH_GATES" "$STAGED_HOOKS_DIR" <<'PY'
import json, os, shlex, sys, time

settings_path, hooks_dir, with_gates = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
staged_dir = sys.argv[4] if len(sys.argv) > 4 else ""

# Scripts that must keep running on a checkout whose branch does not carry
# them, so they are registered from the staged copy when one exists. Everything
# else stays pinned to the checkout, where it belongs.
STAGED_SCRIPTS = {"slack-register-gate.sh"}

def cmd(script):
    # Quote the path so a checkout under a directory with spaces still works.
    base = staged_dir if (script in STAGED_SCRIPTS and staged_dir) else hooks_dir
    return f"bash {shlex.quote(os.path.join(base, script))}"

# (event, matcher-or-None, [(script, timeout_seconds), ...]) — the NO-GATE set.
groups = [
    ("SessionStart", None, [("load-decision-profile.sh", 6), ("import-local-memories.sh", 10)]),
    ("UserPromptSubmit", None, [("recall-decisions.sh", 20), ("supply-ground.sh", 20)]),
    ("PostToolUse", "AskUserQuestion", [("capture-decision.sh", 6)]),
    ("PostToolUse", "mcp__mollow__get_session_context", [("grounding-receipt.sh", 5)]),
    ("Stop", None, [("sync-session.sh", 5), ("supply-stop.sh", 5),
                    ("record-sweep-decisions.sh", 6), ("grounding-engagement.sh", 5)]),
    # The messages-to-humans register gate. In the DEFAULT set rather than behind
    # --with-gates: that flag fences the BLOCKING guardrails gate, and this one
    # denies only two mechanical defects (a mention that notifies nobody, an
    # unresolvable reference in a channel a non-engineer reads), each challenged
    # once with an identical resend always going through. Everything about HOW a
    # message is written is a non-blocking warning. It is also inert without a
    # channel register, which the public plugin does not ship.
    ("PreToolUse", "mcp__slack-local__conversations_add_message",
     [("slack-register-gate.sh", 5)]),
]
if with_gates:
    groups += [("SessionStart", None, [("arm-guardrails.sh", 6)])]
    # The gate's matchers are read from hooks.json, the plugin's own registration,
    # rather than restated here: a second copy lagged once already, and an install
    # that lags gates nothing on the tools it is missing, silently (MOL-9756).
    try:
        with open(os.path.join(hooks_dir, "hooks.json")) as f:
            plugin_pre = json.load(f)["hooks"]["PreToolUse"]
        gate_matchers = [g["matcher"] for g in plugin_pre
                         if any("guardrails-gate.sh" in h.get("command", "") for h in g.get("hooks", []))]
    except (OSError, ValueError, KeyError, TypeError):
        gate_matchers = []
    if not gate_matchers:
        print(f"cannot read the guardrails matchers from {hooks_dir}/hooks.json — aborting, nothing changed",
              file=sys.stderr)
        sys.exit(1)
    groups += [("PreToolUse", m, [("guardrails-gate.sh", 5)]) for m in gate_matchers]

try:
    with open(settings_path) as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
if not isinstance(data, dict):
    print("settings.json is not a JSON object — aborting, nothing changed", file=sys.stderr)
    sys.exit(1)

hooks = data.setdefault("hooks", {})

def present(event, matcher, script):
    # Keyed on the matcher too: one script can be registered under two matchers
    # (guardrails-gate.sh is), and a check on the name alone would read the first
    # registration as the second and skip it. A missing matcher and "" both mean
    # "every tool", so they compare equal.
    for grp in hooks.get(event, []):
        if (grp.get("matcher") or None) != matcher:
            continue
        for h in grp.get("hooks", []):
            if script in h.get("command", ""):
                return True
    return False

added = []
for event, matcher, scripts in groups:
    # Idempotent PER SCRIPT: add only the scripts not already wired on this event,
    # so a partial prior install is completed rather than skipped wholesale.
    missing = [(s, t) for s, t in scripts if not present(event, matcher, s)]
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

print("✓ installed mollow-claude hooks" + (" (with gates)" if with_gates else " (no gates)") + ":")
for a in added:
    print("   + " + a)
print("→ restart Claude Code to activate. Decision recall, decision-capture and session")
print("  sync are live on restart. (supply-ground is installed too, but only grounds when")
print("  supply mode is enabled via ~/.mollow/supply-mode — it no-ops otherwise.)")
PY
