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
frontmatter reader must not change the bytes of an entry that already parses
correctly, or re-imports would duplicate instead of dedup. The one deliberate
exception is a value the reader used to truncate at an escaped quote (MOL-6198):
its corrected content hashes differently and supersedes the truncated row.
Any change here lands in `HostAgent.MemoryParser` in the same commit —
`memory_parser_golden_test.exs` fails when the two diverge.

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

# The server rejects an entry whose `content` exceeds this
# (`@max_content_chars` in webapp/lib/mollow/mcp/memory_tools/params.ex, counted
# as graphemes). It rejects it INSIDE a 200 response — `results[i].ok: false`
# beside a top-level `ok: true` — so a caller reading the status code sees
# success and the entry simply never arrives (MOL-6699). MEMORY-catalog.md
# crossed this at 37,373 chars while looking synced.
#
# Measured in codepoints here, which can only OVERCOUNT a grapheme cluster
# (a cluster is one or more codepoints), so a chunk inside this bound is always
# inside the server's.
MAX_CONTENT_CHARS = 32_000

# A file this close to the cap is reported on stderr. The whole defect was
# silence: by the time the cap is crossed the rejection hides inside a 200, so
# the warning has to land while a human is still watching the extract.
WARN_RATIO = 0.9

# A fenced block opens with 3+ backticks or 3+ tildes. Tracked by marker rather
# than a boolean so a `~~~` block is a real fence and a longer run closes a
# shorter one, per CommonMark.
FENCE_RE = re.compile(r"^(`{3,}|~{3,})")

# The least body room a split is worth doing with. `name` and `description` repeat
# on every chunk, so as the budget shrinks the entry count grows superlinearly and
# each entry still carries the full header — a 1-char budget turned a 20,000-char
# body into 20,000 entries and 800 MB of `content`. Below this the file is left
# whole and rejected at import instead (MOL-6699, PR #6715 review round 2).
MIN_BODY_BUDGET = 8_000


# A quoted scalar runs to its first UNESCAPED closing quote: `\"` inside double
# quotes, `''` inside single quotes. `[^"]*` stopped at the first escape and
# dropped the rest of the value (MOL-4549, recurred as MOL-6198).
DOUBLE_QUOTED_RE = re.compile(r'^"((?:[^"\\]|\\.)*)"(.*)$')
SINGLE_QUOTED_RE = re.compile(r"^'((?:[^']|'')*)'(.*)$")
# The pre-MOL-6198 pattern. It still decides any value the new one cannot close
# (`"ends in a backslash\"`), so that value keeps the bytes it always had.
LEGACY_DOUBLE_QUOTED_RE = re.compile(r'^"([^"]*)"(.*)$')
# Only `\"` is unescaped. `\\` and every other backslash sequence keep their
# bytes: the old pattern read those values in full, and collapsing them would
# move the content hash of an unchanged file. HostAgent.MemoryParser mirrors this.
BACKSLASH_PAIR_RE = re.compile(r"\\(.)")


def _unescape_quotes(inner):
    return BACKSLASH_PAIR_RE.sub(lambda m: '"' if m.group(1) == '"' else m.group(0), inner)


# `name` keeps the pre-MOL-6198 parse byte for byte. It is the server's supersede
# key (with project + source_file): if its bytes moved, a re-import would miss
# the prior row and both versions would stay active in recall. A name that still
# truncates is reported through `on_trailing` instead.
LEGACY_FIELDS = frozenset({"name"})
LEGACY_SINGLE_QUOTED_RE = re.compile(r"^'([^']*)'(.*)$")


def _unquote(value, on_trailing=None, legacy=False):
    """Strip one level of quoting. `on_trailing(rest)` is called when text follows
    the closing quote — the shape that still loses part of the line."""
    value = value.strip()
    if legacy:
        m = LEGACY_DOUBLE_QUOTED_RE.match(value) or LEGACY_SINGLE_QUOTED_RE.match(value)
        if not m:
            return value
        inner = m.group(1)
    elif m := DOUBLE_QUOTED_RE.match(value):
        inner = _unescape_quotes(m.group(1))
    elif m := LEGACY_DOUBLE_QUOTED_RE.match(value):
        inner = m.group(1)
    else:
        m = SINGLE_QUOTED_RE.match(value)
        if not m:
            return value
        inner = m.group(1).replace("''", "'")
    if on_trailing and m.group(2).strip():
        on_trailing(m.group(2).strip())
    return inner


def _field(frontmatter, key, on_trailing=None):
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
        report = on_trailing and (lambda rest: on_trailing(key, rest))
        return _unquote(value, report, legacy=key in LEGACY_FIELDS)
    return None


def parse_frontmatter(text, on_trailing=None):
    """Return (meta_dict, body). meta_dict has name/description/type/originSessionId.

    `on_trailing(key, rest)` reports a quoted field with text after its closing
    quote; that text is dropped from the value."""
    if not text.startswith("---"):
        return {}, text
    m = re.match(r"^---\s*\n(.*?)\n---\s*\n?(.*)$", text, re.DOTALL)
    if not m:
        return {}, text
    fm_raw, body = m.group(1), m.group(2)

    # `_field` is the single, deliberate parse path (no PyYAML — see module
    # docstring). It matches at any indent, so it finds `type` whether it sits
    # at the top level or nested under `metadata:`.
    meta = {key: _field(fm_raw, key, on_trailing) for key in ("name", "description", "type", "originSessionId")}

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

    def warn_trailing(key, rest):
        # stderr only: stdout is the JSON the import reads. The auto-sync hook
        # discards stderr, so this reaches direct and skill-driven runs.
        sys.stderr.write(
            f"warning: {path.name}: `{key}` has text after its closing quote, which is dropped: {rest!r}\n"
        )

    meta, body = parse_frontmatter(path.read_text(encoding="utf-8"), warn_trailing)
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


def fence_marker(stripped):
    """The opening/closing fence run at the start of a line (``` or ~~~, 3+), else None."""
    m = FENCE_RE.match(stripped)
    return m.group(1) if m else None


def section_prefix(heading):
    """The `## heading` lines a chunk of that section opens with ("" when absent)."""
    return f"## {heading}\n\n" if heading else ""


def split_sections(body):
    """Split a body at top-level `## ` headings, ignoring any inside a fence.

    Returns `[(heading | None, text), ...]` in document order; text before the
    first heading carries `None`.

    Fences are tracked by MARKER, not by a boolean: a `~~~` block is a real
    fence, and treating only backticks as one made a `## Example` inside a tilde
    block a section boundary — splitting the block away from its own closing
    fence. A closing run must use the same character and be at least as long as
    the opening one, per CommonMark.

    A section is kept when it has a heading OR non-blank text. Filtering on text
    alone dropped a standalone `## Projects` whose body is empty, and the heading
    is the content there — it is stored separately, so nothing else carried it.

    Mirrored by `HostAgent.MemoryParser.split_sections/1` byte for byte.
    """
    sections = []
    heading = None
    buffer = []
    fence = None

    for line in body.split("\n"):
        stripped = line.lstrip()
        marker = fence_marker(stripped)

        if fence is None and marker:
            fence = marker
            buffer.append(line)
            continue
        if fence is not None:
            if marker and marker[0] == fence[0] and len(marker) >= len(fence):
                fence = None
            buffer.append(line)
            continue
        # `## Foo` but not `### Foo` — only top-level sections are boundaries.
        if stripped.startswith("## ") and not stripped.startswith("### "):
            sections.append((heading, "\n".join(buffer)))
            heading = stripped[3:].strip()
            buffer = []
            continue
        buffer.append(line)

    sections.append((heading, "\n".join(buffer)))
    return [(h, t) for h, t in sections if t.strip() or h]


def split_long_line(line, budget):
    """Cut one over-budget line into pieces of at most `budget` chars.

    Line splitting alone cannot bound a chunk: a single line can exceed the
    budget on its own (a wide table row, a long one-line paragraph, an embedded
    blob) and would otherwise ride through whole and break the bound the split
    exists to enforce.
    """
    if len(line) <= budget:
        return [line]
    return [line[i : i + budget] for i in range(0, len(line), budget)] or [""]


def accumulate_chunks(text, budget):
    """Pack `text`'s lines into chunks of at most `budget` chars, on line
    boundaries where possible."""
    chunks = []
    current = []
    size = 0

    for raw in text.split("\n"):
        for line in split_long_line(raw, budget):
            # +1 for the newline that will rejoin this line to the previous one.
            addition = len(line) + (1 if current else 0)
            if current and size + addition > budget:
                chunks.append("\n".join(current))
                current, size = [line], len(line)
            else:
                current.append(line)
                size += addition

    chunks.append("\n".join(current))
    return [c for c in chunks if c.strip()]


def bounded_chunks(heading, text, budget):
    """`[(heading, chunk, suffix), ...]` for one section, each within `budget`.

    `suffix` is None for a section that fits whole, else `part-N` — the thing
    that keeps two parts of one section off the same entry name.
    """
    if len(text) <= budget:
        return [(heading, text, None)]
    parts = accumulate_chunks(text, budget)
    return [(heading, chunk, f"part-{i}") for i, chunk in enumerate(parts, 1)]


def _content_overhead(name, description):
    """Chars `assemble_content` adds around a body part (name, description,
    and the blank lines joining them)."""
    return len(assemble_content(name, description, "X")) - 1


def file_entries(path: Path, project, labels=None, max_chars=MAX_CONTENT_CHARS):
    """Import entries for one topic file: `[entry]` when it fits, several when
    it does not.

    A file at or under `max_chars` yields EXACTLY the entry `file_entry` has
    always produced, byte for byte — that is the frozen dedup contract, and the
    reason the threshold is a cap rather than a target. Only a file the server
    would reject is split, at its top-level headings, with a still-oversized
    section cut into bounded parts.

    Split entries keep the file's real `source_file`, `type` and `kind` —
    splitting is a transport concern and must not relabel what the memory is —
    and carry `fanned_out: true`, which is how the server's file projection
    knows to nest them under the file's stem instead of resolving every chunk to
    one colliding path (`Mollow.Memory.FileProjection.file_segments/1`).

    Mirrored by `HostAgent.MemoryParser.file_entries/3`; the golden test asserts
    the two agree byte for byte.
    """
    whole = file_entry(path, project, labels)
    if whole is None:
        return []

    size = len(whole["content"])

    if size <= max_chars:
        # Approaching the cap but still within it. Said here, not after the split
        # decision, because this file is not being split at all.
        if size >= max_chars * WARN_RATIO:
            sys.stderr.write(
                f"warning: {path.name}: content is {size} chars, at or past "
                f"{int(WARN_RATIO * 100)}% of the {max_chars}-char import cap\n"
            )
        return [whole]

    # An unreadable file keeps its whole entry rather than becoming nothing. Without
    # this, an empty body means `split_sections("")` is `[]`, the split fans out over
    # zero sections, and the memory is dropped while stderr reports "split into 0
    # entries" — the silent loss this script exists to remove. A race (the file was
    # readable moments earlier in `file_entry`), but whole means rejected at import and
    # audible, which is strictly better than absent and quiet.
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        sys.stderr.write(
            f"warning: {path.name}: became unreadable between reads ({exc}) — keeping the "
            f"whole entry, which the import will reject at {size} chars\n"
        )
        return [whole]

    _meta, body = parse_frontmatter(text)
    name = whole["name"]
    overhead = _content_overhead(name, whole["description"])

    # `name` and `description` repeat on every chunk, so a wide enough pair leaves
    # too little room for the body. Splitting anyway is NOT a smaller problem than
    # not splitting: at a 1-char budget a 20,000-char body becomes 20,000 entries
    # that each repeat the oversized header — measured at 800 MB of `content` for
    # a 40,000-char description, which blows the bridge's message limit and so
    # stops the healthy files syncing too. Expanding every character into an entry
    # is the failure, not the floor.
    #
    # So below a usable budget the file is NOT split. It is emitted whole, which is
    # what it always was: rejected at import, now loudly, while every other file in
    # the listing still syncs. No split can make a file whose header alone fills the
    # cap conform, and the entry count stays bounded at one either way.
    budget = max_chars - overhead
    sections = split_sections((body or "").strip())

    # The decision is made against the WORST section, because the heading is part of
    # each chunk's content too. Taking `max(MIN_BODY_BUDGET, budget - len(prefix))`
    # instead was a defect: it RAISED a section's budget back up to the floor when
    # the real room was less, emitting entries over the cap — measured at five
    # entries of 32,005 chars for a 23,990-char description plus `## Alpha`, every
    # one of them rejected, which is the exact failure this whole change exists to
    # remove. The floor decides WHETHER to split; it never grants room.
    widest = max([len(section_prefix(heading)) for heading, _ in sections], default=0)
    room = budget - widest
    if room < MIN_BODY_BUDGET:
        sys.stderr.write(
            f"warning: {path.name}: name + description take {overhead} of the {max_chars}-char "
            f"cap and the widest heading {widest} more, leaving "
            f"{room} for the body — too little to split on, so it is left whole and will be rejected "
            f"at import. Shorten its name or description.\n"
        )
        return [whole]

    pieces = []
    # The prefix is derived here rather than precomputed into a parallel list. A
    # `zip(sections, prefixes)` needs the two to stay aligned, and `strict=True` is
    # NOT the way to enforce that here: it is a runtime kwarg added in Python 3.10,
    # this script runs under whatever `python3` is on PATH, and its syntax otherwise
    # parses as far back as 3.8 — so on an older interpreter it would raise
    # TypeError only on the over-cap path, where the auto-sync hook discards stderr
    # and records the empty output as a successful sync. Deriving in the loop removes
    # the alignment question instead of policing it.
    for heading, text in sections:
        prefix = section_prefix(heading)
        for _, chunk, suffix in bounded_chunks(heading, text, budget - len(prefix)):
            pieces.append((heading, prefix, chunk, suffix))

    entries = []
    seen = set()
    for idx, (heading, prefix, chunk, suffix) in enumerate(pieces):
        # The FIRST chunk always takes the bare whole-file name, so a file that
        # grows past the cap supersedes its own prior single row (the supersede
        # key is name + source_file + project) instead of orphaning it. Keying
        # the first chunk on its heading instead only looked right for a file
        # with preamble text before its first `##`: `split_sections` drops the
        # empty preamble, so a file that opens directly with a heading got
        # `name--section` as its first chunk and left a stale row under `name`
        # live in recall alongside the new ones.
        parts = (name,) if idx == 0 else (name, heading and slugify(heading), suffix)
        base = "--".join(p for p in parts if p)[:120]
        chunk_name = base
        n = 1
        while chunk_name in seen:
            n += 1
            chunk_name = f"{base}-{n}"
        seen.add(chunk_name)

        entry = dict(whole)
        entry["content"] = assemble_content(name, whole["description"], prefix + chunk)
        entry["name"] = chunk_name
        entry["fanned_out"] = True
        entries.append(entry)

    # A split that yields nothing must not delete the memory. The read-error path
    # above is the known way in, but this is the backstop for any future one:
    # returning the whole entry means rejected-and-audible, never absent-and-quiet.
    if not entries:
        sys.stderr.write(
            f"warning: {path.name}: splitting produced no entries — keeping the whole entry, "
            f"which the import will reject at {size} chars\n"
        )
        return [whole]

    sys.stderr.write(
        f"warning: {path.name}: content is {size} chars, past the {max_chars}-char import "
        f"cap — split into {len(entries)} entries\n"
    )
    return entries


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
            entries.extend(file_entries(path, project, labels))
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
