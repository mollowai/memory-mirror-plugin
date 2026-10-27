#!/usr/bin/env bash
set -euo pipefail
# Package memory-mirror as a customer-installable Claude Code plugin bundle (MOL-7864).
#
# Produces a self-contained marketplace directory a NON-MOLLOW machine can install
# with the standard `claude plugin marketplace add` / `claude plugin install` flow
# (see INSTALL.md). The bundle carries the deterministic hooks + skills and the
# PORTABLE authored-doctrine predicate slot; it needs NO Mollow API key for the
# local-predicate path.
#
# What this does, in order:
#   1. Stage a copy of plugins/memory-mirror/.
#   2. MOL-2182 strip: remove the monorepo-specific predicate shell + its test
#      (guardrails-gate.sh sources them under `[ -f ]`, so removal only degrades
#      the gate to portable-doctrine + server-rules, never breaks it).
#   3. Activate the portable doctrine: copy guardrail-predicates.sample.json to
#      guardrail-predicates.json UNLESS a real one is already staged (so MOL-7974's
#      authored file, if dropped in beforehand, wins).
#   4. Release gate: run the MOL-2182 sanitizer on the active data file and assert
#      the stripped monorepo file is gone. Abort the build on any violation.
#   5. Wrap it in a standalone .claude-plugin/marketplace.json.
#   6. Emit a .tgz (skipped with --dry-run).
#
# Usage:
#   scripts/package-plugin.sh [--out DIR] [--dry-run]
#     --out DIR    where to build (default: <repo>/dist/memory-mirror-plugin-pkg)
#     --dry-run    stage + sanitize + validate structure; do NOT write the tarball

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"   # plugins/memory-mirror
PLUGIN_NAME="memory-mirror"
MARKET_NAME="mollow"
VERSION="$(jq -r '.version // "0.0.0"' "$PLUGIN_DIR/.claude-plugin/plugin.json" 2>/dev/null || echo 0.0.0)"

OUT=""
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="$2"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$OUT" ] || OUT="$(cd "$PLUGIN_DIR/../.." && pwd)/dist/memory-mirror-plugin-pkg"

command -v jq >/dev/null 2>&1 || { echo "package: jq required" >&2; exit 2; }

# A --dry-run validates the CURRENT inputs and must never touch a real output dir.
# Redirect it into a FRESH throwaway temp dir instead of $OUT. This closes the
# stale-state hazard: a prior run's already-generated guardrail-predicates.json
# could otherwise linger in $OUT and be re-checked by the sanitizer in place of an
# updated sample, so a maintainer who adds a forbidden path to the sample would
# still see a passing dry-run. A fresh dir always re-stages from current inputs and
# leaves $OUT (which real builds share, e.g. --out ./dist) completely untouched.
if [ "$DRY_RUN" = 1 ]; then
  OUT="$(mktemp -d "${TMPDIR:-/tmp}/memory-mirror-pkg.XXXXXX")"
  trap 'rm -rf "$OUT"' EXIT
fi

# Resolve $OUT to an absolute path up front. $OUT may be relative (e.g.
# --out ./dist); the tarball step cd's into it, and a relative archive path
# would then re-resolve against $OUT and double-nest as ./dist/dist/… .
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

BUNDLE="$OUT/${PLUGIN_NAME}-plugin"           # marketplace root
STAGE="$BUNDLE/$PLUGIN_NAME"                   # the plugin itself, under the marketplace
TARBALL="$OUT/${PLUGIN_NAME}-plugin-${VERSION}.tgz"
echo "package: building $PLUGIN_NAME v$VERSION → $BUNDLE"

# Clean only THIS plugin's staging subdir and its archive — never all of $OUT,
# which may hold unrelated artifacts (--out ./dist is a shared dist dir). A
# --dry-run runs against a fresh temp $OUT (set above), so there is nothing stale
# to clean and the rm is skipped.
if [ "$DRY_RUN" != 1 ]; then
  rm -rf "$BUNDLE"
  rm -f "$TARBALL"
fi
mkdir -p "$STAGE"

# 1. Stage. Copy the plugin tree, excluding VCS/build cruft and the packaging dist.
( cd "$PLUGIN_DIR" && \
  find . \
    -path './.git' -prune -o \
    -path './dist' -prune -o \
    -name '*.pyc' -prune -o \
    -name '__pycache__' -prune -o \
    -type f -print ) | while IFS= read -r rel; do
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp "$PLUGIN_DIR/$rel" "$STAGE/$rel"
done

# 2. MOL-2182 strip: remove EVERY Mollow-internal path from the staged bundle.
# Reuse the single source of truth — the public-sync sanitizer's INTERNAL_PATHS
# list — instead of hardcoding a subset here, so the customer bundle and the
# public-repo sync can never drift on what counts as internal. This strips the
# monorepo predicate shell AND the internal test fixtures (one carries an
# internal IP), including this plugin's own portable test file.
SANITIZER="$(cd "$PLUGIN_DIR/../.." && pwd)/scripts/sanitize-public-plugin.sh"
[ -f "$SANITIZER" ] || { echo "package: ABORT — sanitizer not found: $SANITIZER" >&2; exit 1; }
bash "$SANITIZER" "$STAGE"

# 3. Activate the portable doctrine (MOL-7974's file wins if already present).
if [ ! -f "$STAGE/hooks/guardrail-predicates.json" ]; then
  if [ -f "$STAGE/hooks/guardrail-predicates.sample.json" ]; then
    cp "$STAGE/hooks/guardrail-predicates.sample.json" "$STAGE/hooks/guardrail-predicates.json"
    echo "package: activated portable doctrine from sample (MOL-7974 drops the real one here)"
  else
    echo "package: WARNING no portable predicate file to activate — local doctrine will be inert" >&2
  fi
else
  echo "package: using pre-staged guardrail-predicates.json (assuming MOL-7974 content)"
fi

# 4. Release gate (MOL-2182). Sanitize the ACTIVE data file; assert the strip.
# shellcheck source=/dev/null
. "$STAGE/hooks/guardrail-predicates-portable.sh"
if [ -f "$STAGE/hooks/guardrail-predicates.json" ]; then
  if ! check_portable_predicates_sanitized "$STAGE/hooks/guardrail-predicates.json"; then
    echo "package: ABORT — active predicate file failed the MOL-2182 sanitizer" >&2
    exit 1
  fi
  echo "package: sanitizer OK (MOL-2182)"
fi
if [ -e "$STAGE/hooks/guardrail-predicates-mollow.sh" ]; then
  echo "package: ABORT — monorepo-specific predicate file leaked into the bundle" >&2
  exit 1
fi

# 5. Standalone marketplace wrapper so a customer can `claude plugin marketplace add`.
mkdir -p "$BUNDLE/.claude-plugin"
jq -n --arg n "$MARKET_NAME" --arg p "$PLUGIN_NAME" --arg v "$VERSION" '{
  name: $n,
  description: "Mollow memory-mirror plugin for Claude Code.",
  owner: { name: "Mollow" },
  plugins: [ { name: $p, source: ("./" + $p), version: $v } ]
}' > "$BUNDLE/.claude-plugin/marketplace.json"

# Validate the bundle has the pieces a plugin install needs.
for req in \
  "$BUNDLE/.claude-plugin/marketplace.json" \
  "$STAGE/.claude-plugin/plugin.json" \
  "$STAGE/hooks/hooks.json" \
  "$STAGE/hooks/guardrails-gate.sh" \
  "$STAGE/hooks/guardrail-predicates-portable.sh"; do
  [ -f "$req" ] || { echo "package: ABORT — missing required bundle file: $req" >&2; exit 1; }
done
echo "package: structure OK"

if [ "$DRY_RUN" = 1 ]; then
  echo "package: --dry-run OK — staged + sanitized + structure-validated against current inputs in a throwaway temp dir (no tarball written, real output dirs untouched)"
  exit 0
fi

# 6. Tarball. Tar by the archive's BASENAME after cd'ing into $OUT, so the
# written path is always $OUT/<name>.tgz and can never double-nest, regardless
# of how --out was spelled.
( cd "$OUT" && tar czf "${PLUGIN_NAME}-plugin-${VERSION}.tgz" "${PLUGIN_NAME}-plugin" )
echo "package: wrote $TARBALL"
echo "package: done"
