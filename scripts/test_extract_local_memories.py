"""Tests for extract-local-memories.py — the frozen content contract that the
import dedup/supersede behavior depends on.

The script has a hyphenated filename (not import-safe), so it's loaded by path.
Run with: python -m pytest plugins/memory-mirror/scripts/test_extract_local_memories.py
"""

import importlib.util
from pathlib import Path

import pytest

_MODULE_PATH = Path(__file__).parent / "extract-local-memories.py"
_spec = importlib.util.spec_from_file_location("extract_local_memories", _MODULE_PATH)
elm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(elm)


# ── parse_frontmatter ────────────────────────────────────────────────────────


def test_parse_frontmatter_no_frontmatter():
    meta, body = elm.parse_frontmatter("just a body, no frontmatter\n")
    assert meta == {}
    assert body == "just a body, no frontmatter\n"


def test_parse_frontmatter_top_level_scalars():
    text = "---\nname: Foo\ndescription: A thing\ntype: feedback\n---\nbody here\n"
    meta, body = elm.parse_frontmatter(text)
    assert meta["name"] == "Foo"
    assert meta["description"] == "A thing"
    assert meta["type"] == "feedback"
    assert body == "body here\n"


def test_parse_frontmatter_nested_metadata_type():
    # `type` nested under `metadata:` must still resolve (via the `_field` reader,
    # which matches at any indent).
    text = "---\nname: Bar\nmetadata:\n  type: pattern\n  originSessionId: sess-123\n---\nbody\n"
    meta, _ = elm.parse_frontmatter(text)
    assert meta["type"] == "pattern"
    assert meta["originSessionId"] == "sess-123"


def test_parse_frontmatter_folded_description():
    text = "---\nname: Folded\ndescription: >-\n  line one\n  line two\n---\nbody\n"
    meta, _ = elm.parse_frontmatter(text)
    assert meta["description"] == "line one line two"


def test_parse_frontmatter_folded_description_blank_line_is_space_joined():
    # A blank line inside a `>-` block must fold to a single SPACE, not a newline.
    # This is the deliberate divergence from PyYAML (which would yield "...one\n...two"):
    # `_field` is the sole parse path so the bytes are identical on every machine and
    # match the Elixir port (HostAgent.MemoryParser), keeping dedup intact.
    text = "---\nname: Folded\ndescription: >-\n  para one\n\n  para two\n---\nbody\n"
    meta, _ = elm.parse_frontmatter(text)
    assert meta["description"] == "para one para two"


def test_parse_frontmatter_quoted_scalar():
    text = '---\nname: "Quoted Name"\ntype: reference\n---\nbody\n'
    meta, body = elm.parse_frontmatter(text)
    assert meta["name"] == "Quoted Name"
    assert meta["type"] == "reference"
    assert body == "body\n"


def test_parse_frontmatter_malformed_block_returns_raw():
    # Opening fence without a closing `---` is not a valid frontmatter block.
    text = "---\nname: Foo\nno closing fence\n"
    meta, body = elm.parse_frontmatter(text)
    assert meta == {}
    assert body == text


# ── assemble_content (FROZEN contract) ───────────────────────────────────────


def test_assemble_content_frozen_format():
    assert elm.assemble_content("Name", "Desc", "Body") == "Name\n\nDesc\n\nBody"


def test_assemble_content_is_deterministic():
    a = elm.assemble_content("N", "D", "B")
    b = elm.assemble_content("N", "D", "B")
    assert a == b


def test_assemble_content_dedups_name_equal_description():
    # When description merely repeats the name it must be dropped, not duplicated.
    assert elm.assemble_content("Same", "Same", "Body") == "Same\n\nBody"


def test_assemble_content_omits_missing_parts():
    assert elm.assemble_content("OnlyName", None, "") == "OnlyName"
    assert elm.assemble_content(None, None, "OnlyBody") == "OnlyBody"
    assert elm.assemble_content(None, None, "") == ""


# ── resolve_type_and_kind ────────────────────────────────────────────────────


def test_resolve_type_and_kind_from_frontmatter():
    assert elm.resolve_type_and_kind({"type": "feedback"}, "anything.md") == ("preference", "feedback")
    assert elm.resolve_type_and_kind({"type": "pattern"}, "x.md") == ("insight", "pattern")


def test_resolve_type_and_kind_filename_prefix_fallback():
    # No frontmatter type → derive from the `<prefix>_rest.md` filename convention.
    assert elm.resolve_type_and_kind({}, "reference_apple.md") == ("knowledge", "reference")


def test_resolve_type_and_kind_unknown_defaults_to_knowledge():
    assert elm.resolve_type_and_kind({}, "no-prefix.md") == ("knowledge", "memory")


# ── memory_index_entries (MEMORY.md inline facts) ────────────────────────────


def _write(tmp_path, text):
    p = tmp_path / "MEMORY.md"
    p.write_text(text, encoding="utf-8")
    return p


def test_memory_index_chunks_by_section_keeping_pointer_rows(tmp_path):
    # One entry per section; pointer rows are now KEPT (their curated hooks are
    # unique index data), alongside inline facts, in document order.
    path = _write(tmp_path, "## Section\n- [Title](some-file.md) — a pointer\n- a real inline fact\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert [e["content"] for e in entries] == ["Section\n- [Title](some-file.md) — a pointer\n- a real inline fact"]


def test_memory_index_one_entry_per_section(tmp_path):
    path = _write(tmp_path, "## A\n- one\n- two\n## B\n- three\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert [e["content"] for e in entries] == ["A\n- one\n- two", "B\n- three"]
    assert [e["name"] for e in entries] == ["a", "b"]


def test_memory_index_disambiguates_colliding_section_names(tmp_path):
    # Two headings that slugify to the same name would otherwise share the
    # import versioning key (name + source_file + project), so the second
    # section would supersede — and hide — the first. Distinct names keep both.
    path = _write(tmp_path, "## Security\n- first fact\n## Security!\n- second fact\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert [e["name"] for e in entries] == ["security", "security-2"]
    # Content still differs, so both survive content-hash dedup; the disambiguated
    # names ensure neither supersedes the other on import.
    assert [e["content"] for e in entries] == ["Security\n- first fact", "Security!\n- second fact"]


def test_memory_index_disambiguation_is_stable_across_runs(tmp_path):
    # Same input, same document order -> identical names every run, so a
    # re-sync of an unchanged MEMORY.md dedups cleanly.
    text = "## Dup\n- a\n## Dup\n- b\n## Dup\n- c\n"
    names = [e["name"] for e in elm.memory_index_entries(_write(tmp_path, text), "proj", skip_ephemeral=False)]
    assert names == ["dup", "dup-2", "dup-3"]


def test_memory_index_disambiguation_avoids_generated_suffix_collision(tmp_path):
    # A real heading that already looks like a generated suffix must not collide
    # with a disambiguated duplicate: "Security-2" takes security-2, so the
    # second "Security" probes past it to security-3.
    text = "## Security\n- a\n## Security-2\n- b\n## Security\n- c\n"
    names = [e["name"] for e in elm.memory_index_entries(_write(tmp_path, text), "proj", skip_ephemeral=False)]
    assert names == ["security", "security-2", "security-3"]


def test_memory_index_preserves_multi_link_rows_verbatim(tmp_path):
    row = "- [Eval](a.md) MOL-1 · [Graph](b.md) MOL-2 · [Fusion](c.md) MOL-3"
    path = _write(tmp_path, f"## GBrain\n{row}\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert entries[0]["content"] == f"GBrain\n{row}"


def test_memory_index_respects_code_fences(tmp_path):
    path = _write(tmp_path, "## S\n```\n- not a fact, inside a fence\n```\n- real fact\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert [e["content"] for e in entries] == ["S\n- real fact"]


def test_memory_index_h3_subheading_is_body_line(tmp_path):
    path = _write(tmp_path, "## Top\n### Sub\n- nested fact\n")
    entries = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert entries[0]["content"] == "Top\n### Sub\n- nested fact"


def test_memory_index_skip_ephemeral_drops_host_lines_from_chunk(tmp_path):
    text = "## Infra\n- IP is 100.69.225.80\n- socket at /tmp/foo.sock\n- bind localhost:8080\n- durable fact\n"
    path = _write(tmp_path, text)
    kept = elm.memory_index_entries(path, "proj", skip_ephemeral=True)
    assert [e["content"] for e in kept] == ["Infra\n- durable fact"]
    # Without the flag, all four lines stay in the one section chunk.
    without = elm.memory_index_entries(path, "proj", skip_ephemeral=False)
    assert len(without) == 1
    assert without[0]["content"].count("\n") == 4


def test_memory_index_entry_shape_and_slug(tmp_path):
    path = _write(tmp_path, "## My Section\n- some fact here\n")
    entry = elm.memory_index_entries(path, "myproj", skip_ephemeral=False)[0]
    assert entry["kind"] == "memory_index"
    assert entry["source_file"] == "MEMORY.md"
    assert entry["project"] == "myproj"
    assert entry["type"] == "knowledge"
    assert entry["name"] == elm.slugify("My Section")[:80]
    assert " " not in entry["name"]


# ── file_entry ───────────────────────────────────────────────────────────────


def test_file_entry_resolves_type_kind_and_provenance(tmp_path):
    f = tmp_path / "feedback_be_blunt.md"
    f.write_text(
        "---\nname: Be Blunt\ndescription: No padding\ntype: feedback\n---\nLead with problems.\n",
        encoding="utf-8",
    )
    entry = elm.file_entry(f, "myproj")
    assert entry["type"] == "preference"
    assert entry["kind"] == "feedback"
    assert entry["name"] == "Be Blunt"
    assert entry["source_file"] == "feedback_be_blunt.md"
    assert entry["project"] == "myproj"
    assert entry["content"] == "Be Blunt\n\nNo padding\n\nLead with problems."


def test_file_entry_name_falls_back_to_stem(tmp_path):
    f = tmp_path / "pattern_thing.md"
    f.write_text("no frontmatter, just body\n", encoding="utf-8")
    entry = elm.file_entry(f, "p")
    # No frontmatter name → path stem; filename prefix drives kind.
    assert entry["name"] == "pattern_thing"
    assert entry["kind"] == "pattern"
    assert entry["type"] == "insight"


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))
