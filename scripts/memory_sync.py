#!/usr/bin/env python3
"""memory-sync — verify / status / push local Claude Code memories against Mollow.

The file-based Claude Code memories (`~/.claude/projects/<slug>/memory/*.md`)
and a Mollow instance are two stores. The SessionStart hook pushes local → cloud
but records success on HTTP 200, not on confirmed remote presence — so a partial
import can look "synced" while entries are missing (observed: 22/208 silently
absent from prod despite a matching fingerprint). This tool closes that gap with
a first-class, read-only verify plus an idempotent push, parameterized by
environment so anyone can run the same checks.

Subcommands:
    status   Show, for the resolved target: config agreement across the three
             sources of truth (selected-env / injected env / .claude.json MCP),
             the remote memory count, and the local entry count.
    verify   READ-ONLY. Extract local entries, pull GET /api/memory/export, and
             diff by content. Reports N local / M present / K missing (+ names).
             Exit 1 if anything is missing — hook/CI usable.
    push     Import local entries via POST /api/memory/import (server dedups).
             `--repair` pushes only the entries verify found missing.

Target resolution precedence (single source of truth, mirrors fleet-target):
    --env <dev|staging|prod>                         (explicit)
  > $MOLLOW_MEMORY_URL + $MOLLOW_MEMORY_API_KEY      (injected: forge/yolo/worker)
  > ~/.mollow/selected-env + ~/.mollow/secrets/mol-keys.env
  > prod (default)

Dependency-free (stdlib only), like extract-local-memories.py. The env→URL map
and keyfile format are a contract shared with scripts/fleet-target.sh.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

# ── Contract shared with scripts/fleet-target.sh (ft_env_to_base_url) ─────────
ENV_BASE_URLS = {
    "dev": "http://localhost:4000",
    "staging": "https://staging.mollow.ai",
    "prod": "https://mollow.ai",
}
DEFAULT_ENV = "prod"

# The selected-env / keyfile paths are resolved at call time (see
# _selected_env_path / _keyfile_path), not captured here at import, so setting
# the env var after import — or in a test — still takes effect.
CLAUDE_JSON = Path("~/.claude.json").expanduser()
IMPORT_CHUNK = 100  # server caps a batch at 100.

_EXTRACT = Path(__file__).with_name("extract-local-memories.py")


# ═══════════════════════════════════════════════════════════════════════════
# Pure helpers (unit-tested in test_memory_sync.py)
# ═══════════════════════════════════════════════════════════════════════════


def env_to_url(env):
    """dev|staging|prod → the memory MCP URL. Raises ValueError on unknown."""
    try:
        return ENV_BASE_URLS[env] + "/mcp/v2"
    except KeyError:
        raise ValueError(f"unknown env {env!r} (expected one of {sorted(ENV_BASE_URLS)})") from None


def api_base(url):
    """Strip the load-bearing /mcp/v2 suffix (and an optional trailing slash) to
    get the REST API base — mirrors _common.sh mm_api_base."""
    url = url.rstrip("/")
    if url.endswith("/mcp/v2"):
        url = url[: -len("/mcp/v2")]
    return url


_LOCALHOST_HTTP = re.compile(r"^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/mcp/v2$")


def url_send_ok(url):
    """True when it's safe to send a mol_* key to this URL — mirrors the
    _common.sh mm_ready guard: must end in /mcp/v2, and must be HTTPS unless it
    is loopback http (dev only)."""
    url = url.rstrip("/")
    if not url.endswith("/mcp/v2"):
        return False
    if url.startswith("https://"):
        return True
    return bool(_LOCALHOST_HTTP.match(url))


def parse_keyfile(text):
    """Parse mol-keys.env → {env: key}. Lines look like `MOL_KEY_PROD=mol_…`,
    tolerating a leading `export ` and single/double quotes. Last one wins."""
    out = {}
    for line in text.splitlines():
        m = re.match(r"^\s*(?:export\s+)?MOL_KEY_([A-Za-z]+)\s*=\s*(.*)$", line)
        if not m:
            continue
        env = m.group(1).lower()
        val = m.group(2).strip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
            val = val[1:-1]
        out[env] = val
    return out


def parse_export_memory_contents(ndjson_text):
    """From a GET /api/memory/export NDJSON body, return the set of `content`
    strings for saved memories (rows with type=="memory"). Transcript
    messages/sessions are ignored. Blank/malformed lines are skipped."""
    contents = set()
    for line in ndjson_text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if isinstance(obj, dict) and obj.get("type") == "memory":
            content = obj.get("content")
            if content is not None:
                contents.add(content)
    return contents


def diff_entries(local_entries, remote_contents):
    """Diff local extracted entries against the set of remote memory contents.
    Match is exact content-string equality (import stores `content` verbatim and
    dedups on its hash, so equal content ⇒ present)."""
    missing = [
        {"name": e.get("name"), "content": e.get("content")}
        for e in local_entries
        if e.get("content") not in remote_contents
    ]
    local_count = len(local_entries)
    return {
        "local_count": local_count,
        "missing": missing,
        "missing_count": len(missing),
        "present_count": local_count - len(missing),
    }


def infer_env_from_url(url):
    """Map a memory URL back to an env name, or 'custom' if unrecognized."""
    if not url:
        return None
    base = api_base(url)
    for env, env_base in ENV_BASE_URLS.items():
        if base == env_base:
            return env
    return "custom"


def resolve_target(env_arg, environ, selected_env, keyfile):
    """Resolve which (env, url, key) to act against, by precedence. Returns a
    dict {env, url, base, key, source}. `key` may be None if unresolved."""
    if env_arg:
        url = env_to_url(env_arg)
        return {
            "env": env_arg,
            "url": url,
            "base": api_base(url),
            "key": keyfile.get(env_arg),
            "source": "arg",
        }

    env_url = environ.get("MOLLOW_MEMORY_URL")
    env_key = environ.get("MOLLOW_MEMORY_API_KEY")
    if env_url and env_key:
        return {
            "env": infer_env_from_url(env_url),
            "url": env_url,
            "base": api_base(env_url),
            "key": env_key,
            "source": "env",
        }

    if selected_env:
        url = env_to_url(selected_env)
        return {
            "env": selected_env,
            "url": url,
            "base": api_base(url),
            "key": keyfile.get(selected_env),
            "source": "selected-env",
        }

    url = env_to_url(DEFAULT_ENV)
    return {
        "env": DEFAULT_ENV,
        "url": url,
        "base": api_base(url),
        "key": keyfile.get(DEFAULT_ENV),
        "source": "default",
    }


def detect_disagreement(selected_env, env_var_url, mcp_config_url):
    """Do the three config sources point at the same env? Returns
    {agree, envs, sources} where `envs` is the distinct set of known targets."""
    sources = {
        "selected-env": selected_env,
        "env-var": infer_env_from_url(env_var_url),
        "mcp-config": infer_env_from_url(mcp_config_url),
    }
    envs = []
    for env in sources.values():
        if env and env not in envs:
            envs.append(env)
    return {"agree": len(envs) <= 1, "envs": envs, "sources": sources}


# ═══════════════════════════════════════════════════════════════════════════
# I/O — extraction, config reads, network
# ═══════════════════════════════════════════════════════════════════════════


def _selected_env_path():
    return Path(os.environ.get("MOLLOW_SELECTED_ENV_FILE", "~/.mollow/selected-env")).expanduser()


def _keyfile_path():
    return Path(os.environ.get("MOLLOW_KEYFILE", "~/.mollow/secrets/mol-keys.env")).expanduser()


def read_selected_env():
    try:
        val = _selected_env_path().read_text(encoding="utf-8").strip()
        return val or None
    except OSError:
        return None


def read_keyfile(path=None):
    path = Path(path) if path else _keyfile_path()
    try:
        return parse_keyfile(path.read_text(encoding="utf-8"))
    except OSError:
        return {}


def read_mcp_config_url():
    """Best-effort: the mollow-memory MCP server URL from ~/.claude.json."""
    try:
        data = json.loads(CLAUDE_JSON.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return _find_mollow_memory_url(data)


def _find_mollow_memory_url(node):
    if isinstance(node, dict):
        server = node.get("mollow-memory")
        if isinstance(server, dict) and isinstance(server.get("url"), str):
            return server["url"]
        for value in node.values():
            found = _find_mollow_memory_url(value)
            if found:
                return found
    elif isinstance(node, list):
        for value in node:
            found = _find_mollow_memory_url(value)
            if found:
                return found
    return None


def extract_entries(project=None, all_projects=False, skip_ephemeral=False, dir_path=None):
    """Shell out to the frozen extractor so the byte contract is identical to
    the hook's import path."""
    cmd = [sys.executable, str(_EXTRACT)]
    if dir_path:
        cmd += ["--dir", dir_path]
    elif all_projects:
        cmd.append("--all")
    elif project:
        cmd += ["--project", project]
    if skip_ephemeral:
        cmd.append("--skip-ephemeral")
    out = subprocess.run(cmd, capture_output=True, text=True, check=True).stdout
    return json.loads(out or "[]")


# Network goes through `curl`, not urllib: prod's Cloudflare edge 403s the
# `Python-urllib` User-Agent but allowlists curl (the same client the hooks
# use). Body + bearer key are passed via stdin/args curl reads, never printed.
def _curl(method, url, key, body=None, timeout=30):
    """Return (http_status:int, body:str). Raises RuntimeError on transport
    failure (curl non-zero exit: DNS, TLS, timeout)."""
    # The bearer key goes to curl via a 0600 temp header file (-H @file), never
    # as a CLI arg: an argv token is visible in `ps` / `/proc/PID/cmdline` to any
    # local user — a real exposure on shared-PID cloud workers. mkstemp creates
    # the file 0600; it is unlinked immediately after the request.
    fd, hdr_path = tempfile.mkstemp(suffix=".hdr")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(f"Authorization: Bearer {key}\n")
        cmd = [
            "curl",
            "-sS",
            "--max-time",
            str(timeout),
            "-X",
            method,
            url,
            "-H",
            f"@{hdr_path}",
            "-w",
            "\n%{http_code}",
        ]
        stdin = None
        if body is not None:
            cmd += ["-H", "Content-Type: application/json", "--data-binary", "@-"]
            stdin = json.dumps(body)
        proc = subprocess.run(cmd, input=stdin, capture_output=True, text=True)
    finally:
        Path(hdr_path).unlink()
    if proc.returncode != 0:
        raise RuntimeError(f"curl failed ({proc.returncode}): {proc.stderr.strip()}")
    out = proc.stdout
    nl = out.rfind("\n")
    status = int(out[nl + 1 :].strip() or 0)
    return status, out[:nl]


def fetch_export(base, key, timeout=120):
    status, body = _curl("GET", base + "/api/memory/export", key, timeout=timeout)
    if status != 200:
        raise RuntimeError(f"export HTTP {status} from {base}")
    return body


def fetch_stats(base, key, timeout=30):
    try:
        status, body = _curl("GET", base + "/api/memory/migration/stats", key, timeout=timeout)
        return json.loads(body) if status == 200 else None
    except (RuntimeError, ValueError):
        return None


def post_import(base, key, entries, timeout=30):
    """POST entries in chunks. Returns aggregate {ok, deduped, error}."""
    agg = {"ok": 0, "deduped": 0, "error": 0}
    for i in range(0, len(entries), IMPORT_CHUNK):
        chunk = entries[i : i + IMPORT_CHUNK]
        status, body = _curl("POST", base + "/api/memory/import", key, {"entries": chunk}, timeout)
        if status != 200:
            raise RuntimeError(f"import HTTP {status} from {base}")
        count = json.loads(body).get("count", {})
        for k in agg:
            agg[k] += count.get(k, 0)
    return agg


# ═══════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════


def _guard(target):
    if not target["key"]:
        sys.stderr.write(f"memory-sync: no key for env '{target['env']}' (source: {target['source']}).\n")
        sys.stderr.write(f"  Add it to {_keyfile_path()} as MOL_KEY_{(target['env'] or '').upper()}=mol_…\n")
        return False
    if not url_send_ok(target["url"]):
        sys.stderr.write(f"memory-sync: refusing to send key to {target['url']} (not HTTPS or missing /mcp/v2).\n")
        return False
    return True


def cmd_status(args):
    selected = read_selected_env()
    env_var_url = os.environ.get("MOLLOW_MEMORY_URL")
    mcp_url = read_mcp_config_url()
    dis = detect_disagreement(selected, env_var_url, mcp_url)
    target = resolve_target(args.env, os.environ, selected, read_keyfile())

    print("memory-sync status")
    print(f"  target env   : {target['env']}  (via {target['source']})  {target['url']}")
    print("  config sources:")
    print(f"    selected-env : {selected or '(unset)'}")
    print(f"    env-var      : {infer_env_from_url(env_var_url) or '(unset)'}  {env_var_url or ''}")
    print(f"    mcp-config   : {infer_env_from_url(mcp_url) or '(unset)'}  {mcp_url or ''}")
    if dis["agree"]:
        print(f"  config       : ✓ aligned on {dis['envs'][0] if dis['envs'] else '(none)'}")
    else:
        print(f"  config       : ✗ DISAGREEMENT across {', '.join(dis['envs'])} — run fleet-target to reconcile")

    entries = extract_entries(
        project=args.project, all_projects=args.all, skip_ephemeral=args.skip_ephemeral, dir_path=args.dir
    )
    print(f"  local entries: {len(entries)}")
    if _guard(target):
        stats = fetch_stats(target["base"], target["key"])
        if stats:
            print(f"  remote stats : {json.dumps(stats.get('stats', stats))}")
        else:
            print("  remote stats : (unavailable)")
    return 0 if dis["agree"] else 3


def cmd_verify(args):
    selected = read_selected_env()
    target = resolve_target(args.env, os.environ, selected, read_keyfile())
    if not _guard(target):
        return 2
    entries = extract_entries(
        project=args.project, all_projects=args.all, skip_ephemeral=args.skip_ephemeral, dir_path=args.dir
    )
    try:
        export = fetch_export(target["base"], target["key"])
    except RuntimeError as exc:
        sys.stderr.write(f"memory-sync: export failed against {target['base']}: {exc}\n")
        return 2
    remote = parse_export_memory_contents(export)
    d = diff_entries(entries, remote)

    if args.json:
        print(json.dumps({"env": target["env"], "url": target["url"], **d}))
    else:
        print(f"verify against {target['env']} ({target['url']})")
        print(f"  local: {d['local_count']}   present: {d['present_count']}   missing: {d['missing_count']}")
        for m in d["missing"][:50]:
            print(f"    MISSING  {m['name']}")
        if d["missing_count"] > 50:
            print(f"    … and {d['missing_count'] - 50} more")
    return 0 if d["missing_count"] == 0 else 1


def cmd_push(args):
    selected = read_selected_env()
    target = resolve_target(args.env, os.environ, selected, read_keyfile())
    if not _guard(target):
        return 2
    entries = extract_entries(
        project=args.project, all_projects=args.all, skip_ephemeral=args.skip_ephemeral, dir_path=args.dir
    )

    try:
        if args.repair:
            export = fetch_export(target["base"], target["key"])
            remote = parse_export_memory_contents(export)
            entries = diff_entries_missing_entries(entries, remote)
            noun = "entry" if len(entries) == 1 else "entries"
            print(f"repair: {len(entries)} missing {noun} to push to {target['env']}")
            if not entries:
                return 0
        agg = post_import(target["base"], target["key"], entries)
    except RuntimeError as exc:
        sys.stderr.write(f"memory-sync: push failed against {target['base']}: {exc}\n")
        return 2
    new = agg["ok"] - agg["deduped"]
    print(f"push to {target['env']} ({target['url']})")
    print(f"  sent: {len(entries)}   new: {new}   deduped: {agg['deduped']}   error: {agg['error']}")
    return 0 if agg["error"] == 0 else 1


def diff_entries_missing_entries(local_entries, remote_contents):
    """Full local entries (not just name/content) that are absent remotely."""
    return [e for e in local_entries if e.get("content") not in remote_contents]


# ═══════════════════════════════════════════════════════════════════════════
# CLI
# ═══════════════════════════════════════════════════════════════════════════


def build_parser():
    p = argparse.ArgumentParser(prog="memory-sync", description=__doc__.splitlines()[0])
    p.add_argument("--env", choices=sorted(ENV_BASE_URLS), help="Explicit target env (overrides all other sources).")
    p.add_argument("--project", help="Project root path (default: cwd).")
    p.add_argument("--dir", help="A specific memory/ directory (unambiguous; overrides --project/--all).")
    p.add_argument("--all", action="store_true", help="All projects under ~/.claude/projects.")
    p.add_argument("--skip-ephemeral", action="store_true", help="Drop host-specific facts (IPs, sockets, ports).")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="Show target, config agreement, and counts.")
    s.set_defaults(func=cmd_status)

    v = sub.add_parser("verify", help="Read-only: diff local entries vs remote export.")
    v.add_argument("--json", action="store_true", help="Emit the diff as JSON.")
    v.set_defaults(func=cmd_verify)

    u = sub.add_parser("push", help="Import local entries (idempotent).")
    u.add_argument("--repair", action="store_true", help="Push only entries verify found missing.")
    u.set_defaults(func=cmd_push)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        return args.func(args)
    except subprocess.CalledProcessError as exc:
        sys.stderr.write(f"memory-sync: extractor failed: {exc.stderr or exc}\n")
        return 2


if __name__ == "__main__":
    sys.exit(main())
