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


def test_file_entry_attaches_index_title_and_label(tmp_path):
    f = tmp_path / "reference_thing.md"
    f.write_text("---\nname: Thing\n---\nBody.\n", encoding="utf-8")
    labels = {"reference_thing.md": ("A Thing", "#42; the hook")}
    entry = elm.file_entry(f, "p", labels)
    assert entry["indexed"] is True
    assert entry["index_title"] == "A Thing"
    assert entry["index_label"] == "#42; the hook"


def test_file_entry_omits_label_keys_when_unlinked_or_empty(tmp_path):
    f = tmp_path / "reference_thing.md"
    f.write_text("---\nname: Thing\n---\nBody.\n", encoding="utf-8")
    # Index processed but this file isn't linked → indexed, no label keys.
    unlinked = elm.file_entry(f, "p", {})
    assert unlinked["indexed"] is True
    assert "index_title" not in unlinked
    assert "index_label" not in unlinked
    # Linked but empty hook → title present, label omitted (put_if semantics).
    entry = elm.file_entry(f, "p", {"reference_thing.md": ("A Thing", None)})
    assert entry["index_title"] == "A Thing"
    assert "index_label" not in entry


def test_file_entry_unindexed_when_index_not_processed(tmp_path):
    # labels=None (default / --no-index / no MEMORY.md) → the entry is NOT marked
    # indexed, so the server won't read absent labels as an unlink+clear signal.
    f = tmp_path / "reference_thing.md"
    f.write_text("---\nname: Thing\n---\nBody.\n", encoding="utf-8")
    for entry in (elm.file_entry(f, "p"), elm.file_entry(f, "p", None)):
        assert "indexed" not in entry
        assert "index_title" not in entry
        assert "index_label" not in entry


# ── index_labels ─────────────────────────────────────────────────────────────


def test_index_labels_single_link_strips_em_dash_separator():
    text = "## S\n- [Dash0](reference_dash0.md) — #3062; env label prod/staging\n"
    assert elm.index_labels(text) == {"reference_dash0.md": ("Dash0", "#3062; env label prod/staging")}


def test_index_labels_multi_link_row_each_link_keyed_hook_between_links():
    text = "## G\n- **GBrain**: [eval](a.md) MOL-1 first · [graph](b.md) MOL-2 CTE · [rrf](c.md)\n"
    assert elm.index_labels(text) == {
        "a.md": ("eval", "MOL-1 first"),
        "b.md": ("graph", "MOL-2 CTE"),
        "c.md": ("rrf", None),  # last link on the line → empty hook
    }


def test_index_labels_first_link_to_a_file_wins():
    text = "## A\n- [first hook](dup.md) wins\n## B\n- [second](dup.md) ignored\n"
    assert elm.index_labels(text)["dup.md"] == ("first hook", "wins")


def test_index_labels_ignores_urls_and_non_md_targets():
    text = "## S\n- [site](https://example.com) x · [img](pic.png) y · [ok](topic.md) keep\n"
    assert elm.index_labels(text) == {"topic.md": ("ok", "keep")}


def test_index_labels_canonicalizes_fragment_and_query_targets():
    # `file.md#anchor` / `file.md?v=1` must resolve to the topic file, not be
    # skipped (which, with the indexed signal, would clear the topic's label).
    text = "## S\n- [Frag](topic_alpha.md#details) hook · [Query](topic_beta.md?v=1) other\n"
    assert elm.index_labels(text) == {
        "topic_alpha.md": ("Frag", "hook"),
        "topic_beta.md": ("Query", "other"),
    }


def test_index_labels_keeps_interior_hyphens():
    # Regular hyphens carry meaning and must survive; only —/· separators strip.
    text = "## S\n- [cap](project_macos_activity_capture.md) — MOL-2511 CGEventTap→Engram\n"
    assert elm.index_labels(text)["project_macos_activity_capture.md"] == (
        "cap",
        "MOL-2511 CGEventTap→Engram",
    )


if __name__ == "__main__":
    raise SystemExit(pytest.main([__file__, "-v"]))


# ── --repo (MOL-4740 / MOL-4502 step 5) ─────────────────────────────────────
#
# `repo` is the destination map's key; `project` beside it is the directory
# slug, which survives canonicalization unchanged and can never match a route
# row. Without `repo` on the entry, every memory this producer syncs through
# POST /api/memory/import resolves to the private workspace.


def _run_extractor(tmp_path, extra_args):
    """Run the extractor CLI over a one-file fixture and return its entries."""
    import json
    import subprocess
    import sys

    root = tmp_path / "projects"
    mdir = root / "-Users-x-dev-thing" / "memory"
    mdir.mkdir(parents=True)
    (mdir / "reference_a.md").write_text(
        "---\nname: reference_a\ndescription: a thing\nmetadata:\n  type: reference\n---\n\nBody.\n",
        encoding="utf-8",
    )

    script = Path(__file__).resolve().parent / "extract-local-memories.py"
    out = subprocess.run(
        [sys.executable, str(script), "--dir", str(mdir), *extra_args],
        capture_output=True,
        text=True,
        check=True,
    )
    return json.loads(out.stdout)


def test_repo_is_omitted_when_not_given(tmp_path):
    # Parity with the Elixir parser's golden test depends on this: an absent
    # --repo must add no key at all, not an empty one.
    entries = _run_extractor(tmp_path, [])

    assert entries, "precondition: the fixture must produce an entry"
    for entry in entries:
        assert "repo" not in entry


def test_repo_is_attached_to_every_entry_when_given(tmp_path):
    entries = _run_extractor(tmp_path, ["--repo", "github.com/mollowai/monorepo"])

    assert entries
    for entry in entries:
        assert entry["repo"] == "github.com/mollowai/monorepo"


def test_repo_and_project_stay_distinct(tmp_path):
    # The whole reason for a second field. Collapsing them would feed a slug to
    # the map, which cannot match a route row.
    entries = _run_extractor(tmp_path, ["--repo", "github.com/mollowai/monorepo"])

    for entry in entries:
        assert entry["project"] == "-Users-x-dev-thing"
        assert entry["repo"] != entry["project"]
