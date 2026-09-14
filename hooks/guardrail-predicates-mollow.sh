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
#
# ── Why these match per-invocation, not per-string (MOL-5183) ────────────────
#
# Every Bash predicate used to test the WHOLE `$cmd` string. Fragments from
# unrelated commands then combined: `pgrep -f claude; git status; echo unpushed`
# reported a force-push, because `-f` came from pgrep, `git ` from git status,
# and `push` from inside the word "unpushed". All ten predicates misfired that
# way, and the end-to-end suite stayed green because its fixtures are single
# self-contained commands that cannot express it.
#
# Worse, three predicates negated over the whole string too
# (`! =~ force-with-lease`, `! =~ TEST_FORMATTER=quiet`, `! =~ docker compose
# exec`). Naming the safe form ANYWHERE disarmed the rule for an unsafe
# invocation elsewhere in the same command — so `git push --force origin main;
# echo "see force-with-lease"` warned about nothing.
#
# So: split the command into segments, resolve each segment's command head, and
# apply each predicate only to segments actually invoking that program. A rule
# about `git push` now requires a segment whose head IS git, which also drops
# the `echo "…"`-mentions-it class and confines every suppression to its own
# invocation (fixing the false negatives as a side effect, not a special case).
#
# LIMITS, on purpose: _mgp_split is a separator scan, not a shell parser. A `;`
# or `&&` inside a quoted string splits anyway, and `bash -c "git push --force"`
# is judged by its head (`bash`), so the inner command is not inspected. Both
# are acceptable for warn-only advisory rules; a real parser is not worth it
# here. What matters is that a rule no longer fires on a program nobody ran.

# Emit a warning line: "<severity>\t<short>\t<fix>". The gate renders these; the
# tab layout keeps parsing trivial and the text greppable in tests.
_mgp_warn() { printf 'warn\t%s\t%s\n' "$1" "$2"; }

# True when a migration file is the target (Write/Edit content checks key off it).
_mgp_is_migration() { [[ "$1" =~ /migrations/[^/]*\.exs$ ]]; }

# Split a command line into roughly-independent invocations on the shell control
# operators. Separator scan, not a parser — see LIMITS above. Emits one segment
# per line; empty segments are dropped by the callers' `[ -n ]` guard.
_mgp_split() {
  local s="$1" nl=$'\n'
  # Pure bash: BSD sed emits a literal 'n' for a '\n' replacement, and putting
  # '\n' inside a bracket expression would split on the letter n as well.
  # Two-character operators first, so the singles cannot bisect them.
  s="${s//&&/$nl}"
  s="${s//||/$nl}"
  s="${s//;/$nl}"
  s="${s//|/$nl}"
  s="${s//&/$nl}"
  printf '%s' "$s"
}

# The program a segment actually invokes, or "" when there is none.
# Skips leading `VAR=value` assignments and common wrappers so
# `TEST_FORMATTER=quiet mix test` resolves to `mix` and `timeout 25 ssh x` to
# `ssh`. Returns the basename, so `/usr/bin/git` and `git` agree.
_mgp_head() {
  local seg="$1"
  # shellcheck disable=SC2086
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;                                  # env assignment prefix
      nohup | time | command | exec | builtin) shift ;;

      # Wrappers whose own options can take a SEPARATE value. Consuming the flag
      # but not its value left that value where the program should be, so
      # `sudo -u deploy git push --force` resolved to head `deploy` and went
      # unwarned (Greptile P1 on PR #5636). An earlier attempt scanned the rest
      # of the segment for any predicate program instead; that made
      # `sudo echo git push --force` warn about a force-push nobody ran
      # (Greptile P2, same PR). So consume each wrapper's options exactly, and
      # stop at the first real word — which is the command it wraps.
      sudo)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            # Value-taking options per sudo(8): -C -D -g -h -p -R -T -U -u and
            # the SELinux pair -r -t. Missing one leaves its VALUE looking like
            # the command, so the wrapped program is never inspected.
            -u | -g | -p | -C | -h | -U | -r | -t | -D | -T | -R) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) break ;;
          esac
        done
        ;;
      env)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -u | -C | -S) shift; [ $# -gt 0 ] && shift ;;
            -* | *=*) shift ;;
            *) break ;;
          esac
        done
        ;;
      timeout)
        shift
        while [ $# -gt 0 ]; do
          case "$1" in
            -s | -k | --signal | --kill-after) shift; [ $# -gt 0 ] && shift ;;
            -*) shift ;;
            *) shift; break ;;                       # the duration itself
          esac
        done
        ;;

      -*) shift ;;                                   # stray leading flag
      *) break ;;                                    # the command
    esac
  done
  [ $# -gt 0 ] || { printf ''; return 0; }
  printf '%s' "${1##*/}"
}

# Strip Elixir line comments before matching migration content, so a comment
# describing a convention does not trip the rule enforcing it.
#
# `#{` is interpolation, not a comment. Stripping from the first `#` truncated
# `execute("INSERT INTO #{table} VALUES ('2026-09-14T05:00')")` at the brace and
# hid the timestamp after it (Greptile P1 on PR #5636); four migrations in this
# repo interpolate that way. So a comment starts at a `#` that is at line start
# or preceded by whitespace AND is not followed by `{`.
#
# Still naive: a literal " # " inside a string is treated as a comment. That is
# far rarer than interpolation, and the cost is a missed warning on one line of
# one migration rather than a false one on every commented file.
_mgp_strip_ex_comments() {
  printf '%s' "$1" | sed -E 's/(^|[[:space:]])#([^{].*)?$/\1/'
}

mollow_guardrail_predicates() {
  local tool="$1" cmd="$2" file="$3" content="$4" cwd="$5"
  local re

  # ── Bash command conventions ────────────────────────────────────────────────
  # Each rule runs per segment, gated on the program that segment invokes, so a
  # flag belonging to another command can never satisfy it (MOL-5183).
  if [ "$tool" = "Bash" ] && [ -n "$cmd" ]; then
    local seg head saw_force_push=0 saw_no_verify=0 saw_no_cache=0
    local saw_native_mix=0 saw_worktree_rm=0 saw_unquiet_test=0 saw_amend=0

    while IFS= read -r seg; do
      [ -n "$seg" ] || continue
      head="$(_mgp_head "$seg")"
      [ -n "$head" ] || continue

      case "$head" in
        git)
          # 1. Force-push without a lease clobbers teammates' commits. The lease
          # check is scoped to THIS segment: mentioning it elsewhere must not
          # disarm a real force push here.
          re='(^|[[:space:]])push([[:space:]]|$)'
          if [[ "$seg" =~ $re ]]; then
            re='(--force([^-=]|$)|[[:space:]]-f([[:space:]]|$))'
            if [[ "$seg" =~ $re ]] && [[ ! "$seg" =~ --force-with-lease ]]; then
              saw_force_push=1
            fi
          fi

          # 2. git --no-verify skips the pre-commit / pre-push quality hooks.
          re='(^|[[:space:]])--no-verify([[:space:]]|$)'
          [[ "$seg" =~ $re ]] && saw_no_verify=1

          # 5. Raw worktree removal skips managed cleanup (forge/host bookkeeping).
          re='(^|[[:space:]])worktree[[:space:]]+remove([[:space:]]|$)'
          [[ "$seg" =~ $re ]] && saw_worktree_rm=1

          # 7. commit --amend silently folds unrelated changes into a prior commit.
          re='(^|[[:space:]])commit([[:space:]]|$)'
          if [[ "$seg" =~ $re ]]; then
            re='(^|[[:space:]])--amend([[:space:]]|$)'
            [[ "$seg" =~ $re ]] && saw_amend=1
          fi
          ;;

        docker)
          # 3. docker build --no-cache throws away every layer. Word-bounded so
          # pip's --no-cache-dir in another command cannot satisfy it.
          re='(^|[[:space:]])--no-cache([[:space:]]|$)'
          [[ "$seg" =~ $re ]] && saw_no_cache=1
          ;;

        mix | iex)
          # 4. Native mix/iex inside a yolo session must route through the
          # container. A `docker compose exec … mix test` segment has head
          # `docker`, so it never reaches here — the old whole-string exemption
          # is unnecessary now, and cannot silence a later native call.
          [[ "$cwd" == /workspaces/* ]] && saw_native_mix=1

          # 6. mix test without the quiet formatter floods output. The env prefix
          # is read from THIS segment, so one quiet run cannot excuse the next.
          if [ "$head" = mix ]; then
            re='(^|[[:space:]])test([[:space:]]|$)'
            if [[ "$seg" =~ $re ]] && [[ ! "$seg" =~ TEST_FORMATTER=quiet ]]; then
              saw_unquiet_test=1
            fi
          fi
          ;;
      esac
    done <<EOF
$(_mgp_split "$cmd")
EOF

    [ "$saw_force_push" = 1 ] && _mgp_warn "force-push without --force-with-lease" \
      "CLAUDE.md: never force-push unless asked; prefer 'git push --force-with-lease'."
    [ "$saw_no_verify" = 1 ] && _mgp_warn "--no-verify bypasses git hooks" \
      "Run /pre-pr instead of skipping the commit/push gates."
    [ "$saw_no_cache" = 1 ] && _mgp_warn "--no-cache discards the Docker build cache" \
      "Drop --no-cache unless you're deliberately busting a stale layer."
    [ "$saw_native_mix" = 1 ] && _mgp_warn "native mix/iex in a yolo session" \
      "CLAUDE.md: run Elixir/Mix via 'docker compose exec' in /workspaces/ sessions."
    [ "$saw_worktree_rm" = 1 ] && _mgp_warn "raw 'git worktree remove'" \
      "Use /worktree:down or the forge/host cleanup skill so session state stays consistent."
    [ "$saw_unquiet_test" = 1 ] && _mgp_warn "mix test without TEST_FORMATTER=quiet" \
      "CLAUDE.md: 'TEST_FORMATTER=quiet mix test <files>' then read webapp/tmp/test_full_output.log."
    [ "$saw_amend" = 1 ] && _mgp_warn "git commit --amend" \
      "CLAUDE.md: separate commits per logical change; don't amend to squash unrelated work."
  fi

  # ── Migration content conventions (Write/Edit/MultiEdit) ────────────────────
  # Matched against comment-stripped content: a comment describing a convention
  # must not trip the rule enforcing it (MOL-5183).
  if _mgp_is_migration "$file" && [ -n "$content" ]; then
    local code
    code="$(_mgp_strip_ex_comments "$content")"

    # 8. New migrations must use :text, not :string (custom credo check).
    # Word-bounded: :string_id and :stringify are different atoms.
    re=':string([^A-Za-z0-9_]|$)'
    if [[ "$code" =~ $re ]]; then
      _mgp_warn "':string' column in a migration" \
        "New migrations must use :text (custom credo start_after gate)."
    fi

    # 9. New migrations must use change/0, not up/down. `defp?` so a private
    # up/down is caught too — `def[[:space:]]` could never match `defp`.
    re='defp?[[:space:]]+(up|down)([[:space:]]|\()'
    if [[ "$code" =~ $re ]]; then
      _mgp_warn "up/down in a migration" \
        "New migrations must define change/0, not up/down (custom credo gate)."
    fi

    # 10. Hardcoded ISO8601 timestamps in a migration are non-deterministic data.
    re='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}'
    if [[ "$code" =~ $re ]]; then
      _mgp_warn "ISO8601 date literal in a migration" \
        "Don't hardcode timestamps in migrations; compute them or use DB defaults."
    fi
  fi
}
