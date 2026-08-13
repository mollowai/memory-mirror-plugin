#!/usr/bin/env bash
# scope-sync.sh — resolve the directories your decisions were recorded in to
# stable repository identities, and backfill them (MOL-3980).
#
# Deliberate, never automatic. This rewrites stored memory, so it runs when you
# mean it rather than as a side effect of opening a session, and it previews
# what it would change before writing anything.
#
# ## Why the client has to do this
#
# The server can recover WHICH DIRECTORY a decision was recorded in — it joins
# `metadata["source_session"]` to the transcript session that carries
# `project_dir`. It cannot say which repository that directory belongs to:
# that needs `git` in the directory, and the webapp ships to other people, so
# nobody's directory layout can be baked into it.
#
# ## Deleted worktrees are the majority case
#
# Most worktrees are removed once their PR merges, so their directory can no
# longer be probed — and those are exactly the sessions whose label was wrong,
# because a worktree recorded under its own name instead of its repository's.
# Exact per-directory mapping alone would therefore miss most of what this
# exists to fix. So a fully ENUMERATED parent (`~/dev/mollow`, `~/workspaces`,
# `/workspaces`) also contributes a PREFIX rule covering its deleted children.
#
# Two conditions, and both matter:
#
#   * the parent was enumerated — every child listed. Unanimity is a claim about
#     all of them, and a directory named with `--dir` is a sample of one, where
#     "all children agree" is trivially true and would emit a rule covering
#     siblings never examined;
#   * its live children agree on one repository. Two repositories under one
#     parent means the parent says nothing.
#
# Otherwise its dead directories stay unresolved rather than guessed at. A
# mapped row is skipped by later runs, so a wrong rule is permanent — a
# corrected run cannot take it back.
#
# Usage:
#   scope-sync.sh                 preview only (default)
#   scope-sync.sh --apply         write, after printing the same preview
#   scope-sync.sh --dir <path>    add a directory to probe (repeatable)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$DIR/_common.sh"

APPLY=false
EXTRA_DIRS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=true
      shift
      ;;
    --dir)
      [ $# -ge 2 ] || {
        echo "scope-sync: --dir requires a value" >&2
        exit 2
      }
      EXTRA_DIRS+=("$2")
      shift 2
      ;;
    *)
      echo "usage: scope-sync.sh [--apply] [--dir <path>]..." >&2
      exit 2
      ;;
  esac
done

mm_ready || {
  echo "scope-sync: memory not configured or unreachable" >&2
  exit 1
}

# Parents this run ENUMERATES in full. Only these may produce a prefix rule:
# unanimity is a claim about every child, and it can only be made about a
# directory whose children were all listed.
ENUMERATED_PARENTS=("$HOME/dev/mollow" "$HOME/workspaces" /workspaces)

# Fully-listed children of the enumerated parents.
enumerated_dirs() {
  local parent
  for parent in "${ENUMERATED_PARENTS[@]}"; do
    [ -d "$parent" ] || continue
    find "$parent" -maxdepth 1 -mindepth 1 -type d 2>/dev/null || true
  done
}

# Directories named individually. These are SAMPLES — nothing was listed around
# them — so they contribute exact mappings only, never a prefix rule.
sampled_dirs() {
  printf '%s\n' "${EXTRA_DIRS[@]:-}"
  printf '%s\n' "$PWD"
}

# {dir, repo, enumerated} for every candidate that is a git repository.
resolve_dirs() {
  local flag="$1"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    repo="$(mm_repo_of "$d")"
    [ -n "$repo" ] || continue
    jq -cn --arg dir "$d" --arg repo "$repo" --argjson enum "$flag" \
      '{dir: $dir, repo: $repo, enumerated: $enum}'
  done
}

resolved="$(
  {
    enumerated_dirs | sort -u | resolve_dirs true
    sampled_dirs | sort -u | resolve_dirs false
  } | jq -cs 'group_by(.dir) | map(max_by(.enumerated))'
)"

if [ "$(printf '%s' "$resolved" | jq 'length')" -eq 0 ]; then
  echo "scope-sync: no git repositories found to map" >&2
  exit 1
fi

# A parent contributes a prefix rule only when it was ENUMERATED and its live
# children agree.
#
# The enumeration requirement is what makes unanimity mean anything. A directory
# named with --dir (or the cwd) is a sample of one: nothing else under its parent
# was listed, so "all children agree" is trivially true and would emit a rule
# covering siblings never examined. Because a mapped row is skipped by later runs
# (`repo IS NULL`), that wrong rule would be permanent — a corrected run could
# not take it back.
#
# Where enumerated children disagree the parent is dropped. A wrong rule writes a
# plausible false identity into memory, which is worse than leaving those rows
# unresolved.
prefixes="$(
  printf '%s' "$resolved" | jq -c '
    map(select(.enumerated) | . + {parent: (.dir | sub("/[^/]+$"; "") + "/")})
    | group_by(.parent)
    | map(select((map(.repo) | unique | length) == 1)
          | {prefix: .[0].parent, repo: .[0].repo})
  '
)"

mappings="$(jq -cn --argjson d "$resolved" --argjson p "$prefixes" \
  '[$d[] | {dir, repo}] + $p')"

echo "Mappings computed from this machine:"
printf '%s' "$mappings" | jq -r '.[] | "  \(.dir // .prefix)  ->  \(.repo)"'
echo

# Preview first, always — including under --apply, so the counts are on screen
# before anything is written.
body="$(jq -cn --argjson m "$mappings" '{mappings: $m, dry_run: true}')"
preview="$(mm_post_read "/api/memory/decisions/scope-mappings" "$body" 60)"

if [ -z "$preview" ] || ! printf '%s' "$preview" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "scope-sync: preview failed (${#preview} bytes)" >&2
  exit 1
fi

echo "Decisions that would be updated:"
printf '%s' "$preview" | jq -r '.applied[] | select(.rows > 0) | "  \(.rows)\t\(.repo)"'
echo "  ---"
echo "  $(printf '%s' "$preview" | jq -r '.total') total"

if [ "$APPLY" != "true" ]; then
  echo
  echo "Preview only. Re-run with --apply to write."
  exit 0
fi

echo
body="$(jq -cn --argjson m "$mappings" '{mappings: $m, dry_run: false}')"
applied="$(mm_post_read "/api/memory/decisions/scope-mappings" "$body" 120)"

if [ -z "$applied" ] || ! printf '%s' "$applied" | jq -e '.ok == true' >/dev/null 2>&1; then
  echo "scope-sync: apply failed (${#applied} bytes)" >&2
  exit 1
fi

echo "Updated $(printf '%s' "$applied" | jq -r '.total') decisions."
