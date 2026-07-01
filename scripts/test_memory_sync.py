"""Tests for memory_sync — the local↔Mollow memory verify/status/push tool.

Covers the pure, deterministic core: env→URL mapping, the credential-send
security guard (mirrors hooks/_common.sh `mm_ready`), keyfile parsing, the
read-only export diff, and target resolution precedence. Network I/O and the
CLI are integration-tested separately (test-memory-sync.sh).
"""

import importlib.util
import json
from pathlib import Path

import pytest

_MOD_PATH = Path(__file__).with_name("memory_sync.py")
_spec = importlib.util.spec_from_file_location("memory_sync", _MOD_PATH)
memory_sync = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(memory_sync)


# ── env → URL ────────────────────────────────────────────────────────────────


def test_env_to_url_known_envs():
    assert memory_sync.env_to_url("dev") == "http://localhost:4000/mcp/v2"
    assert memory_sync.env_to_url("staging") == "https://staging.mollow.ai/mcp/v2"
    assert memory_sync.env_to_url("prod") == "https://mollow.ai/mcp/v2"


def test_env_to_url_unknown_raises():
    with pytest.raises(ValueError):
        memory_sync.env_to_url("production")  # must be 'prod', not 'production'


def test_env_to_url_matches_fleet_target():
    # These three strings are the contract shared with scripts/fleet-target.sh
    # (ft_env_to_base_url). If fleet-target changes an env's base, this test is
    # the tripwire that says "update both".
    for env in ("dev", "staging", "prod"):
        assert memory_sync.env_to_url(env).endswith("/mcp/v2")


# ── api_base ─────────────────────────────────────────────────────────────────


def test_api_base_strips_mcp_suffix():
    assert memory_sync.api_base("https://mollow.ai/mcp/v2") == "https://mollow.ai"
    assert memory_sync.api_base("https://staging.mollow.ai/mcp/v2") == "https://staging.mollow.ai"


def test_api_base_tolerates_trailing_slash():
    assert memory_sync.api_base("https://mollow.ai/mcp/v2/") == "https://mollow.ai"


def test_api_base_localhost():
    assert memory_sync.api_base("http://localhost:4000/mcp/v2") == "http://localhost:4000"


# ── credential-send guard (mirror of _common.sh mm_ready) ────────────────────


@pytest.mark.parametrize(
    ("url", "ok"),
    [
        ("https://mollow.ai/mcp/v2", True),
        ("https://staging.mollow.ai/mcp/v2", True),
        ("http://localhost:4000/mcp/v2", True),
        ("http://127.0.0.1:4000/mcp/v2", True),
        # http to a non-loopback host must be refused (would leak the mol_* key).
        ("http://mollow.ai/mcp/v2", False),
        ("http://localhost.evil.com/mcp/v2", False),
        # missing the load-bearing /mcp/v2 suffix.
        ("https://mollow.ai", False),
        ("https://mollow.ai/api/memory", False),
    ],
)
def test_url_send_ok(url, ok):
    assert memory_sync.url_send_ok(url) is ok


# ── keyfile parsing (mol-keys.env) ───────────────────────────────────────────


def test_parse_keyfile_basic():
    text = "MOL_KEY_DEV=mol_dev1\nMOL_KEY_PROD=mol_prod1\nMOL_KEY_STAGING=mol_stg1\n"
    assert memory_sync.parse_keyfile(text) == {
        "dev": "mol_dev1",
        "prod": "mol_prod1",
        "staging": "mol_stg1",
    }


def test_parse_keyfile_tolerates_export_and_quotes():
    text = "export MOL_KEY_PROD=\"mol_prod1\"\nMOL_KEY_STAGING='mol_stg1'\n# a comment\n"
    parsed = memory_sync.parse_keyfile(text)
    assert parsed["prod"] == "mol_prod1"
    assert parsed["staging"] == "mol_stg1"


def test_parse_keyfile_last_wins():
    text = "MOL_KEY_PROD=mol_old\nMOL_KEY_PROD=mol_new\n"
    assert memory_sync.parse_keyfile(text)["prod"] == "mol_new"


# ── export NDJSON → memory contents ──────────────────────────────────────────


def _ndjson(*objs):
    return "\n".join(json.dumps(o) for o in objs) + "\n"


def test_parse_export_memory_contents_only_memories():
    text = _ndjson(
        {"type": "manifest", "counts": {"messages": 3}},
        {"type": "session", "id": "s1", "condensed_text": "not a memory"},
        {"type": "message", "content": "a plain transcript message", "memory_type": None},
        {"type": "memory", "content": "REAL MEMORY ONE", "memory_type": "knowledge"},
        {"type": "memory", "content": "REAL MEMORY TWO", "memory_type": "preference"},
    )
    got = memory_sync.parse_export_memory_contents(text)
    assert got == {"REAL MEMORY ONE", "REAL MEMORY TWO"}


def test_parse_export_ignores_blank_and_malformed_lines():
    text = "\n".join(
        [
            json.dumps({"type": "memory", "content": "keep me", "memory_type": "knowledge"}),
            "",
            "not json at all",
            "   ",
        ]
    )
    assert memory_sync.parse_export_memory_contents(text) == {"keep me"}


# ── diff ─────────────────────────────────────────────────────────────────────


def test_diff_all_present():
    local = [{"name": "a", "content": "X"}, {"name": "b", "content": "Y"}]
    remote = {"X", "Y", "Z"}
    d = memory_sync.diff_entries(local, remote)
    assert d["local_count"] == 2
    assert d["present_count"] == 2
    assert d["missing_count"] == 0
    assert d["missing"] == []


def test_diff_reports_missing_by_name():
    local = [{"name": "a", "content": "X"}, {"name": "gone", "content": "MISSING"}]
    remote = {"X"}
    d = memory_sync.diff_entries(local, remote)
    assert d["missing_count"] == 1
    assert d["missing"][0]["name"] == "gone"
    assert d["present_count"] == 1


def test_diff_empty_local():
    d = memory_sync.diff_entries([], {"X"})
    assert d["local_count"] == 0
    assert d["missing_count"] == 0


# ── resolve_target precedence ────────────────────────────────────────────────


KEYFILE = {"dev": "mol_dev", "staging": "mol_stg", "prod": "mol_prod"}


def test_resolve_explicit_env_arg_wins():
    # An explicit --env overrides everything else, keyed from the keyfile.
    t = memory_sync.resolve_target(
        env_arg="prod",
        environ={"MOLLOW_MEMORY_URL": "https://staging.mollow.ai/mcp/v2", "MOLLOW_MEMORY_API_KEY": "mol_stg"},
        selected_env="staging",
        keyfile=KEYFILE,
    )
    assert t["env"] == "prod"
    assert t["url"] == "https://mollow.ai/mcp/v2"
    assert t["key"] == "mol_prod"
    assert t["source"] == "arg"


def test_resolve_env_vars_take_precedence_over_selected_env():
    # Backward-compat: an injected MOLLOW_MEMORY_URL/KEY (forge/yolo/worker) is
    # honored before the selected-env file, so this change can't break sessions
    # that already inject creds.
    t = memory_sync.resolve_target(
        env_arg=None,
        environ={"MOLLOW_MEMORY_URL": "https://mollow.ai/mcp/v2", "MOLLOW_MEMORY_API_KEY": "mol_prod"},
        selected_env="staging",
        keyfile=KEYFILE,
    )
    assert t["url"] == "https://mollow.ai/mcp/v2"
    assert t["key"] == "mol_prod"
    assert t["source"] == "env"
    assert t["env"] == "prod"  # inferred from the URL


def test_resolve_falls_back_to_selected_env():
    t = memory_sync.resolve_target(
        env_arg=None,
        environ={},
        selected_env="staging",
        keyfile=KEYFILE,
    )
    assert t["env"] == "staging"
    assert t["url"] == "https://staging.mollow.ai/mcp/v2"
    assert t["key"] == "mol_stg"
    assert t["source"] == "selected-env"


def test_resolve_default_is_prod():
    t = memory_sync.resolve_target(env_arg=None, environ={}, selected_env=None, keyfile=KEYFILE)
    assert t["env"] == "prod"
    assert t["source"] == "default"
    assert t["key"] == "mol_prod"


def test_resolve_infer_env_from_url_unknown_is_custom():
    t = memory_sync.resolve_target(
        env_arg=None,
        environ={"MOLLOW_MEMORY_URL": "https://mem.example.com/mcp/v2", "MOLLOW_MEMORY_API_KEY": "mol_x"},
        selected_env=None,
        keyfile=KEYFILE,
    )
    assert t["env"] == "custom"
    assert t["source"] == "env"


# ── config-disagreement detection (status) ───────────────────────────────────


def test_detect_disagreement_flags_split():
    # selected-env says staging, but the injected env + MCP config say prod.
    d = memory_sync.detect_disagreement(
        selected_env="staging",
        env_var_url="https://mollow.ai/mcp/v2",
        mcp_config_url="https://mollow.ai/mcp/v2",
    )
    assert d["agree"] is False
    assert set(d["envs"]) == {"staging", "prod"}


def test_detect_disagreement_all_aligned():
    d = memory_sync.detect_disagreement(
        selected_env="prod",
        env_var_url="https://mollow.ai/mcp/v2",
        mcp_config_url="https://mollow.ai/mcp/v2",
    )
    assert d["agree"] is True
    assert d["envs"] == ["prod"]


def test_detect_disagreement_ignores_unset_sources():
    # Only one source known → trivially in agreement (nothing to contradict).
    d = memory_sync.detect_disagreement(selected_env="prod", env_var_url=None, mcp_config_url=None)
    assert d["agree"] is True
    assert d["envs"] == ["prod"]


# ── call-time config resolution (no import-time env capture) ─────────────────


def test_read_keyfile_resolves_env_at_call_time(tmp_path, monkeypatch):
    # MOLLOW_KEYFILE set AFTER import must still be honored — the path is
    # resolved per call, not captured at import (security review CR-S-r1-002).
    kf = tmp_path / "mol-keys.env"
    kf.write_text("MOL_KEY_PROD=mol_fromenv\n")
    monkeypatch.setenv("MOLLOW_KEYFILE", str(kf))
    assert memory_sync.read_keyfile()["prod"] == "mol_fromenv"


def test_read_keyfile_missing_file_is_empty(monkeypatch):
    monkeypatch.setenv("MOLLOW_KEYFILE", "/no/such/keyfile.env")
    assert memory_sync.read_keyfile() == {}
