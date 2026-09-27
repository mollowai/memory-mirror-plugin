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


# ── repo routing: which scopes may carry a `repo`, and which must not ─────────
#
# `repo` is the destination map's key (`memory_destinations` is keyed
# `(user_id, repo)`). An entry without it imports fine and lands in the PRIVATE
# workspace — indistinguishable, from the caller's side, from one that routed
# correctly. `push` never passed it, so every entry this documented command sent
# (`README.md`: `memory_sync.py --all push --repair`) silently missed its Space.
#
# The fix is NOT "always pass a repo". `--repo` is stamped on EVERY extracted
# entry (extract-local-memories.py:361-363), while `--all` spans EVERY project
# under the root (:305) and `--dir` names a memory dir whose slug is lossy and
# cannot be inverted to a project. Stamping this repo across either scope would
# route ANOTHER project's memories into this repo's shared, undeletable Space —
# strictly worse than the private-workspace landing it would be fixing
# (Greptile #5333). So only a single-project scope may carry one.


def test_scope_carries_repo_only_for_a_single_project():
    # The one scope with exactly one answer: an explicit project, or cwd.
    assert memory_sync.scope_carries_repo(all_projects=False, dir_path=None) is True


def test_scope_refuses_repo_for_all_projects():
    # `--all` is every project under the root; one --repo would stamp them all.
    assert memory_sync.scope_carries_repo(all_projects=True, dir_path=None) is False


def test_scope_refuses_repo_for_an_explicit_memory_dir():
    # `--dir` names a MEMORY dir. The slug is lossy (`/` and `.` both become
    # `-`), so it cannot be inverted to say which project owns it.
    assert memory_sync.scope_carries_repo(all_projects=False, dir_path="/some/memory") is False


def test_scope_refuses_repo_for_dir_even_with_all():
    # --dir overrides --all in extract_entries; the refusal must not depend on
    # which branch wins.
    assert memory_sync.scope_carries_repo(all_projects=True, dir_path="/some/memory") is False


def _argv_of(monkeypatch, **kwargs):
    """Capture the argv extract_entries hands the frozen extractor."""
    seen = {}

    class _Done:
        stdout = "[]"

    def fake_run(cmd, **_kw):
        seen["cmd"] = cmd
        return _Done()

    monkeypatch.setattr(memory_sync.subprocess, "run", fake_run)
    memory_sync.extract_entries(**kwargs)
    return seen["cmd"]


def test_extract_entries_passes_repo_through_to_the_extractor(monkeypatch):
    # THE defect: without this the entry carries no `repo` and lands private.
    argv = _argv_of(monkeypatch, project="/repo/checkout", repo="github.com/mollowai/monorepo")
    assert "--repo" in argv
    assert argv[argv.index("--repo") + 1] == "github.com/mollowai/monorepo"


def test_extract_entries_omits_repo_when_none(monkeypatch):
    # Omitted rather than sent empty — an empty `--repo` is a route key that
    # matches nothing, and parity with the Elixir golden test depends on the
    # field being ABSENT, not blank.
    #
    # NOTE this one is an over-correction guard, not a bug detector: once `repo`
    # is a parameter at all, omitting it is already the behaviour. It exists so a
    # later "always stamp a repo" cannot land quietly.
    argv = _argv_of(monkeypatch, project="/repo/checkout", repo=None)
    assert "--repo" not in argv


# ── import retry: a gateway timeout is not a verdict on the write ─────────────
#
# Measured 2026-09-27 (MOL-6187, and MOL-6165 before it): POST /api/memory/import
# with 48 entries / 163 KB returned HTTP 524 at 125 s, and a re-post of the
# identical payload came back {"error":0,"ok":48,"deduped":43}. So a 5xx gateway
# status says the proxy gave up waiting, not that nothing landed.
#
# In that instance the 43 were strong evidence the timed-out call had committed,
# because the entries were freshly built and known-new. In general they are not:
# `deduped` only says the content hash is already stored, which an earlier sync
# could equally explain. So the rule is "re-post to establish PRESENCE", not
# "read `deduped` to learn which attempt committed".
#
# `post_import` did the opposite: it raised on any non-200, which both reported a
# committed write as a failure AND discarded the counts of every chunk that had
# already succeeded.


class _FakeCurl:
    """Scripted _curl replacement. `plan` is a list of (status, body) or an
    Exception to raise, consumed one per call."""

    def __init__(self, plan):
        self.plan = list(plan)
        self.calls = []

    def __call__(self, method, url, key, body=None, timeout=30):
        self.calls.append({"method": method, "url": url, "body": body, "timeout": timeout})
        step = self.plan.pop(0)
        if isinstance(step, Exception):
            raise step
        return step


def _count(ok=0, deduped=0, error=0):
    return json.dumps({"count": {"ok": ok, "deduped": deduped, "error": error}})


def test_post_import_reposts_once_on_a_gateway_timeout(monkeypatch):
    # 524 then 200 — the re-post's counts are the ones that must be reported,
    # because they describe the state that actually holds.
    #
    # NOT because `deduped` proves the first call committed: the hash could have
    # been present from an earlier sync entirely, so `deduped` conflates the two.
    # What the re-post establishes is PRESENCE NOW, which is what the sync needs
    # (Greptile on #6389 caught the stronger claim).
    fake = _FakeCurl([(524, "<html>timeout</html>"), (200, _count(ok=48, deduped=43))])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c"}])
    assert len(fake.calls) == 2, "a 524 must be re-posted, not raised"
    assert agg["ok"] == 48
    assert agg["deduped"] == 43
    assert agg["error"] == 0


def test_post_import_reposts_once_on_a_transport_timeout(monkeypatch):
    # curl blowing --max-time raises RuntimeError from _curl. Same situation as a
    # 524: the client stopped waiting, the server may well have committed.
    fake = _FakeCurl([RuntimeError("curl failed (28): timed out"), (200, _count(ok=5, deduped=5))])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c"}])
    assert len(fake.calls) == 2
    assert agg["deduped"] == 5


def test_post_import_does_not_retry_a_client_error(monkeypatch):
    # 400 is a real defect in what we sent (e.g. the bare-array-vs-{"entries"}
    # shape). Re-posting it just sends the same broken body twice and buries the
    # message the caller needs.
    fake = _FakeCurl([(400, '{"error":"entries is required"}')])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    with pytest.raises(RuntimeError, match="400"):
        memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c"}])
    assert len(fake.calls) == 1, "a 4xx must not be re-posted"


def test_post_import_raises_when_the_repost_also_fails(monkeypatch):
    # Two gateway failures in a row: the fate is genuinely unknown, and saying so
    # is the honest outcome. Silently returning zeroes would let a caller --stamp
    # over memories that never landed.
    fake = _FakeCurl([(524, "t"), (524, "t")])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    with pytest.raises(RuntimeError, match="524"):
        memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c"}])
    assert len(fake.calls) == 2, "exactly one re-post, not an unbounded retry loop"


def test_post_import_keeps_counts_from_chunks_that_already_succeeded(monkeypatch):
    # The old code raised mid-loop, throwing away the first chunk's confirmed
    # counts along with it. Aggregate across chunks must survive a later retry.
    entries = [{"content": f"c{i}"} for i in range(memory_sync.IMPORT_CHUNK + 1)]
    fake = _FakeCurl([(200, _count(ok=100)), (524, "t"), (200, _count(ok=1, deduped=1))])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", entries)
    assert agg["ok"] == 101
    assert agg["deduped"] == 1


# ── the export read path cannot see a Space (Greptile P1 on #6389) ────────────
#
# `GET /api/memory/export` is WORKSPACE-scoped: `memory_export_controller.ex:174-178`
# filters `where: c.workspace_id == ^workspace_id` through the channel join, and its
# own docstring at `:12` says "every Etch message in the workspace".
#
# Before repo routing, `push` sent everything to the private workspace and `verify`
# read that same workspace — consistent, if wrong. Adding routing made the two
# disagree: a routed entry lands in a Space channel the export cannot return, so
# `verify` reports it MISSING forever and `--repair` re-sends it on every run.
#
# So a routed scope must not be verified through this endpoint at all. Reporting
# "N missing" that is an artefact of the reader is worse than reporting nothing —
# and `--repair` ACTS on that diff, which is what makes it a refusal rather than a
# warning.


def test_export_cannot_observe_a_routed_scope():
    assert memory_sync.export_can_observe(repo=None) is True
    assert memory_sync.export_can_observe(repo="github.com/mollowai/monorepo") is False


def test_verify_refuses_a_routed_scope_rather_than_reporting_false_missing(monkeypatch, capsys):
    """The dangerous outcome is not an error, it is a confident wrong number."""
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "repo_for_args", lambda _a: ("github.com/mollowai/monorepo", "resolved"))
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: [{"content": "c", "name": "n"}])

    def explode(*_a, **_k):  # pragma: no cover - must never be reached
        raise AssertionError("must not fetch a workspace export for a routed scope")

    monkeypatch.setattr(memory_sync, "fetch_export", explode)

    args = memory_sync.build_parser().parse_args(["--project", "/repo", "verify"])
    rc = memory_sync.cmd_verify(args)
    err = capsys.readouterr().err
    assert rc == 3, "a scope this instrument cannot read is neither pass (0) nor missing (1)"
    assert "workspace-scoped" in err.lower()


def test_repair_refuses_a_routed_scope_rather_than_re_sending_forever(monkeypatch, capsys):
    """--repair ACTS on the diff, so a false "missing" makes it re-push every run."""
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "repo_for_args", lambda _a: ("github.com/mollowai/monorepo", "resolved"))
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: [{"content": "c", "name": "n"}])

    def explode(*_a, **_k):  # pragma: no cover
        raise AssertionError("must not diff a routed scope against a workspace export")

    monkeypatch.setattr(memory_sync, "fetch_export", explode)
    monkeypatch.setattr(memory_sync, "post_import", explode)

    args = memory_sync.build_parser().parse_args(["--project", "/repo", "push", "--repair"])
    rc = memory_sync.cmd_push(args)
    err = capsys.readouterr().err
    assert rc == 3
    assert "workspace-scoped" in err.lower()


def test_an_unrouted_push_still_repairs(monkeypatch, capsys):
    """The refusal must be narrow. An unrouted scope lands in the private
    workspace, which is exactly what the export reads — so --repair is sound
    there and must keep working."""
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "repo_for_args", lambda _a: (None, "unresolved — --all spans every project"))
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: [{"content": "c", "name": "n"}])
    monkeypatch.setattr(memory_sync, "fetch_export", lambda *_a, **_k: '{"type":"memory","content":"other"}')
    sent = {}

    def fake_post(_base, _key, entries, **_kw):
        sent["n"] = len(entries)
        return {"ok": 1, "deduped": 0, "error": 0, "reposted": 0}

    monkeypatch.setattr(memory_sync, "post_import", fake_post)

    args = memory_sync.build_parser().parse_args(["--all", "push", "--repair"])
    rc = memory_sync.cmd_push(args)
    assert rc == 0
    assert sent["n"] == 1, "the one locally-present, remotely-absent entry must still be pushed"


# ── the read-back hash the docs promise must actually be obtainable ───────────
#
# Greptile P1, round 5: both docs tell an operator to confirm a routed entry with
# `verify_stored_memory` on "a message_hash the import returned" — but post_import
# read only `count` and threw the per-entry `results` away, so there was no hash to
# pass. A check an operator cannot perform is not a check.
#
# The hashes are there: handle_import_claude_memories returns
# `%{results: results, count: tally(results)}` (memory_tools.ex:1262+) and each
# result carries `message_hash` (`:206`, `:264`, `:342`). For a ROUTED push they are
# the only read-back that exists, because the export cannot see a Space.


def _count_with_results(entries, ok=1, deduped=0, error=0):
    return json.dumps(
        {
            "count": {"ok": ok, "deduped": deduped, "error": error},
            "results": [
                {"ok": True, "name": e["name"], "message_hash": f"h_{e['name']}", "deduped": False} for e in entries
            ],
        }
    )


def test_post_import_keeps_the_per_entry_hashes(monkeypatch):
    entries = [{"content": "c1", "name": "a"}, {"content": "c2", "name": "b"}]
    fake = _FakeCurl([(200, _count_with_results(entries, ok=2))])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", entries)
    assert [h["message_hash"] for h in agg["hashes"]] == ["h_a", "h_b"]
    assert [h["name"] for h in agg["hashes"]] == ["a", "b"]


def test_post_import_keeps_hashes_for_deduped_entries_too(monkeypatch):
    """A DEDUPED entry carries a hash and must not be filtered out.

    Both server dedup paths return one — `finalize_import_insert/3` at
    memory_tools.ex:1874 and `deduped_result/2` at :1790, each
    `%{message_hash: …, deduped: true}`. This is the common case, not an edge one: on
    any re-sync most entries dedupe, and for a ROUTED project those hashes are the
    only read-back there is. Dropping them would leave a re-synced corpus
    unverifiable while the counts looked fine.
    """
    entries = [{"content": "c1", "name": "fresh"}, {"content": "c2", "name": "already"}]
    body = json.dumps(
        {
            "count": {"ok": 2, "deduped": 1, "error": 0},
            "results": [
                {"ok": True, "name": "fresh", "message_hash": "h_fresh", "deduped": False},
                {"ok": True, "name": "already", "message_hash": "h_already", "deduped": True},
            ],
        }
    )
    fake = _FakeCurl([(200, body)])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", entries)
    assert [h["message_hash"] for h in agg["hashes"]] == ["h_fresh", "h_already"]
    assert [h["deduped"] for h in agg["hashes"]] == [False, True], "the deduped flag must survive"


def test_post_import_drops_a_result_with_no_hash(monkeypatch):
    """A failed entry has no hash to record; recording a None would put an
    unusable row in the file operators are told to read."""
    body = json.dumps(
        {
            "count": {"ok": 1, "deduped": 0, "error": 1},
            "results": [
                {"ok": True, "name": "good", "message_hash": "h_good", "deduped": False},
                {"ok": False, "name": "bad", "error": "changeset invalid"},
            ],
        }
    )
    fake = _FakeCurl([(200, body)])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c", "name": "good"}])
    assert [h["name"] for h in agg["hashes"]] == ["good"]


def test_post_import_tolerates_a_response_with_no_results(monkeypatch):
    """The endpoint's `results` key is what this reads; a body without it must not
    crash the push, only leave `hashes` empty."""
    fake = _FakeCurl([(200, _count(ok=1))])
    monkeypatch.setattr(memory_sync, "_curl", fake)
    agg = memory_sync.post_import("https://mollow.ai", "mol_k", [{"content": "c", "name": "a"}])
    assert agg["hashes"] == []
    assert agg["ok"] == 1


def test_push_writes_the_hashes_and_says_where(monkeypatch, capsys, tmp_path):
    """A routed push's hashes are the ONLY read-back available, so the path has to
    reach the operator — printing 1,100 hashes to stdout would not."""
    entries = [{"content": "c", "name": "a"}]
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "repo_for_args", lambda _a: ("github.com/mollowai/monorepo", "resolved"))
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: entries)
    monkeypatch.setattr(memory_sync, "HASHES_PATH", tmp_path / "import-hashes.json")
    monkeypatch.setattr(
        memory_sync,
        "post_import",
        lambda *_a, **_k: {
            "ok": 1,
            "deduped": 0,
            "error": 0,
            "reposted": 0,
            "hashes": [{"name": "a", "message_hash": "h_a", "deduped": False}],
        },
    )

    args = memory_sync.build_parser().parse_args(["--project", "/repo", "push"])
    rc = memory_sync.cmd_push(args)
    out = capsys.readouterr().out
    assert rc == 0
    written = json.loads((tmp_path / "import-hashes.json").read_text())
    assert written[0]["message_hash"] == "h_a"
    assert str(tmp_path / "import-hashes.json") in out, "the path must be printed, not just written"
    assert "verify_stored_memory" in out, "name the tool the hashes are for"


def test_repair_states_the_precondition_it_cannot_check(monkeypatch, capsys):
    """Greptile P1, round 4, and the bottom of the problem: `--repair` can create
    PRIVATE DUPLICATES.

    If a project's memories already live in a Space, the workspace-scoped export
    does not return them, so they read as missing — and repairing that "absence"
    imports fresh copies with no `repo`, landing a second, private copy beside the
    Space one. It repairs a phantom.

    The tool cannot detect this. `--dir` (the only scope repair accepts) names a
    memory directory whose slug is not invertible, so it cannot ask whether that
    project routes; and the destination map is not exposed to clients anyway. The
    operator knows and the tool does not — so the tool must SAY the precondition
    rather than imply it holds."""
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: [{"content": "c", "name": "n"}])
    monkeypatch.setattr(memory_sync, "fetch_export", lambda *_a, **_k: "")
    monkeypatch.setattr(
        memory_sync, "post_import", lambda *_a, **_k: {"ok": 1, "deduped": 0, "error": 0, "reposted": 0}
    )

    args = memory_sync.build_parser().parse_args(["--dir", "/some/memory", "push", "--repair"])
    memory_sync.cmd_push(args)
    err = capsys.readouterr().err
    assert "duplicate" in err.lower(), "repair must name the private-duplicate risk it cannot rule out"
    assert "space" in err.lower()


def test_a_plain_push_does_not_warn_about_duplicates(monkeypatch, capsys):
    """Narrowness: only --repair invents an absence to act on. A plain push sends
    what is there and a warning would be noise."""
    monkeypatch.setattr(memory_sync, "read_selected_env", lambda: None)
    monkeypatch.setattr(memory_sync, "read_keyfile", lambda: {"prod": "mol_k"})
    monkeypatch.setattr(memory_sync, "extract_entries", lambda **_kw: [{"content": "c", "name": "n"}])
    monkeypatch.setattr(
        memory_sync, "post_import", lambda *_a, **_k: {"ok": 1, "deduped": 0, "error": 0, "reposted": 0}
    )

    args = memory_sync.build_parser().parse_args(["--dir", "/some/memory", "push"])
    memory_sync.cmd_push(args)
    assert "duplicate" not in capsys.readouterr().err.lower()


def test_every_documented_repair_uses_the_one_sound_scope():
    """Two Greptile P1s on #6389, one after the other, both from documenting
    `--repair` with the wrong scope. Exactly one scope is sound:

    - `--project` routes, so the workspace export cannot see it — exits 3.
    - `--all` spans every project, so it uploads memories the user never approved
      (the deliberately-local `financials` corpus in step 3) — a scope defect.
    - `--dir` names ONE project's memory dir and does not route, so the export
      reads exactly where the entries land — correct.

    Reads the RENDERED doc text, because that is what an operator follows. Nothing
    else in this suite reads the docs, and both defects were doc-only."""
    root = Path(__file__).resolve().parents[1]
    offenders = []
    for doc in (root / "README.md", root / "skills/verify/SKILL.md"):
        lines = doc.read_text().splitlines()
        # Reassemble shell invocations: a line holding `memory_sync.py` plus any
        # lines it continues onto via a trailing backslash. Anything else is prose,
        # which is free to DISCUSS --repair and its unsound pairings — an earlier
        # version of this test joined by proximity instead and flagged the very
        # sentences explaining the rule.
        n = 0
        while n < len(lines):
            if "memory_sync.py" not in lines[n]:
                n += 1
                continue
            start, block = n + 1, lines[n]
            while block.rstrip().endswith("\\") and n + 1 < len(lines):
                n += 1
                block = block.rstrip().rstrip("\\") + " " + lines[n]
            if "--repair" in block and "--dir" not in block:
                why = "exits 3 (routed scope)" if "--project" in block else "uploads every project"
                offenders.append(f"{doc.name}:{start}: {why} — {' '.join(block.split())}")
            n += 1
    assert not offenders, "documented repair uses an unsound scope:\n" + "\n".join(offenders)


def test_post_import_timeout_exceeds_the_measured_import_duration():
    # A 30s default against a measured 125s import guaranteed a timeout on every
    # full chunk. Pinned so it cannot regress to a value the server cannot meet.
    import inspect

    default = inspect.signature(memory_sync.post_import).parameters["timeout"].default
    assert default >= 300, f"import timeout {default}s is below the measured 125s+ import"
