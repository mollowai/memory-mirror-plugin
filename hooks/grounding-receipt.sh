#!/usr/bin/env bash
# PostToolUse (matcher: mcp__mollow__get_session_context): write the grounding
# receipt that grounding-engagement.sh (Stop) scores every later turn against.
#
# The server returns `_grounding = %{emission_id, artifacts: [%{kind, ref, terms,
# tools}]}` on a get_session_context call that captured a grounding emission
# (Mollow.MCP.MemoryTools.maybe_put_grounding/3). This hook copies that — and
# nothing else from the response — into a per-session receipt, plus the
# transcript byte offset at this moment, so the Stop hook counts only what
# happened AFTER the grounding arrived.
#
# ── The shape of .tool_response for an MCP tool (measured, not assumed) ─────
# Captured from a live `claude -p` run calling mcp__mollow__get_session_context
# on 2026-11-17: `.tool_response` is an ARRAY of MCP content blocks,
#   [{"type": "text", "text": "<the tool result, JSON-encoded as a string>"}]
# — NOT the result object. So `.tool_response._grounding` is null on every real
# call, and a parse written that way would never write a receipt while every
# fixture built from the server's map shape passed. The parser joins the text
# blocks and decodes them; it also accepts a bare object or string, so a later
# Claude Code that unwraps MCP results does not silently stop the receipts.
#
# ── Blast radius ─────────────────────────────────────────────────────────────
# No network. The hook writes a file only when the response carries
# `_grounding`, which only a server with grounding capture returns; everything
# else is an exit 0 with nothing written. Never prints to stdout (no context is
# injected) and never fails the turn.
#
# Opt-out: MOLLOW_GROUNDING_ENGAGEMENT=0 (or off/false/no) disables both hooks.

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_common.sh"

case "$(printf '%s' "${MOLLOW_GROUNDING_ENGAGEMENT:-}" | tr '[:upper:]' '[:lower:]')" in
  0 | off | false | no) exit 0 ;;
esac
command -v jq >/dev/null 2>&1 || exit 0

input="$(cat)"

tool_name="$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null || true)"
case "$tool_name" in
  mcp__*__get_session_context) ;;
  *) exit 0 ;;
esac

session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
mm_safe_component "$session_id" || exit 0
transcript_path="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
prompt_id="$(printf '%s' "$input" | jq -r '.prompt_id // empty' 2>/dev/null || true)"

# Extract and sanitize `_grounding`. Bounded on the way in: at most 200
# artifacts, refs ≤200 chars (the server's citation_key cap), at most 50 terms
# and 50 tools each, strings only.
grounding="$(printf '%s' "$input" | jq -c '
  def body:
    if type == "array" then
      [ .[]? | select(type == "object" and (.type? // "") == "text") | (.text? // "") ] | join("")
    else . end;
  def str_list: [ (. // [])[]? | select(type == "string" and length > 0 and length <= 200) ] | .[:50];
  (.tool_response | body) as $b
  | (if ($b | type) == "string" then ($b | try fromjson catch null) else $b end) as $r
  | ($r | if type == "object" then (._grounding? // null) else null end) as $g
  | if ($g | type) != "object" then empty
    elif (($g.emission_id? // null) | type) != "string" then empty
    else
      { emission_id: $g.emission_id,
        artifacts: [ ($g.artifacts? // [])[]?
                     | select(type == "object")
                     | select((.kind? // "") as $k | ["skill", "hypothesis", "decision"] | index($k))
                     | select(((.ref? // null) | type) == "string" and (.ref | length) > 0 and (.ref | length) <= 200)
                     | { kind, ref, terms: (.terms | str_list), tools: (.tools | str_list) } ][:200] }
    end
  ' 2>/dev/null || true)"

[ -n "$grounding" ] || exit 0
emission_id="$(printf '%s' "$grounding" | jq -r '.emission_id' 2>/dev/null || true)"
mm_safe_component "$emission_id" || exit 0

offset=0
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  offset="$(wc -c <"$transcript_path" 2>/dev/null | tr -d ' ')"
  case "$offset" in '' | *[!0-9]*) offset=0 ;; esac
fi

receipt_root="${TMPDIR:-/tmp}/mollow-grounding"
receipt_dir="${receipt_root}/${session_id}"
# Both levels must be ours, private and not symlinks before anything is written
# beneath them (mm_private_dir) — a shared /tmp makes the path predictable.
mm_private_dir "$receipt_root" || exit 0
mm_private_dir "$receipt_dir" || exit 0

# A later get_session_context in the same session replaces the receipt: the
# newest grounding is the one later turns are attributed to. The temp file is
# created exclusively by mktemp, never at a predictable name a planted symlink
# could redirect.
tmp="$(mktemp "$receipt_dir/.receipt.XXXXXX" 2>/dev/null)" || exit 0
# `turn_ref`/`turn_start` mark the grounding turn itself: its Stop scores only
# what came after this point (see grounding-engagement.sh § Windows).
printf '%s' "$grounding" | jq -c --argjson off "$offset" --arg pid "$prompt_id" \
  '. + {offset: $off, turn_ref: (if $pid == "" then null else $pid end), turn_start: $off}' \
  >"$tmp" 2>/dev/null &&
  mv -f "$tmp" "$receipt_dir/receipt.json" 2>/dev/null
rm -f "$tmp" 2>/dev/null || true
exit 0
