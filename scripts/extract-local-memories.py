#!/usr/bin/env python3
"""Extract Claude Code file-based memories into import_claude_memories entries.

Reads a project's `~/.claude/projects/<slug>/memory/*.md` files (and the inline
facts in `MEMORY.md`) and emits, on stdout, a JSON array of entries shaped for
Mollow's `import_claude_memories` MCP tool / `POST /api/memory/import`:

    {"content", "type", "name", "kind", "description",
     "origin_session_id", "source_file", "project"}

`type` is the Mollow memory class (knowledge|insight|preference); `kind` keeps
the original Claude Code category (feedback|reference|project|pattern|user|
memory_index) for provenance.

Deterministic and dependency-free: a minimal frontmatter reader (`_field`) is
the ONLY parse path — deliberately NOT PyYAML. PyYAML folds blank lines in a
`>-`/`|` block scalar into newlines, so its output for such a `description`
would depend on whether PyYAML happened to be installed, and would diverge from
the native app's Elixir port (`HostAgent.MemoryParser`, which mirrors `_field`).
Keeping a single hand-rolled reader makes the byte output identical on every
machine and across both collection paths, so they dedup against each other
instead of double-importing. Both the `import-local-memories` skill and the
auto-sync hook call this, so parsing has a single source of truth.

CONTRACT — FROZEN: the import dedups on a hash of `content`. The content
assembly here ("{name}\\n\\n{description}\\n\\n{body}") and the `_field`
frontmatter reader must never change, or re-imports would duplicate instead of
dedup.

Usage:
    extract-local-memories.py                 # current project (cwd)
    extract-local-memories.py --project PATH  # a specific project root
    extract-local-memories.py --dir PATH      # a specific memory/ dir
    extract-local-memories.py --all           # every project under --root
    extract-local-memories.py --no-index      # skip MEMORY.md inline facts
    extract-local-memories.py --skip-ephemeral  # drop host-specific facts (IPs, sockets)
"""

import argparse
import json
import re
import sys
from pathlib import Path

# Claude Code frontmatter `type` (or filename prefix) -> Mollow memory class.
TYPE_MAP = {
    "feedback": "preference",
    "reference": "knowledge",
    "project": "knowledge",
    "user": "preference",
    "pattern": "insight",
}
VALID_TYPES = {"knowledge", "insight", "preference"}

# Host-specific / transient facts that are noise in a durable cross-AI memory.
EPHEMERAL_RES = [
    re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"),  # IPv4 (e.g. a Tailscale IP)
    re.compile(r"/\S+\.sock\b"),  # unix socket paths
    re.compile(r"\blocalhost:\d+\b"),
]

# MEMORY.md index links: `[Title](target.md)`. The micro-hook is the text after
# the link up to the next link on the line (or EOL). Both the title and hook get
# attached to the linked topic file's entry as metadata (index_title/index_label).
LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")
# Separator/whitespace stripped from a hook's ends: space, tab, CR, em-dash (—),
# middle dot (·) — the two separators the index uses between a link and its hook.
# Regular hyphens are NOT stripped (they carry meaning: MOL-2511, Qwen3-4B).
LABEL_STRIP = " \t\r—·"


def _unquote(value):
    value = value.strip()
    m = re.match(r'^"([^"]*)"', value) or re.match(r"^'([^']*)'", value)
    return m.group(1) if m else value


def _field(frontmatter, key):
    """Pull a scalar `key` from a frontmatter block — top-level or nested,
    inline or folded/block (`>-`, `|`). Returns None when absent."""
    lines = frontmatter.split("\n")
    for idx, line in enumerate(lines):
        m = re.match(r"^([ \t]*)" + re.escape(key) + r":[ \t]*(.*)$", line)
        if not m:
            continue
        base_indent = len(m.group(1))
        value = m.group(2).strip()
        if value in ("", ">", ">-", "|", "|-"):
            collected = []
            for nxt in lines[idx + 1 :]:
                if nxt.strip() == "":
                    continue
                if len(nxt) - len(nxt.lstrip()) <= base_indent:
                    break
                collected.append(nxt.strip())
            joined = " ".join(collected).strip()
            return joined or None
        return _unquote(value)
    return None


def parse_frontmatter(text):
    """Return (meta_dict, body). meta_dict has name/description/type/originSessionId."""
    if not text.startswith("---"):
        return {}, text
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.DOTALL)
    if not m:
        return {}, text
    fm_raw, body = m.group(1), m.group(2)

    # `_field` is the single, deliberate parse path (no PyYAML — see module
    # docstring). It matches at any indent, so it finds `type` whether it sits
    # at the top level or nested under `metadata:`.
    meta = {key: _field(fm_raw, key) for key in ("name", "description", "type", "originSessionId")}

    return {k: v for k, v in meta.items() if v}, body


def resolve_type_and_kind(meta, filename):
    """(memory_type, kind). Map on frontmatter type; fall back to filename prefix."""
    raw = (meta.get("type") or "").strip().lower()
    if not raw and "_" in filename:
        raw = filename.split("_", 1)[0].lower()
    kind = raw or "memory"
    return TYPE_MAP.get(raw, "knowledge"), kind


def assemble_content(name, description, body):
    """FROZEN format — see module docstring."""
    parts = []
    if name:
        parts.append(name.strip())
    if description and description.strip() != (name or "").strip():
        parts.append(description.strip())
    body = (body or "").strip()
    if body:
        parts.append(body)
    return "\n\n".join(parts).strip()


def slugify(text):
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-")


def index_labels(text):
    """Map a topic filename -> (title, label) from MEMORY.md's index links.

    For every `[Title](file.md)` link — including each one in a multi-link row —
    the label is the micro-hook after the link (text up to the next link or EOL),
    with the leading/trailing separators (— · whitespace) stripped. First link to
    a given file wins, so a file referenced from two rows keeps its first hook.
    URL links and non-`.md` targets are ignored. Keyed by the target's basename,
    which matches `file_entry`'s `path.name`. Mirrored byte-for-byte by
    `HostAgent.MemoryParser.index_labels/1`.
    """
    labels = {}
    for line in text.split("\n"):
        matches = list(LINK_RE.finditer(line))
        for i, m in enumerate(matches):
            # Canonicalize before the .md check + keying so a fragment/query link
            # (`file.md#anchor`, `file.md?v=1`) still resolves to its topic file —
            # otherwise, with the `indexed` signal, a missed link reads as "unlinked"
            # and clears the topic's stored label.
            target = m.group(2).strip().split("#", 1)[0].split("?", 1)[0]
            if "://" in target or not target.endswith(".md"):
                continue
            filename = target.rsplit("/", 1)[-1]
            if filename in labels:
                continue
            hook_end = matches[i + 1].start() if i + 1 < len(matches) else len(line)
            title = m.group(1).strip() or None
            hook = line[m.end() : hook_end].strip(LABEL_STRIP) or None
            labels[filename] = (title, hook)
    return labels


def file_entry(path: Path, project, labels=None):
    """Build the import entry for one topic file.

    `labels` is the MEMORY.md link map from `index_labels` when the index was
    processed, or `None` when it wasn't (`--no-index`, or no MEMORY.md). A non-None
    `labels` marks the entry `indexed: true` — an authoritative statement of the
    current index state, so the server can clear a stale label when a file is
    unlinked (absent from the map). `None` leaves the entry unmarked, so a
    legacy/partial client that simply omits index fields never erases a label.
    """
    meta, body = parse_frontmatter(path.read_text(encoding="utf-8"))
    filename = path.name
    name = meta.get("name") or path.stem
    description = meta.get("description")
    memory_type, kind = resolve_type_and_kind(meta, filename)
    content = assemble_content(name, description, body)
    if not content:
        return None
    entry = {
        "content": content,
        "type": memory_type,
        "name": name,
        "kind": kind,
        "description": description,
        "origin_session_id": meta.get("originSessionId"),
        "source_file": filename,
        "project": project,
    }
    if labels is not None:
        entry["indexed"] = True
        title, label = labels.get(filename, (None, None))
        if title:
            entry["index_title"] = title
        if label:
            entry["index_label"] = label
    return entry


def memory_index_entries(path: Path, project, skip_ephemeral):
    """MEMORY.md as section-level chunks — one entry per top-level (``##``)
    section, holding all of its lines (pointer bullets, inline facts, ``###``
    subheadings, multi-link rows) verbatim.

    Pointer rows are kept, not skipped: the curated one-line hooks after each
    link are unique index data that never reaches the topic files themselves.
    Chunking by section (rather than per bullet) preserves the human's grouping,
    keeps multi-link rows coherent, and yields a handful of searchable entries
    instead of hundreds of context-free fragments. ``content`` is the section
    heading followed by its lines, blank-line- and fence-stripped;
    ``skip_ephemeral`` drops host-specific lines (IPs, sockets, localhost ports).
    """
    text = path.read_text(encoding="utf-8")

    entries = []
    seen_names = set()
    h2 = None
    buffer = []
    in_fence = False

    def flush():
        if h2 is not None and buffer:
            # Disambiguate headings that slugify to the same name: import keys
            # supersede on name + source_file + project, so two same-slug
            # sections in one MEMORY.md would hide each other. First keeps the
            # bare slug; later collisions get a "-N" suffix, probing past any
            # name already emitted (so a real "Security-2" heading and a
            # disambiguated duplicate never land on the same name). Deterministic
            # in document order, so an unchanged re-sync dedups cleanly.
            base = slugify(h2)[:80]
            name = base
            n = 1
            while name in seen_names:
                n += 1
                name = f"{base}-{n}"
            seen_names.add(name)
            entries.append(
                {
                    "content": h2 + "\n" + "\n".join(buffer),
                    "type": "knowledge",
                    "name": name,
                    "kind": "memory_index",
                    "description": None,
                    "origin_session_id": None,
                    "source_file": "MEMORY.md",
                    "project": project,
                }
            )

    for line in text.split("\n"):
        stripped = line.strip()
        if stripped.startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        if stripped.startswith("## "):
            flush()
            h2 = stripped[3:].strip()
            buffer = []
            continue
        if not stripped or h2 is None:
            continue
        if skip_ephemeral and any(r.search(stripped) for r in EPHEMERAL_RES):
            continue
        buffer.append(stripped)

    flush()
    return entries


def cwd_slug(path):
    # Claude Code names a project dir by its absolute path with separators and
    # dots turned into hyphens: /Users/x/my.app -> -Users-x-my-app. Use
    # `absolute()` (not `resolve()`) so symlinked paths keep the logical name
    # Claude Code used.
    return re.sub(r"[/.]", "-", str(Path(path).expanduser().absolute()))


def resolve_dirs(args):
    """Return [(memory_dir: Path, project_slug), ...]."""
    root = Path(args.root).expanduser()

    if args.dir:
        mdir = Path(args.dir).expanduser().absolute()
        slug = mdir.parent.name or "claude-code"
        return [(mdir, slug)]

    if args.all:
        return [(mdir, mdir.parent.name) for mdir in sorted(root.glob("*/memory"))]

    slug = cwd_slug(args.project or Path.cwd())
    return [(root / slug / "memory", slug)]


def main():
    ap = argparse.ArgumentParser(description="Extract Claude Code memories as import entries.")
    ap.add_argument("--dir", help="A specific memory/ directory to read.")
    ap.add_argument("--project", help="A project root path (its slug is derived).")
    ap.add_argument("--all", action="store_true", help="Every project under --root.")
    ap.add_argument("--root", default="~/.claude/projects", help="Projects root.")
    ap.add_argument("--no-index", dest="include_index", action="store_false", help="Skip MEMORY.md inline facts.")
    ap.add_argument(
        "--skip-ephemeral", action="store_true", help="Drop host-specific facts (IPs, socket paths, localhost ports)."
    )
    ap.add_argument(
        "--repo",
        help=(
            "The destination map's key for these memories (github.com/owner/name). "
            "Distinct from the project slug: the slug survives canonicalization "
            "unchanged and can never match a route row (MOL-4740). Omitted when "
            "absent, which is what keeps entry-for-entry parity with the Elixir "
            "parser's golden test."
        ),
    )
    ap.add_argument("--verbose", action="store_true", help="Print a summary to stderr.")
    args = ap.parse_args()

    entries = []
    dirs_seen = 0

    for mdir, project in resolve_dirs(args):
        if not mdir.is_dir():
            continue
        dirs_seen += 1
        # Parse MEMORY.md's per-link hooks first so each topic file entry can
        # carry its index_title/index_label. Gated on --index like the section
        # chunks: with --no-index we ignore MEMORY.md entirely.
        index = mdir / "MEMORY.md"
        # `None` (not `{}`) when the index wasn't processed, so `file_entry` leaves
        # the entry unmarked instead of asserting "indexed with no links".
        labels = index_labels(index.read_text(encoding="utf-8")) if args.include_index and index.is_file() else None
        for path in sorted(mdir.glob("*.md")):
            if path.name == "MEMORY.md":
                continue
            entry = file_entry(path, project, labels)
            if entry:
                entries.append(entry)
        if args.include_index and index.is_file():
            entries.extend(memory_index_entries(index, project, args.skip_ephemeral))

    # Applied here, not inside `file_entry`/`memory_index_entries`: those two are
    # the frozen contract the Elixir port asserts byte-parity against, and adding
    # a key inside them would break `memory_parser_golden_test.exs`. The Elixir
    # side attaches `repo` one layer up too, in `MemoryReader`.
    if args.repo:
        for entry in entries:
            entry["repo"] = args.repo

    json.dump(entries, sys.stdout, ensure_ascii=False)
    sys.stdout.write("\n")

    if args.verbose:
        by_type = {}
        for e in entries:
            by_type[e["type"]] = by_type.get(e["type"], 0) + 1
        sys.stderr.write(
            f"extract-local-memories: {len(entries)} entries from {dirs_seen} dir(s) {json.dumps(by_type)}\n"
        )


if __name__ == "__main__":
    main()
