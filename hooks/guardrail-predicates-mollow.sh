#!/usr/bin/env bash
# Mollow-internal seeded guardrail predicates (MOL-2336 Phase-1 MVP).
#
# Deterministic, warn-only predicates over a pending tool call — the local seed
# set that gives the guardrail gate value before the Engram distillation pipeline
# (MOL-2335) produces per-workspace WayOfWorking rules. Each predicate encodes a
# convention from CLAUDE.md / docs/CODING_STANDARDS.md that recurs as `e_firm`
# feedback. All are :warn (advisory additionalContext); TDD is the one :block
# rule and lives in guardrails-gate.sh, not here.
#
# PUBLIC SPLIT: this file is Mollow-monorepo-specific (hardcoded repo conventions,
# yolo `/workspaces/` paths). The public memory-mirror plugin sync MUST strip it
# (MOL-2182) — guardrails-gate.sh sources it guarded by `[ -f ]`, so removing the
# file degrades the gate to server-rules + override only, never breaks it.
#
# Contract: `mollow_guardrail_predicates <tool> <cmd> <file> <content> <cwd>`
# echoes zero or more warning lines (one per matched predicate). No network, no
# side effects, never fails the caller.
#
# Regexes are held in variables and matched as `[[ $text =~ $re ]]`: an inline
# `[[ =~ (…(…) ]]` pattern with a literal `(` inside a bracket expression trips
# bash's conditional-command paren balancer, so keep them out of the literal.

# Emit a warning line: "<severity>\t<short>\t<fix>". The gate renders these; the
# tab layout keeps parsing trivial and the text greppable in tests.
_mgp_warn() { printf 'warn\t%s\t%s\n' "$1" "$2"; }

# True when a migration file is the target (Write/Edit content checks key off it).
_mgp_is_migration() { [[ "$1" =~ /migrations/[^/]*\.exs$ ]]; }

mollow_guardrail_predicates() {
  local tool="$1" cmd="$2" file="$3" content="$4" cwd="$5"
  local re

  # ── Bash command conventions ────────────────────────────────────────────────
  if [ "$tool" = "Bash" ] && [ -n "$cmd" ]; then
    # 1. Force-push without a lease clobbers teammates' commits.
    re='(--force([^-=]|$)|[[:space:]]-f([[:space:]]|$))'
    if [[ "$cmd" =~ git[[:space:]].*push ]] && [[ "$cmd" =~ $re ]] &&
      [[ ! "$cmd" =~ force-with-lease ]]; then
      _mgp_warn "force-push without --force-with-lease" \
        "CLAUDE.md: never force-push unless asked; prefer 'git push --force-with-lease'."
    fi

    # 2. git --no-verify skips the pre-commit / pre-push quality hooks. Scoped to
    # git: other tools (npm, gem, …) also take --no-verify and don't mean this.
    re='(^|[[:space:]])--no-verify([[:space:]]|$)'
    if [[ "$cmd" =~ git[[:space:]] ]] && [[ "$cmd" =~ $re ]]; then
      _mgp_warn "--no-verify bypasses git hooks" \
        "Run /pre-pr instead of skipping the commit/push gates."
    fi

    # 3. docker build --no-cache throws away every layer (slow, rarely intended).
    if [[ "$cmd" =~ docker[[:space:]] ]] && [[ "$cmd" =~ --no-cache ]]; then
      _mgp_warn "--no-cache discards the Docker build cache" \
        "Drop --no-cache unless you're deliberately busting a stale layer."
    fi

    # 4. Native mix/iex inside a yolo session must route through the container.
    re='(^|[[:space:]&|;(])(mix|iex)[[:space:]]'
    if [[ "$cwd" == /workspaces/* ]] && [[ "$cmd" =~ $re ]] &&
      [[ ! "$cmd" =~ docker[[:space:]]+compose[[:space:]]+(exec|run) ]]; then
      _mgp_warn "native mix/iex in a yolo session" \
        "CLAUDE.md: run Elixir/Mix via 'docker compose exec' in /workspaces/ sessions."
    fi

    # 5. Raw worktree removal skips managed cleanup (forge/host bookkeeping).
    if [[ "$cmd" =~ git[[:space:]].*worktree[[:space:]]+remove ]]; then
      _mgp_warn "raw 'git worktree remove'" \
        "Use /worktree:down or the forge/host cleanup skill so session state stays consistent."
    fi

    # 6. mix test without the quiet formatter floods output instead of the log.
    re='(^|[[:space:]&|;(])mix[[:space:]]+test([[:space:]]|$)'
    if [[ "$cmd" =~ $re ]] && [[ ! "$cmd" =~ TEST_FORMATTER=quiet ]]; then
      _mgp_warn "mix test without TEST_FORMATTER=quiet" \
        "CLAUDE.md: 'TEST_FORMATTER=quiet mix test <files>' then read webapp/tmp/test_full_output.log."
    fi

    # 7. commit --amend silently folds unrelated changes into a prior commit.
    if [[ "$cmd" =~ git[[:space:]].*commit ]] && [[ "$cmd" =~ --amend ]]; then
      _mgp_warn "git commit --amend" \
        "CLAUDE.md: separate commits per logical change; don't amend to squash unrelated work."
    fi
  fi

  # ── Migration content conventions (Write/Edit/MultiEdit) ────────────────────
  if _mgp_is_migration "$file" && [ -n "$content" ]; then
    # 8. New migrations must use :text, not :string (custom credo check).
    if [[ "$content" =~ :string ]]; then
      _mgp_warn "':string' column in a migration" \
        "New migrations must use :text (custom credo start_after gate)."
    fi

    # 9. New migrations must use change/0, not up/down.
    re='def[[:space:]]+(up|down)([[:space:]]|\()'
    if [[ "$content" =~ $re ]]; then
      _mgp_warn "up/down in a migration" \
        "New migrations must define change/0, not up/down (custom credo gate)."
    fi

    # 10. Hardcoded ISO8601 timestamps in a migration are non-deterministic data.
    re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'
    if [[ "$content" =~ $re ]]; then
      _mgp_warn "ISO8601 date literal in a migration" \
        "Don't hardcode timestamps in migrations; compute them or use DB defaults."
    fi
  fi
}
