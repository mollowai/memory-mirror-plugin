#!/usr/bin/env bash
set -uo pipefail
# Predicate-level tests for guardrail-predicates-mollow.sh (MOL-5183).
#
# test-guardrails-gate.sh drives the GATE end-to-end and passed 54/54 while every
# predicate in this file misfired, because its fixtures are single self-contained
# commands. The defects need fragments spread across DIFFERENT commands in one
# string, so they can only be expressed here — against the predicate function
# itself, which is where the defect is.
#
# Run: bash plugins/memory-mirror/hooks/test-guardrail-predicates.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/guardrail-predicates-mollow.sh"

PASS=0
FAIL=0
RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; shift; for l in "$@"; do echo "  $l"; done; FAIL=$((FAIL + 1)); }

# Any path that is NOT under /workspaces/ — only predicate 4 reads cwd, and it
# fires on the yolo prefix. Deliberately not a real path: these predicates never
# touch the filesystem, and a hardcoded personal path would not survive CI or
# the public plugin sync.
REPO="/repo"
MIG="priv/repo/migrations/20260914000000_x.exs"

# shorts <tool> <cmd> <file> <content> <cwd> -> the matched predicate short names
shorts() { mollow_guardrail_predicates "$1" "$2" "$3" "$4" "$5" 2>/dev/null | cut -f2 | paste -sd'|' -; }

# expect_warn <label> <needle> <tool> <cmd> [cwd]
expect_warn() {
  local label="$1" needle="$2" got
  got="$(shorts "$3" "$4" "" "" "${5:-$REPO}")"
  case "$got" in *"$needle"*) pass "$label" ;; *) fail "$label" "want match: $needle" "got: ${got:-<silent>}" ;; esac
}
# expect_clean_of <label> <needle> <tool> <cmd> [cwd]  — needle must NOT appear
expect_clean_of() {
  local label="$1" needle="$2" got
  got="$(shorts "$3" "$4" "" "" "${5:-$REPO}")"
  case "$got" in *"$needle"*) fail "$label" "did NOT want: $needle" "got: $got" ;; *) pass "$label" ;; esac
}
# migration content variants
expect_mig_warn() {
  local label="$1" needle="$2" got
  got="$(shorts Write "" "$MIG" "$3" "$REPO")"
  case "$got" in *"$needle"*) pass "$label" ;; *) fail "$label" "want match: $needle" "got: ${got:-<silent>}" ;; esac
}
expect_mig_clean_of() {
  local label="$1" needle="$2" got
  got="$(shorts Write "" "$MIG" "$3" "$REPO")"
  case "$got" in *"$needle"*) fail "$label" "did NOT want: $needle" "got: $got" ;; *) pass "$label" ;; esac
}

echo "── true positives must survive the fix ──────────────────────────────────"
expect_warn "P1 real force-push"            "force-push"   Bash 'git push --force origin main'
expect_warn "P1 real force-push -f"         "force-push"   Bash 'git push -f origin main'
expect_warn "P2 real git --no-verify"       "no-verify"    Bash 'git commit --no-verify -m x'
expect_warn "P3 real docker --no-cache"     "no-cache"     Bash 'docker build --no-cache .'
expect_warn "P4 real native mix in yolo"    "native mix"   Bash 'mix format' /workspaces/x
expect_warn "P5 real worktree remove"       "worktree"     Bash 'git worktree remove ../wt'
expect_warn "P6 real bare mix test"         "TEST_FORMATTER" Bash 'mix test foo.exs'
expect_warn "P7 real commit --amend"        "amend"        Bash 'git commit --amend -m x'
expect_mig_warn "P8 real :string column"    "string"       'def change do
  add :name, :string
end'
expect_mig_warn "P9 real def up"            "up/down"      'def up() do
  :ok
end'
expect_mig_warn "P10 real ISO8601 in data"  "ISO8601"      'def change do
  execute "insert into t values (1, timestamp 2026-09-14T05:00:00Z)"
end'

echo
echo "── false positives: fragments from UNRELATED commands must not combine ──"
expect_clean_of "P1 pgrep -f + git + word 'unpushed'"   "force-push" Bash 'pgrep -f claude; git status; echo unpushed'
# shellcheck disable=SC2016  # the $( ) below is fixture TEXT and must not expand
expect_clean_of "P1 the real reported command"          "force-push" Bash 'pgrep -f "bin/claude"; cd /w && echo "branch: $(git branch --show-current)" && echo "unpushed: $(git log HEAD --not --remotes | wc -l)"'
expect_clean_of "P1 'push' only as a filename"          "force-push" Bash 'git log --oneline; cat -f push.md'
expect_clean_of "P2 npm --no-verify after a git cmd"    "no-verify"  Bash 'git status; npm ci --no-verify'
expect_clean_of "P3 pip --no-cache-dir after docker"    "no-cache"   Bash 'docker ps; pip install --no-cache-dir requests'
expect_clean_of "P5 'worktree remove' only as prose"    "worktree"   Bash 'git status; echo "never run worktree remove by hand"'
expect_clean_of "P7 clean commit + prose about amend"   "amend"      Bash 'git commit -m "real"; echo "do not use --amend"'

echo
echo "── false positives: a rule must not fire on text it merely MENTIONS ─────"
expect_clean_of "P4 echo mentioning mix"    "native mix"     Bash 'echo "use mix format here"' /workspaces/x
expect_clean_of "P6 echo mentioning mix test" "TEST_FORMATTER" Bash 'echo "always run mix test via the log"'
expect_mig_clean_of "P8 comment warning against :string" "string" '# never use :string here
def change do
  add :n, :text
end'
expect_mig_clean_of "P9 comment mentioning def up"       "up/down" '# migrated from def up / def down style
def change do
  add :n, :text
end'

echo
echo "── false positives: word boundaries ─────────────────────────────────────"
expect_mig_clean_of "P8 :string_id is not :string"  "string" 'def change do
  add :string_id, :text
end'
expect_mig_clean_of "P8 :stringify is not :string"  "string" 'def change do
  add :stringify, :text
end'

echo
echo "── FALSE NEGATIVES: naming the safe form must not disarm the rule ──────"
expect_warn "P1 force-push NOT silenced by later prose" "force-push" Bash 'git push --force origin main; echo "see docs on force-with-lease"'
expect_warn "P4 native mix NOT silenced by an earlier docker compose exec" "native mix" Bash 'docker compose exec webapp mix test; mix format' /workspaces/x
expect_warn "P6 unquiet mix test NOT silenced by an earlier quiet one" "TEST_FORMATTER" Bash 'TEST_FORMATTER=quiet mix test a.exs; mix test b.exs'
expect_mig_warn "P9 defp up is still up/down" "up/down" 'defp up() do
  :ok
end'

echo
echo "── the sanctioned forms must stay clean ─────────────────────────────────"
expect_clean_of "P1 --force-with-lease is fine"       "force-push" Bash 'git push --force-with-lease origin main'
expect_clean_of "P4 docker compose exec mix is fine"  "native mix" Bash 'docker compose exec webapp mix test' /workspaces/x
expect_clean_of "P6 quiet mix test is fine"           "TEST_FORMATTER" Bash 'TEST_FORMATTER=quiet mix test foo.exs'
expect_clean_of "P5 scripts/worktree-remove.sh is fine" "worktree"  Bash 'bash scripts/worktree-remove.sh mol-1'
expect_clean_of "benign command warns nothing"        "force-push" Bash 'ls -la'
expect_mig_clean_of "P8/9/10 clean migration"         "string" 'def change do
  add :n, :text
end'

echo
echo "── wrappers must not hide the real command (Greptile P1, PR #5636) ─────"
# `sudo -u deploy git push --force` resolved to head `deploy`: the blanket -*
# skip consumed the flag but not its VALUE, so the segment never reached the
# git predicates and a real force-push went unwarned.
expect_warn "P1 through sudo"                   "force-push" Bash 'sudo git push --force origin main'
expect_warn "P1 through sudo -u <user>"         "force-push" Bash 'sudo -u deploy git push --force origin main'
expect_warn "P1 through env -i"                 "force-push" Bash 'env -i git push --force origin main'
expect_warn "P1 through timeout <secs>"         "force-push" Bash 'timeout 30 git push --force origin main'
expect_warn "P1 through nohup"                  "force-push" Bash 'nohup git push --force origin main'
# A non-wrapper head must still NOT be scanned through, or the prose FPs return.
expect_clean_of "echo naming git push is still clean" "force-push" Bash 'echo "git push --force is banned"'
# ...and a wrapper must resolve to the command it WRAPS, not to any predicate
# program further along the line. `sudo echo git push --force` runs echo.
expect_clean_of "sudo echo naming git push is clean"  "force-push" Bash 'sudo echo git push --force'
expect_clean_of "sudo grep for the phrase is clean"   "force-push" Bash 'sudo grep -r "git push --force" .'
expect_clean_of "sudo -u <user> echo is clean"        "force-push" Bash 'sudo -u deploy echo git push --force'
# Every value-taking sudo option, per sudo(8): -C -D -g -h -p -R -T -t -r -U -u.
# Any one missed leaves its VALUE looking like the command, so the wrapped
# program is never inspected.
expect_warn "P1 through sudo -T <timeout>"      "force-push" Bash 'sudo -T 30 git push --force origin main'
expect_warn "P1 through sudo -R <chroot>"       "force-push" Bash 'sudo -R /srv/jail git push --force origin main'
expect_warn "P1 through sudo -D <dir>"          "force-push" Bash 'sudo -D /tmp git push --force origin main'
expect_warn "P1 through sudo -h <host>"         "force-push" Bash 'sudo -h buildbox git push --force origin main'
expect_warn "P1 through sudo -C <num>"          "force-push" Bash 'sudo -C 3 git push --force origin main'
expect_warn "P1 through sudo -g <group>"        "force-push" Bash 'sudo -g staff git push --force origin main'
expect_warn "P1 through sudo -p <prompt>"       "force-push" Bash 'sudo -p pw git push --force origin main'
expect_warn "P1 through sudo -U <user>"         "force-push" Bash 'sudo -U deploy git push --force origin main'
# Valueless sudo flags must NOT swallow the command that follows them.
expect_warn "P1 through sudo -b (valueless)"    "force-push" Bash 'sudo -b git push --force origin main'
expect_warn "P1 through sudo -En (valueless)"   "force-push" Bash 'sudo -E -n git push --force origin main'

echo
echo "── comment stripping must not eat Elixir interpolation (Greptile P1) ───"
# `#{table}` is not a comment. Stripping from the first `#` truncated the line
# and hid the violation after it; 4 migrations in this repo interpolate.
expect_mig_warn "P10 ISO8601 after an interpolation on the same line" "ISO8601" 'def change do
  execute("INSERT INTO #{table} VALUES (1, '"'"'2026-09-14T05:00:00Z'"'"')")
end'
expect_mig_warn "P8 :string after an interpolation on the same line" "string" 'def change do
  execute("ALTER TABLE #{t} ...")
  add :name, :string
end'
# ...while a real comment must still be stripped.
expect_mig_clean_of "P8 trailing comment still stripped" "string" 'def change do
  add :n, :text # was :string before
end'

echo
echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
