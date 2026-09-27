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
# `mm_repo_of` lives here. Shelled out to, never reimplemented — see resolve_repo.
_COMMON_SH = Path(__file__).resolve().parents[1] / "hooks/_common.sh"


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


def scope_carries_repo(all_projects=False, dir_path=None):
    """May entries from this scope be stamped with a single `repo`?

    Only a single-project scope may. `--repo` is stamped on EVERY extracted
    entry (extract-local-memories.py:361-363), so a scope covering more than one
    project has no single right answer:

    * `--all` is every project under the root (:305). One `--repo` would claim
      all of them belong to this one.
    * `--dir` names a MEMORY directory, not a project. The slug is lossy (`/`
      and `.` both become `-`) so it cannot be inverted to find the owner.

    Guessing either way routes ANOTHER project's memories into this repo's
    shared, undeletable Space — worse than the private-workspace landing it
    would be fixing (Greptile #5333, and sync.py carries the same refusal).
    Returning False leaves them unrouted, which is recoverable: a later
    single-project run re-posts them and import dedups on the content hash.
    """
    if dir_path:
        return False
    return not all_projects


def resolve_repo(project_dir):
    """Repo identity for `project_dir` — `github.com/owner/name`, or None.

    SHELLS OUT to `mm_repo_of` rather than reimplementing the rule, and that is
    the point: `repo` is the destination map's key, MOL-4691 already requires
    three producers to agree on it, and a fourth spelling here would drift
    silently. The failure it would cause — a memory routed to the private
    workspace instead of its Space — is invisible from this side.

    None is a legitimate outcome: most projects map to no Space. The caller
    reports which case it is, so "no repo could be resolved" is never mistaken
    for "resolved, and it routes nowhere".
    """
    if not _COMMON_SH.is_file():
        return None
    try:
        proc = subprocess.run(
            ["bash", "-c", 'set -e; . "$1"; mm_repo_of "$2"', "_", str(_COMMON_SH), str(project_dir)],
            capture_output=True,
            text=True,
            timeout=15,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def repo_for_args(args):
    """The `repo` to stamp for this invocation, plus why — (repo, routing).

    `routing` is REPORTED by every command, because an entry with no `repo`
    imports fine and lands in the private workspace, which from the caller's
    side is indistinguishable from a correct route. Naming the state is the only
    thing that separates "this project maps to no Space, as expected" from "the
    field was never sent, so nothing could map".
    """
    if not scope_carries_repo(all_projects=args.all, dir_path=args.dir):
        scope = "--dir names a memory dir, not a project" if args.dir else "--all spans every project"
        return None, (
            f"unresolved — {scope}, so no single `repo` can be stamped; entries land in the "
            "private workspace. Re-run per project (--project <repo-checkout>) to route them"
        )
    repo = resolve_repo(Path(args.project).expanduser() if args.project else Path.cwd())
    if repo:
        return repo, f"resolved — {repo}"
    return None, "unresolved — this project maps to no Space; entries land in the private workspace"


def extract_entries(project=None, all_projects=False, skip_ephemeral=False, dir_path=None, repo=None):
    """Shell out to the frozen extractor so the byte contract is identical to
    the hook's import path.

    `repo` is what `import-local-memories.sh` passes (hooks/import-local-memories.sh:101)
    and what `process_import_entry` routes on. Omitting it — this function's only
    behaviour until MOL-6187 — produced entries carrying just `project`, the
    directory slug, which the destination map never consults. So every entry
    `push` ever sent landed in the private workspace while reporting success.
    """
    cmd = [sys.executable, str(_EXTRACT)]
    if dir_path:
        cmd += ["--dir", dir_path]
    elif all_projects:
        cmd.append("--all")
    elif project:
        cmd += ["--project", project]
    if skip_ephemeral:
        cmd.append("--skip-ephemeral")
    # Omitted, never blank: an empty `--repo` is a route key matching nothing,
    # and entry-for-entry parity with the Elixir parser's golden test depends on
    # the field being ABSENT rather than present-and-empty.
    if repo:
        cmd += ["--repo", repo]
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


# A gateway gave up waiting. Says nothing about whether the write committed —
# measured 2026-09-27, a 524 at 125 s had fully committed (MOL-6187 / MOL-6165).
# 500 is excluded on purpose: it is the app reporting its own failure, not a
# proxy timing out, so re-posting it just repeats a request the server rejected.
_GATEWAY_TIMEOUT_STATUSES = frozenset({502, 503, 504, 524})


# Where a push records the per-entry hashes it got back. For a ROUTED push these are
# the only read-back that exists (the export cannot see a Space), so they have to
# outlive the run — and there can be ~1,100 of them, which is not stdout material.
HASHES_PATH = Path.home() / ".mollow/.memory-sync-import-hashes.json"


def _post_chunk(base, key, chunk, timeout):
    """One chunk, with exactly one re-post on a gateway/transport timeout.

    Returns (count_dict, reposted: bool). Raises RuntimeError when the fate
    cannot be established.

    Re-posting is safe because the import dedups on a frozen content hash, so a
    chunk that already landed comes back `deduped` rather than doubled. What the
    re-post establishes is that the rows ARE PRESENT NOW — which is the thing the
    sync actually needs.

    It does NOT establish which attempt put them there, and `deduped` must not be
    read that way: the hash may have been present from an EARLIER sync entirely, so
    `deduped` conflates "the timed-out call committed" with "this was already here".
    Both are fine outcomes and neither needs distinguishing; the claim to avoid is
    the stronger one (Greptile on #6389 — an earlier version of this docstring made
    exactly that error).

    Bounded at one retry: each attempt costs the full server-side import (125 s
    measured), so an unbounded loop turns one slow sync into a multi-minute stall
    per chunk.
    """
    body_obj = {"entries": chunk}
    url = base + "/api/memory/import"

    def attempt():
        status, body = _curl("POST", url, key, body_obj, timeout)
        if status == 200:
            parsed = json.loads(body)
            # `results` carries the per-entry `message_hash`
            # (handle_import_claude_memories returns `%{results:, count:}`;
            # memory_tools.ex:206/264/342). Kept, not discarded: for a routed push it
            # is the ONLY read-back, since the export cannot see a Space. `.get`
            # rather than `[]` so a body without it leaves the hashes empty instead
            # of failing the push.
            return {**parsed.get("count", {}), "_results": parsed.get("results") or []}
        return status

    try:
        first = attempt()
    except RuntimeError as exc:
        # curl could not complete (timeout, reset). Same epistemic state as a
        # 524: unknown, and knowable only by asking again.
        first = f"transport: {exc}"
    if isinstance(first, dict):
        return first, False

    # A 4xx is OURS — a malformed body, a bad key. Re-posting sends the same
    # broken request twice and buries the message that names the defect.
    if isinstance(first, int) and first not in _GATEWAY_TIMEOUT_STATUSES:
        raise RuntimeError(f"import HTTP {first} from {base}")

    try:
        second = attempt()
    except RuntimeError as exc:
        raise RuntimeError(f"import to {base} failed twice: first {first}, re-post {exc}") from exc
    if isinstance(second, dict):
        return second, True
    raise RuntimeError(
        f"import to {base} failed twice (first {first}, re-post HTTP {second}) — "
        "the write may still have committed; re-post and read `deduped` before re-syncing"
    )


def post_import(base, key, entries, timeout=900):
    """POST entries in chunks. Returns aggregate {ok, deduped, error, reposted}.

    `timeout` defaults high because the server-side import is slow: 48 entries /
    163 KB took 125 s (MOL-6187). The old 30 s default was below that for every
    full IMPORT_CHUNK, so the documented `push` timed out by construction — and
    then raised, discarding the counts of every chunk that had already landed.

    `reposted` counts chunks that needed a second attempt. It is surfaced rather
    than swallowed so a caller can see a timeout happened at all — the counts alone
    would look like an ordinary slow sync. It does not license reading `deduped` as
    proof that the timed-out attempt committed; see `_post_chunk`.
    """
    agg = {"ok": 0, "deduped": 0, "error": 0, "reposted": 0, "hashes": []}
    for i in range(0, len(entries), IMPORT_CHUNK):
        count, reposted = _post_chunk(base, key, entries[i : i + IMPORT_CHUNK], timeout)
        for k in ("ok", "deduped", "error"):
            agg[k] += count.get(k, 0)
        agg["reposted"] += 1 if reposted else 0
        for r in count.get("_results", []):
            if isinstance(r, dict) and r.get("message_hash"):
                agg["hashes"].append(
                    {"name": r.get("name"), "message_hash": r["message_hash"], "deduped": r.get("deduped")}
                )
    return agg


# ═══════════════════════════════════════════════════════════════════════════
# Commands
# ═══════════════════════════════════════════════════════════════════════════


def export_can_observe(repo):
    """Can `GET /api/memory/export` see where entries from this scope land?

    No, once they route. The export is WORKSPACE-scoped:
    `memory_export_controller.ex:174-178` filters
    `where: c.workspace_id == ^workspace_id` through the channel join, and its
    docstring at `:12` says "every Etch message in the workspace". A routed entry
    lands in a Space channel that query cannot return.

    Before repo routing existed this was consistent by accident — `push` sent
    everything to the private workspace and `verify` read that same workspace.
    Adding routing split the two, so a routed entry would read as MISSING forever
    and `--repair` would re-send it on every run (Greptile P1 on #6389).

    CONSERVATIVE, and knowingly so: a resolved `repo` means the entries CAN route,
    not that they do. `memory_destinations` is keyed `(user_id, repo)` and most
    projects have no row, so an unmapped project's entries land in the private
    workspace — where the export would in fact have seen them. This still refuses,
    because nothing on this side can tell the two apart: the destination map is not
    exposed to the client, and the import's response does not say where a row went.
    So the choice is between a false refusal and a false "N missing", and only one
    of those gets acted on by `--repair`.

    If you need the export path for such a project, widen the scope (`--all`) so
    nothing routes. Narrowing this properly needs the server to report the
    destination it chose — worth having, and not built.
    """
    return repo is None


# Exit code for "this instrument cannot answer the question you asked". Distinct
# from 1 (entries are genuinely missing) and 0 (all present), because a confident
# wrong number is the failure being avoided — not an absent one.
EXIT_UNOBSERVABLE = 3


def _refuse_unobservable(repo, what):
    sys.stderr.write(
        f"memory-sync: cannot {what} a routed scope.\n"
        f"  Entries carry repo={repo}, so they land in that project's Space, but\n"
        "  GET /api/memory/export is WORKSPACE-scoped (memory_export_controller.ex:174-178)\n"
        "  and cannot return a Space channel's messages. Diffing against it would report\n"
        "  every correctly-routed entry as missing — and --repair would re-send them on\n"
        "  every run.\n"
        "  Read-back for a routed entry needs verify_stored_memory with a message_hash the\n"
        "  import returned. To exercise this path against the private workspace instead,\n"
        "  widen the scope (--all) so nothing routes.\n"
    )


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

    repo, routing = repo_for_args(args)
    entries = extract_entries(
        project=args.project,
        all_projects=args.all,
        skip_ephemeral=args.skip_ephemeral,
        dir_path=args.dir,
        repo=repo,
    )
    print(f"  local entries: {len(entries)}")
    print(f"  routing      : {routing}")
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
    # Extract exactly as `push` does, `repo` included. The diff itself keys on
    # `content`, which `--repo` never touches (it only adds a field), so this
    # changes no verdict — but a verify that extracted differently from the push
    # it gates would be checking a payload nobody sends.
    repo, _routing = repo_for_args(args)
    if not export_can_observe(repo):
        _refuse_unobservable(repo, "verify")
        return EXIT_UNOBSERVABLE
    entries = extract_entries(
        project=args.project,
        all_projects=args.all,
        skip_ephemeral=args.skip_ephemeral,
        dir_path=args.dir,
        repo=repo,
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
    repo, routing = repo_for_args(args)
    # A plain push is fine either way — the import routes on `repo` and needs no
    # read-back. Only --repair is unsafe, because it DIFFS against the
    # workspace-scoped export and then acts on the result, so a routed scope makes
    # it re-send the whole corpus on every run.
    if args.repair and not export_can_observe(repo):
        _refuse_unobservable(repo, "repair")
        return EXIT_UNOBSERVABLE
    if args.repair:
        # The precondition this tool CANNOT check, so it states it instead.
        #
        # `--repair` acts on an absence inferred from the workspace-scoped export.
        # If these memories already live in a Space, the export does not return
        # them, they read as missing, and repairing that imports fresh copies with
        # no `repo` — a second, PRIVATE copy beside the Space one. It repairs a
        # phantom.
        #
        # Undetectable from here: `--dir` is the only scope repair accepts and its
        # slug is not invertible, so the project cannot be identified to ask whether
        # it routes; and the destination map is not exposed to clients regardless.
        # The operator knows and the tool does not (Greptile P1, round 4, on #6389).
        sys.stderr.write(
            "memory-sync: WARNING — repair infers what is missing from a WORKSPACE-scoped\n"
            "  export (memory_export_controller.ex:174-178). If this project's memories\n"
            "  already live in a SPACE, they are absent from that export, will read as\n"
            "  missing, and this run will import PRIVATE DUPLICATES beside them rather than\n"
            "  repairing the Space.\n"
            "  This cannot be checked from here — --dir's slug is not invertible and the\n"
            "  destination map is not exposed. Only repair a project you know does not route.\n"
            "  To check one entry, use verify_stored_memory with a message_hash the import\n"
            "  returned.\n"
        )
    entries = extract_entries(
        project=args.project,
        all_projects=args.all,
        skip_ephemeral=args.skip_ephemeral,
        dir_path=args.dir,
        repo=repo,
    )
    # Printed BEFORE the request, not after: this is the one thing about a push
    # the response body cannot tell you. `count: {ok, deduped, error}` looks
    # identical whether the rows reached their Space or the private workspace.
    print(f"routing: {routing}")

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
    # Written, and the PATH printed. Both docs tell an operator to confirm an entry
    # with verify_stored_memory on "a message_hash the import returned" — and until
    # now post_import discarded them, so there was no hash to pass and the documented
    # check could not be performed (Greptile P1, round 5, on #6389). For a routed
    # push this file is the only read-back that exists.
    if agg.get("hashes"):
        try:
            HASHES_PATH.parent.mkdir(parents=True, exist_ok=True)
            HASHES_PATH.write_text(json.dumps(agg["hashes"], indent=2))
            print(f"  hashes: {len(agg['hashes'])} written to {HASHES_PATH}")
            print("          pass any `message_hash` to verify_stored_memory to confirm that row landed")
        except OSError as exc:
            # Not fatal — the import already happened. But say it, because the
            # read-back the docs promise is now unavailable for this run.
            sys.stderr.write(f"memory-sync: could not write {HASHES_PATH} ({exc}); read-back hashes are lost\n")
    if agg["reposted"]:
        # Said out loud because otherwise a timeout looks like an ordinary slow
        # sync. Deliberately does NOT claim the first attempt committed: `deduped`
        # cannot separate that from "already present from an earlier sync". The
        # re-post's 200 establishes the rows are present now, which is what matters.
        print(
            f"  reposted: {agg['reposted']} chunk(s) timed out and were re-posted once; "
            "the re-post confirms these rows are present now (which attempt landed them "
            "is not determinable from `deduped`)"
        )
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
