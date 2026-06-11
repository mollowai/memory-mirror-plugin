"""Tests for sync-session.sh — the Stop hook that nudges Claude to call
sync_session_context.

The hook can't observe whether the model actually synced (a bash Stop hook can't
see MCP tool calls), so the contract under test is "nudge at most once per
session": block the first natural stop, then stay quiet for the rest of the
session so it doesn't re-fire on every turn.

Each invocation runs the script as a subprocess with a crafted Stop-hook JSON on
stdin. TMPDIR is pointed at a per-test directory so the per-session marker the
hook writes is isolated and discoverable.

Run with: python -m pytest plugins/memory-mirror/hooks/test_sync_session.py
"""

import json
import subprocess
from pathlib import Path

_HOOK = Path(__file__).parent / "sync-session.sh"


def run_hook(payload: dict, state_dir: Path) -> subprocess.CompletedProcess:
    """Invoke sync-session.sh with `payload` on stdin, marker state under state_dir."""
    return subprocess.run(
        ["bash", str(_HOOK)],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        env={"TMPDIR": str(state_dir), "PATH": "/usr/bin:/bin:/usr/local/bin"},
        timeout=10,
    )


def assert_blocks(result: subprocess.CompletedProcess) -> dict:
    """The hook nudged: exit 0, stdout is a {systemMessage: ...} doc."""
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip(), "expected a nudge on stdout, got nothing"
    doc = json.loads(result.stdout)
    assert "systemMessage" in doc
    assert doc["systemMessage"].strip()
    return doc


def assert_does_not_block(result: subprocess.CompletedProcess) -> None:
    """The hook let the stop proceed: exit 0, no decision emitted."""
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "", f"expected no block, got: {result.stdout!r}"


def test_first_stop_blocks(tmp_path):
    result = run_hook({"session_id": "sess-A", "stop_hook_active": False}, tmp_path)
    doc = assert_blocks(result)
    assert "sync_session_context" in doc["systemMessage"]


def test_second_stop_same_session_does_not_block(tmp_path):
    # First natural stop nudges...
    assert_blocks(run_hook({"session_id": "sess-A", "stop_hook_active": False}, tmp_path))
    # ...the next natural stop in the SAME session must stay quiet (idempotent).
    assert_does_not_block(run_hook({"session_id": "sess-A", "stop_hook_active": False}, tmp_path))


def test_stop_hook_active_does_not_block(tmp_path):
    # Re-entrancy guard: a stop triggered by a stop hook lets the session end.
    assert_does_not_block(run_hook({"session_id": "sess-A", "stop_hook_active": True}, tmp_path))


def test_different_session_blocks_again(tmp_path):
    assert_blocks(run_hook({"session_id": "sess-A", "stop_hook_active": False}, tmp_path))
    # A different session is a fresh nudge, even sharing the state dir.
    assert_blocks(run_hook({"session_id": "sess-B", "stop_hook_active": False}, tmp_path))


def test_missing_session_id_still_nudges(tmp_path):
    # No session id → can't dedupe; degrade to the old always-nudge behavior
    # rather than going silent (better a repeat nudge than a dropped one).
    assert_blocks(run_hook({"stop_hook_active": False}, tmp_path))
    assert_blocks(run_hook({"stop_hook_active": False}, tmp_path))


def test_path_traversal_session_id_is_not_used_as_marker(tmp_path):
    # A hostile session id must not escape the marker layout. It won't match the
    # safe-charset guard, so it falls back to always-nudge (no marker written).
    payload = {"session_id": "../../etc/evil", "stop_hook_active": False}
    assert_blocks(run_hook(payload, tmp_path))
    assert_blocks(run_hook(payload, tmp_path))
