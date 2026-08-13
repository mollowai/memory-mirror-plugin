#!/usr/bin/env bash
set -euo pipefail
# Tests for mm_repo_of / mm_path_of / mm_project_of — the stable scope identity
# behind decision recall (MOL-3980).
#
# The label these replace was `basename "$cwd"`, so ONE repository recorded as
# `monorepo` from the primary checkout, `ask-first-question-sweep` from a
# worktree and `mol-1234` from a yolo clone. Every equality filter over that
# fragmented exactly where the large work happens.
#
# What must hold, and what these fixtures exercise with real git repos:
#
#   * the same repository yields the SAME identity from its primary checkout, a
#     linked worktree, and a separate clone — the three session shapes;
#   * all three remote URL spellings (https, git@, ssh://) collapse to one value;
#   * a repo with no remote still gets a stable identity, via the MAIN repo's
#     directory (`--git-common-dir`), never the worktree's own name;
#   * outside a repository everything degrades to the old basename rather than
#     erroring, because these run inside hooks that must never break a session.
#
# Run: bash plugins/memory-mirror/hooks/test-repo-identity.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# No key ⇒ mm_ready() short-circuits; nothing here should reach the network.
unset MOLLOW_MEMORY_API_KEY
# shellcheck source=/dev/null
. "$DIR/_common.sh"

PASS=0
FAIL=0
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASS=$((PASS + 1)); }
fail() {
  echo -e "${RED}FAIL${NC}: $1"
  shift
  for line in "$@"; do echo "  $line"; done
  FAIL=$((FAIL + 1))
}

eq() {
  local label="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$label"
  else
    fail "$label" "expected: [$expected]" "actual:   [$actual]"
  fi
}

tmpdir() { mktemp -d "${TMPDIR:-/tmp}/mm-repo-XXXXXX"; }

# A real repo with one commit, so worktrees can be added from it.
make_repo() {
  local dir="$1" remote="${2:-}"
  mkdir -p "$dir"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  git -C "$dir" commit -q --allow-empty -m init
  [ -n "$remote" ] && git -C "$dir" remote add origin "$remote"
  return 0
}

# ── all three remote spellings collapse to one identity ──────────────────────
for spelling in \
  "https://github.com/mollowai/monorepo.git" \
  "git@github.com:mollowai/monorepo.git" \
  "ssh://git@github.com/mollowai/monorepo" \
  "ssh://git@github.com:22/mollowai/monorepo.git"; do
  t="$(tmpdir)"
  make_repo "$t/repo" "$spelling"
  eq "remote spelling collapses: $spelling" "github.com/mollowai/monorepo" "$(mm_repo_of "$t/repo")"
  rm -rf "$t"
done

# ── the three session shapes agree ───────────────────────────────────────────
# This is the whole point. A worktree is the case that fails today.
t="$(tmpdir)"
make_repo "$t/monorepo" "https://github.com/mollowai/monorepo.git"
git -C "$t/monorepo" worktree add -q -b wt "$t/workspaces-mol-1234" 2>/dev/null
git clone -q "$t/monorepo" "$t/yolo-clone" 2>/dev/null

primary="$(mm_repo_of "$t/monorepo")"
worktree="$(mm_repo_of "$t/workspaces-mol-1234")"
eq "worktree matches its primary checkout" "$primary" "$worktree"
eq "primary is the normalized remote" "github.com/mollowai/monorepo" "$primary"

# The clone's origin is the local path, so it normalizes to that path's identity
# rather than github.com/... — what matters is that it is STABLE and derived
# from the remote, not from the clone's own directory name.
clone="$(mm_repo_of "$t/yolo-clone")"
if [ -n "$clone" ] && [ "$clone" != "yolo-clone" ]; then
  pass "clone identity comes from its remote, not its directory name"
else
  fail "clone identity comes from its remote, not its directory name" "got: [$clone]"
fi
rm -rf "$t"

# ── a local-path origin is followed one hop, or degrades to its basename ─────
# Yolo agent clones set origin to a container path like `/workspaces/monorepo`.
# Treating that as a URL produced `workspaces/monorepo` — a fake identity that
# split those clones off from the repo they are copies of.
t="$(tmpdir)"
make_repo "$t/upstream" "https://github.com/mollowai/monorepo.git"
git clone -q "$t/upstream" "$t/local-clone" 2>/dev/null
eq "local-path origin follows one hop to the real upstream" \
  "github.com/mollowai/monorepo" "$(mm_repo_of "$t/local-clone")"
rm -rf "$t"

t="$(tmpdir)"
make_repo "$t/orphan"
git -C "$t/orphan" remote add origin /nonexistent/path/monorepo
eq "an unreachable local-path origin degrades to its basename" \
  "monorepo" "$(mm_repo_of "$t/orphan")"
rm -rf "$t"

# CR-A-r1-002: the hop target may ITSELF be a local path (a chain of local
# clones). Falling through to URL normalization there strips the leading slash
# and yields `workspaces/repo` — the same fake-identity shape this function
# exists to remove.
t="$(tmpdir)"
make_repo "$t/root"
git clone -q "$t/root" "$t/middle" 2>/dev/null
git clone -q "$t/middle" "$t/leaf" 2>/dev/null
eq "a two-hop local chain degrades to a basename, never a path-as-URL" \
  "root" "$(mm_repo_of "$t/leaf")"
rm -rf "$t"

# ── no remote: fall back to the MAIN repo's directory, not the worktree's ────
t="$(tmpdir)"
make_repo "$t/primary-name"
git -C "$t/primary-name" worktree add -q -b wt "$t/some-worktree-name" 2>/dev/null
eq "no remote, primary checkout" "primary-name" "$(mm_repo_of "$t/primary-name")"
eq "no remote, worktree still names the MAIN repo" "primary-name" "$(mm_repo_of "$t/some-worktree-name")"
rm -rf "$t"

# ── outside a repo: empty, so callers fall back rather than inventing one ────
t="$(tmpdir)"
eq "non-repo directory has no repo identity" "" "$(mm_repo_of "$t")"
eq "empty argument is not an error" "" "$(mm_repo_of "")"
eq "nonexistent path is not an error" "" "$(mm_repo_of "$t/does-not-exist")"
rm -rf "$t"

# ── mm_path_of: repo-relative subdirectory ───────────────────────────────────
t="$(tmpdir)"
make_repo "$t/repo" "https://github.com/mollowai/monorepo.git"
mkdir -p "$t/repo/webapp/lib"
eq "repo root is the empty prefix" "" "$(mm_path_of "$t/repo")"
eq "subdirectory is repo-relative" "webapp" "$(mm_path_of "$t/repo/webapp")"
eq "nested subdirectory" "webapp/lib" "$(mm_path_of "$t/repo/webapp/lib")"
eq "outside a repo has no path" "" "$(mm_path_of "$t")"
rm -rf "$t"

# ── mm_project_of: now the repo identity, basename only as a fallback ────────
t="$(tmpdir)"
make_repo "$t/monorepo" "https://github.com/mollowai/monorepo.git"
git -C "$t/monorepo" worktree add -q -b wt "$t/ask-first-question-sweep" 2>/dev/null
eq "project is the repo identity" "github.com/mollowai/monorepo" "$(mm_project_of "$t/monorepo")"
eq "project is STABLE across a worktree (the bug)" \
  "github.com/mollowai/monorepo" "$(mm_project_of "$t/ask-first-question-sweep")"
rm -rf "$t"

t="$(tmpdir)"
mkdir -p "$t/not-a-repo"
eq "outside a repo, project degrades to the basename" "not-a-repo" "$(mm_project_of "$t/not-a-repo")"
eq "empty cwd yields nothing" "" "$(mm_project_of "")"
rm -rf "$t"

echo
echo "════════════════════════════════════════"
echo "Results: ${PASS} passed, ${FAIL} failed"
echo "════════════════════════════════════════"
[ "$FAIL" -eq 0 ]
