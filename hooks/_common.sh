#!/usr/bin/env bash
# Shared helpers for Memory Mirror hooks.
#
# Fail-safe contract: every hook sources this and MUST `exit 0` even on error so
# it can never block or break a Claude Code session. All network calls are time-
# boxed and swallow errors.
#
# Transport: the hooks call the webapp's single-request REST surface
# (/api/memory/*) with a `mol_*` key — NOT the MCP JSON-RPC endpoint, which would
# need an initialize→tools/call handshake per call (too slow for the per-prompt
# recall hook).
#
# Config (injected into the session env by the monorepo's session launchers):
#   MOLLOW_MEMORY_API_KEY  required — staging mol_* key. Absent => hooks no-op.
#   MOLLOW_MEMORY_URL      the MCP url (…/mcp/v2). The API base is derived by
#                          stripping the /mcp/v2 suffix. Public default = prod;
#                          the monorepo overrides it to staging.

set -uo pipefail

mm_api_base() {
  local url="${MOLLOW_MEMORY_URL:-https://mollow.ai/mcp/v2}"
  # Strip an optional trailing slash first so "…/mcp/v2/" still maps to the API
  # base. Otherwise the /mcp/v2 strip silently fails and every path double-prefixes.
  url="${url%/}"
  printf '%s' "${url%/mcp/v2}"
}

# Environment label for the CURRENT target (dev|staging|prod|custom), derived
# from the API base. Mirrors memory_sync.py `infer_env_from_url` and the
# fleet-target env→base map. Sync state must be keyed by this: a `synced`
# fingerprint recorded against one env would otherwise suppress the push to a
# different env after a fleet-target switch (the silent-drop bug — memories
# synced to staging never reached prod because the project looked "done").
mm_env_label() {
  local base
  base="$(mm_api_base)"
  case "$base" in
    https://mollow.ai) echo prod ;;
    https://staging.mollow.ai) echo staging ;;
    http://localhost:4000 | http://127.0.0.1:4000) echo dev ;;
    # A non-standard base (preview / self-hosted) gets a label derived from the
    # base itself, not a flat "custom" — otherwise two different custom targets
    # would share one `${label}:${slug}` sync-state key, and a switch between
    # them would suppress the required re-import (the very drop this keying
    # prevents for the standard envs). Short hash keeps the key readable.
    *)
      local h
      if command -v shasum >/dev/null 2>&1; then
        h="$(printf '%s' "$base" | shasum | awk '{print $1}')"
      elif command -v sha256sum >/dev/null 2>&1; then
        h="$(printf '%s' "$base" | sha256sum | awk '{print $1}')"
      else
        h="$(printf '%s' "$base" | cksum | awk '{print $1}')"
      fi
      printf 'custom-%s' "${h:0:8}"
      ;;
  esac
}

# Preconditions: a key, jq, and curl must be present, and MOLLOW_MEMORY_URL must
# end in /mcp/v2 — else the hook no-ops. The suffix check is a security guard: a
# misconfigured URL would otherwise send the mol_* key to `<full_url>/api/memory/*`
# on whatever host the URL resolves to.
mm_ready() {
  [ -n "${MOLLOW_MEMORY_API_KEY:-}" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  command -v curl >/dev/null 2>&1 || return 1

  local url="${MOLLOW_MEMORY_URL:-https://mollow.ai/mcp/v2}"
  url="${url%/}"
  if [[ "$url" != */mcp/v2 ]]; then
    echo "memory-mirror: MOLLOW_MEMORY_URL ('${url}') is missing the /mcp/v2 suffix — refusing to send credentials" >&2
    return 1
  fi

  # Never send the bearer key over plaintext to a remote host. Allow http only
  # for local development — match the host boundary exactly (optional port) so a
  # prefix like http://localhost.evil.com can't slip through.
  if [[ "$url" == https://* ]]; then
    :
  elif [[ "$url" =~ ^http://(localhost|127\.0\.0\.1)(:[0-9]+)?/mcp/v2$ ]]; then
    :
  else
    echo "memory-mirror: MOLLOW_MEMORY_URL ('${url}') is not HTTPS — refusing to send credentials" >&2
    return 1
  fi
}

# POST JSON body ($2) to path ($1) with timeout ($3, default 3s). Fire-and-forget.
mm_post() {
  curl -sS --max-time "${3:-3}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null 2>&1 || true
}

# Like mm_post but returns curl's exit status (0 = delivered, non-zero on
# network error or HTTP >= 400 via --fail) so a caller can gate follow-up state
# (e.g. a sync fingerprint) on successful delivery. Still silent.
mm_post_ok() {
  curl -fsS --max-time "${3:-3}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" >/dev/null 2>&1
}

# GET path ($1) with timeout ($2, default 2s) and print the response body.
mm_get() {
  curl -sS --max-time "${2:-2}" \
    -X GET "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    2>/dev/null || true
}

# POST JSON body ($2) to path ($1) with timeout ($3, default 2s) and print the
# response body (for hooks that inject the result as context).
mm_post_read() {
  curl -sS --max-time "${3:-2}" \
    -X POST "$(mm_api_base)$1" \
    -H "Authorization: Bearer ${MOLLOW_MEMORY_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$2" \
    2>/dev/null || true
}

# Emit additionalContext for SessionStart / UserPromptSubmit. $1 = event name,
# $2 = context text. No-op when the text is empty.
mm_emit_context() {
  [ -z "${2:-}" ] && return 0
  jq -cn --arg ev "$1" --arg ctx "$2" \
    '{hookSpecificOutput: {hookEventName: $ev, additionalContext: $ctx}}'
}

# Best-effort project label from a cwd path.
mm_project_of() {
  local cwd="${1:-}"
  [ -z "$cwd" ] && return 0
  basename "$cwd"
}
