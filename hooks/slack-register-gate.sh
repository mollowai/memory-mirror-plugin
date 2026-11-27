#!/usr/bin/env bash
# PreToolUse(mcp__slack-local__conversations_add_message): the Slack register gate.
#
# Enforces the mechanical half of the "messages to humans" norm on posts that
# reach a channel someone outside engineering reads. The norm itself is the
# messages-to-humans skill shipped alongside this hook; the rules live in the
# slack-register-decision library beside it; this file is the wiring.
#
# ## Why this lives in the plugin and not beside the other three Slack gates
#
# A hook registered in a repository's .claude/settings.json is BRANCH-scoped. The
# colleague who asked for this norm works on a long-lived branch that carries one
# of the three existing Slack gates and none of the comms documentation, while
# still registering the Slack matcher — so from inside that session it looks
# gated and is not. install.sh merges this hook into ~/.claude/settings.json,
# which is user-level and fires whatever branch the checkout is on.
#
# ## Contract
#
#   Deny: print {hookSpecificOutput:{..., permissionDecision:"deny", reason}} to
#         stdout and exit 0. Never exit 2 — the three sibling Slack gates all use
#         the stdout form, and `mise run hooks:denies` reports exit-2 denies only,
#         so this gate will not appear there. That matches its siblings.
#   Warn: print {hookSpecificOutput:{..., additionalContext}} and exit 0.
#   Once: challenged once per distinct message. An identical resend always goes
#         through, and the deny reason says so.
#
# ## Fail-open, everywhere, on purpose
#
# Any missing input — no jq, no lib, no session id, no channel id, no register
# file — exits 0 silently. The register is this workspace's own channel topology
# and is stripped from the public plugin by the sanitizer, so a customer install
# has NO register file. Failing closed there would deny every post that install
# ever makes.
#
# Off switch: MOLLOW_SLACK_REGISTER_GATE=off (session-wide).
# Cap:        MOLLOW_SLACK_REGISTER_GATE_MAX_DENIES, default 3.
# Register:   MOLLOW_SLACK_REGISTER_FILE overrides the shipped path (tests).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command -v jq >/dev/null 2>&1 || exit 0
[ -f "${DIR}/lib/slack-register-decision.sh" ] || exit 0
# shellcheck source=lib/slack-register-decision.sh
source "${DIR}/lib/slack-register-decision.sh" 2>/dev/null || exit 0

INPUT="$(cat)"

TOOL_NAME="$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true)"
[ "$TOOL_NAME" = "mcp__slack-local__conversations_add_message" ] || exit 0

[ "$(slack_register_gate_enabled)" = "true" ] || exit 0

SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)"
CHANNEL_ID="$(printf '%s' "$INPUT" | jq -r '.tool_input.channel_id // empty' 2>/dev/null || true)"
TEXT="$(printf '%s' "$INPUT" | jq -r '.tool_input.text // empty' 2>/dev/null || true)"
BLOCKS="$(printf '%s' "$INPUT" |
  jq -r 'if (.tool_input.blocks // null) == null then ""
         else (.tool_input.blocks | if type == "string" then . else tostring end) end' \
    2>/dev/null || true)"

# A call we could not parse is a call we must not judge.
[ -n "$CHANNEL_ID" ] || exit 0

# Block Kit posts carry their prose inside the blocks structure, which these
# rules do not walk. The test is on BLOCKS rather than on TEXT being empty: a
# Block Kit call routinely carries both, with `text` serving as the notification
# fallback, and gating on an empty `text` would lint that fallback and deny a
# correctly built Block Kit post. A sibling gate shipped that bug and fixed it.
[ -z "$BLOCKS" ] || exit 0
[ -n "$TEXT" ] || exit 0

CLASS="$(slack_register_class "$CHANNEL_ID")"
# `unknown` is the fail-open answer: no register, or one that cannot be read.
case "$CLASS" in business | direct) ;; *) exit 0 ;; esac

REASON="$(slack_register_reason "$CLASS" "$TEXT" 2>/dev/null || true)"

# ── No deny: surface the judgment rules as non-blocking context ──────────────
#
# These are the four the norm asked to have rejected. They warn instead, because
# the one prior attempt at a style rule in this repo false-positived on 7 of 8
# pieces of ordinary prose. A lint that argues about writing gets switched off,
# and takes the working rules with it.
if [ -z "$REASON" ]; then
  WARNS="$(slack_register_warnings "$CLASS" "$TEXT" 2>/dev/null || true)"
  [ -n "$WARNS" ] || exit 0
  CTX="Messages-to-humans norm, worth a look before sending (not blocking): "
  CTX+="$(printf '%s' "$WARNS" | LC_ALL=C paste -sd ',' - | LC_ALL=C sed 's/,/, /g')."
  CTX+=$'\n'"Rules: skills/messages-to-humans/SKILL.md — 100 words, one decision per message, no preamble."
  jq -n --arg c "$CTX" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      additionalContext: $c
    }
  }'
  exit 0
fi

DIGEST="$(_slack_register_digest "$CHANNEL_ID" "$TEXT" "$BLOCKS")"
[ -n "$DIGEST" ] || exit 0

MARKER="$(_slack_register_marker "$SESSION_ID" "$DIGEST")"
[ -n "$MARKER" ] || exit 0

# Bound the challenges per session. An author who answers a deny by REWORDING
# rather than relinking mints a fresh digest and a fresh deny every time.
DENY_COUNT="$(_slack_register_deny_count "$SESSION_ID")"
DENY_CAP="${MOLLOW_SLACK_REGISTER_GATE_MAX_DENIES:-3}"
case "$DENY_CAP" in '' | *[!0-9]*) DENY_CAP=3 ;; esac
[ "$DENY_COUNT" -lt "$DENY_CAP" ] || exit 0

# Claim the once-only marker BEFORE emitting the deny, and abandon the deny if
# the claim fails. Three paths land here and all three mean allow: the author
# saw the deny and resent the identical text; the marker could not be written at
# all (a deny we cannot record would repeat on every retry, and so is
# unsatisfiable); or a concurrent gate process claimed it first.
_slack_register_claim "$MARKER" || exit 0

jq -n --arg r "Blocked once: ${REASON}" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
