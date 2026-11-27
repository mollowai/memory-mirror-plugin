#!/usr/bin/env bash
# slack-register-decision.sh — pure decisions for the Slack register lint.
#
# Sourced by slack-register-gate.sh. Extracted so every rule is unit-testable
# against real posts (scripts/forge/hooks/test-slack-register-decision.sh).
#
# ## What this is for
#
# A message posted into a channel a non-engineer reads is a message asking that
# person to read it. The post that produced these rules carried two PR numbers,
# a tracker id and three commit SHAs, none of them linked, into a four-person
# channel with two non-engineers in it. Its author could resolve every one of
# those six tokens; two of the four readers could resolve none of them.
#
# ## The audience is the discriminator, not the rail
#
# Direct engineer-to-engineer messages are deliberately NOT governed. That is
# not an oversight to be closed later — it was the explicit narrowing agreed
# when the norm was written, by the person who asked for the norm: he declined
# to regulate how colleagues work with each other one-to-one, and confined the
# rule to shared surfaces. So every content rule here takes a register class,
# and `direct` means silence.
#
# One rule is exempt from that scoping, because it is not a register defect at
# all: a plain-text `@name` notifies nobody on any rail, so PLAIN_AT_MENTION
# fires in a direct channel too.
#
# ## What it deliberately does NOT do
#
# It has no opinion on wording, tone or argument. The two DENY rules fire only
# on a shape that cannot be deliberate — an unresolvable reference, and a
# mention that silently fails to notify. Everything about how a message is
# WRITTEN is a warning that the call proceeds past.
#
# That split is measured rather than cautious. A sibling lint in the authoring
# repository recorded the one prior attempt at a style rule: a curated
# allowlist ANDed with a pejorative list false-positived on 7 of 8 pieces of
# ordinary engineering prose and caught 0 of 5 rewordings of the thing it was
# aimed at. The norm's author asked for word count, question count and banned
# preamble phrases as hard rejections; all three are that class, so they warn.
#
# The norm's rule 2 — "say what each figure means for them" — is implemented
# NOWHERE, including as a warning. Every mechanical form of it fires on every
# message containing a number, including every correctly-glossed one, so it
# would carry no information. Resolved toward silence, and recorded here so the
# omission is a decision.
#
# ## Byte semantics
#
# Every rule runs under LC_ALL=C. Matching is on a NORMALIZED copy of the text:
# Slack's own `<...>` constructs are blanked out first, which is what makes
# "unlinked" decidable without parsing mrkdwn — a reference inside `<url|label>`
# or a `<@U…>` mention is not present in the string the rules see at all.

# _slack_register_strip_markup <text>
#
# Blanks every `<...>` construct. Both DENY rules are defined against what
# survives: a linked reference and a real mention are inside angle brackets, an
# unlinked reference and a broken mention are not. Replaced with a space rather
# than deleted, so `a<...>b` cannot be joined into one token.
_slack_register_strip_markup() {
  # Two passes, both replacing with a space so `a<...>b` cannot be joined into
  # one token.
  #
  # 1. Slack's own `<url|label>` and `<@U…>` constructs.
  # 2. BARE URLs. Slack auto-links a raw https:// URL, and it renders a Markdown
  #    `[label](url)` literally with the URL still auto-linked — so in both cases
  #    a reference inside the URL IS reachable by the reader. Without this pass
  #    a correctly-linked message was denied for the id sitting in its own link
  #    target, which asks the author to repair a working link.
  LC_ALL=C printf '%s' "${1:-}" \
    | LC_ALL=C sed -e 's/<[^<>]*>/ /g' -e 's#[a-zA-Z][a-zA-Z0-9+.-]*://[^[:space:]<>|]*# #g'
}

# _slack_register_file
#
# Echoes the register path: $MOLLOW_SLACK_REGISTER_FILE, else the one shipped
# beside this lib. An absent file is not an error — see slack_register_class.
_slack_register_file() {
  if [ -n "${MOLLOW_SLACK_REGISTER_FILE:-}" ]; then
    printf '%s' "$MOLLOW_SLACK_REGISTER_FILE"
    return 0
  fi
  local dir
  dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)" || return 0
  printf '%s' "${dir}/channel-register.json"
}

# slack_register_class <channel_id>
#
# Echoes `business`, `direct`, or `unknown`.
#
# `unknown` is the FAIL-OPEN answer and it is load-bearing: the shipped register
# is Mollow's own channel topology and is stripped from the public plugin by
# scripts/sanitize-public-plugin.sh, so a customer install has no register at
# all. Every content rule returns nothing for `unknown`, so that install gets a
# gate with no opinion rather than one that denies every post.
#
# An UNLISTED channel in a register that does exist is different, and resolves
# to `_default` (shipped as `business`): a channel nobody has classified yet is
# more likely to be a new shared one than a new private one, and the cost of
# being wrong that way is a warning rather than a missed reader.
slack_register_class() {
  local channel="${1:-}" file cls
  [ -n "$channel" ] || { printf 'unknown'; return 0; }
  file="$(_slack_register_file)"
  [ -n "$file" ] && [ -f "$file" ] || { printf 'unknown'; return 0; }
  command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }

  cls="$(jq -r --arg c "$channel" \
    '(.channels[$c] // ._default // "unknown")' "$file" 2>/dev/null)" || cls=""
  case "$cls" in
    business | direct) printf '%s' "$cls" ;;
    *) printf 'unknown' ;;
  esac
}

# _slack_register_mention_names
#
# Echoes the colleague handles the register declares, newline separated. Used by
# PLAIN_AT_MENTION so that `@someone` is only a broken mention when `someone` is
# a person this workspace knows — `@anthropic-ai/sdk` and `ops@vendor.com` are
# not failed mentions, and a rule that flagged them would be switched off.
_slack_register_mention_names() {
  local file
  file="$(_slack_register_file)"
  [ -n "$file" ] && [ -f "$file" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  jq -r '(.mention_names // [])[]' "$file" 2>/dev/null || true
}

# slack_register_unlinked_policy
#
# Echoes `warn` or `deny` — how an unlinked internal reference is treated.
#
# It ships as `warn` ON PURPOSE, and the reason is social rather than technical.
# The norm's author asked for five rejections; this rule is a WEAKER form of one
# of them (his rejected the reference outright, this one only an unlinked
# reference), and the narrowing was never put to him. Denying on a bar he has not
# agreed to would be deciding his own rule for him.
#
# So the flip is a one-line config change rather than a code change: set
# `"unlinked_refs": "deny"` in the channel register once he agrees, or export
# MOLLOW_SLACK_REGISTER_UNLINKED=deny for a session. PLAIN_AT_MENTION is not
# gated this way — it is verbatim in his spec and denies from the start.
slack_register_unlinked_policy() {
  local env_val="${MOLLOW_SLACK_REGISTER_UNLINKED:-}" file val
  case "$env_val" in
    deny | DENY) printf 'deny'; return 0 ;;
    warn | WARN) printf 'warn'; return 0 ;;
  esac
  file="$(_slack_register_file)"
  if [ -n "$file" ] && [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    val="$(jq -r '(.unlinked_refs // "warn")' "$file" 2>/dev/null)" || val=""
    case "$val" in deny) printf 'deny'; return 0 ;; esac
  fi
  printf 'warn'
}

# slack_register_counts <text>
#
# Echoes `words questions refs shas paths mentions` — the measured numbers
# behind the findings, so a deny reason can state what it counted rather than
# assert that something is wrong.
slack_register_counts() {
  local text="${1:-}" stripped words questions refs shas paths mentions name
  stripped="$(_slack_register_strip_markup "$text")"

  words="$(LC_ALL=C printf '%s' "$text" | wc -w | tr -d ' ')"
  questions="$(LC_ALL=C printf '%s' "$text" | tr -cd '?' | wc -c | tr -d ' ')"
  refs="$(LC_ALL=C printf '%s\n' "$stripped" | grep -oE '(#[0-9]{3,5}|MOL-[0-9]+)' | wc -l | tr -d ' ')"
  # A SHA must carry BOTH a digit and a hex letter. Without the digit, ordinary
  # words built from a-f match ("effaced", "defaced" are both 7 hex letters);
  # without the letter, every 7-digit number does.
  shas="$(LC_ALL=C printf '%s\n' "$stripped" \
    | grep -oE '\b[0-9a-f]{7,40}\b' \
    | grep -E '[0-9]' | grep -E '[a-f]' | wc -l | tr -d ' ')"
  paths="$(LC_ALL=C printf '%s\n' "$stripped" \
    | grep -oE '\b(webapp|scripts|plugins|forge|forge_core|host_agent|bridge|docs|specs|tacit_core|test|tests|pulumi)/[A-Za-z0-9._/-]*[A-Za-z0-9_/-]' \
    | wc -l | tr -d ' ')"

  mentions=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    # No pipeline: `printf | grep -q` is the SIGPIPE footgun this repo already
    # documents — grep -q exits on the first match and closes the pipe while
    # printf is still writing, so under pipefail the pipeline reports the write
    # failure rather than grep's success. A herestring has no upstream process
    # to kill.
    if LC_ALL=C grep -qiE "(^|[^A-Za-z0-9_])@${name}([^A-Za-z0-9_]|$)" <<< "$stripped"; then
      mentions=$((mentions + 1))
    fi
  done <<< "$(_slack_register_mention_names)"

  printf '%s %s %s %s %s %s\n' "$words" "$questions" "$refs" "$shas" "$paths" "$mentions"
}

# slack_register_evidence <text>
#
# Echoes the actual tokens matched, space separated and capped, so a deny reason
# can quote what it found. A reason naming "#8800, MOL-9680, 8d1af1ca" is
# checkable by the person reading it; "contains internal references" is not.
slack_register_evidence() {
  local stripped raw out="" tok n=0
  stripped="$(_slack_register_strip_markup "${1:-}")"

  # Every match collected first, then trimmed and joined in bash. The earlier
  # form piped into `head -6`, which exits after its sixth line and SIGPIPEs
  # whatever is still writing upstream — the same early-exit hazard as a
  # `grep -q` on the end of a pipe, and the reason this reads as a loop.
  raw="$(
    LC_ALL=C grep -oE '(#[0-9]{3,5}|MOL-[0-9]+)' <<< "$stripped" || true
    LC_ALL=C grep -oE '\b[0-9a-f]{7,40}\b' <<< "$stripped" \
      | LC_ALL=C grep -E '[0-9]' | LC_ALL=C grep -E '[a-f]' || true
    LC_ALL=C grep -oE '\b(webapp|scripts|plugins|forge|forge_core|host_agent|bridge|docs|specs|tacit_core|test|tests|pulumi)/[A-Za-z0-9._/-]*[A-Za-z0-9_/-]' <<< "$stripped" || true
  )"

  while IFS= read -r tok; do
    [ -n "${tok//[[:space:]]/}" ] || continue
    [ "$n" -lt 6 ] || break
    if [ -z "$out" ]; then out="$tok"; else out="${out}, ${tok}"; fi
    n=$((n + 1))
  done <<< "$raw"

  printf '%s' "$out"
}

# slack_register_findings <class> <text>
#
# Echoes one DENY code per line, or nothing. Codes are [A-Z_] only, because they
# are interpolated into a deny reason and into marker filenames downstream.
#
#   UNLINKED_INTERNAL_REF  a PR number, tracker id, commit SHA or repo path with
#                          no link, in a channel a non-engineer reads
#   PLAIN_AT_MENTION       `@name` of a known colleague outside the `<@U…>`
#                          form, so Slack notifies nobody
slack_register_findings() {
  local cls="${1:-unknown}" text="${2:-}"
  [ -n "${text//[[:space:]]/}" ] || return 0
  case "$cls" in business | direct) ;; *) return 0 ;; esac

  local words questions refs shas paths mentions
  read -r words questions refs shas paths mentions <<< "$(slack_register_counts "$text")"

  # Audience-scoped: an unresolvable reference is only a defect when someone who
  # cannot resolve it is reading.
  if [ "$cls" = "business" ] && [ "$(slack_register_unlinked_policy)" = "deny" ] \
     && { [ "$refs" -gt 0 ] || [ "$shas" -gt 0 ] || [ "$paths" -gt 0 ]; }; then
    printf 'UNLINKED_INTERNAL_REF\n'
  fi
  # NOT audience-scoped: a mention that notifies nobody is broken everywhere.
  if [ "$mentions" -gt 0 ]; then
    printf 'PLAIN_AT_MENTION\n'
  fi
}

# slack_register_warnings <class> <text>
#
# Echoes one WARN code per line. These never deny — see the header. Audience
# scoped: nothing is said about an engineer-to-engineer post.
#
#   OVER_100_WORDS   the norm's rule 6
#   MULTI_QUESTION   the norm's rule 7, one decision per message
#   BANNED_PREAMBLE  the norm's rule 4
slack_register_warnings() {
  local cls="${1:-unknown}" text="${2:-}" limit="${MOLLOW_SLACK_REGISTER_MAX_WORDS:-100}"
  [ -n "${text//[[:space:]]/}" ] || return 0
  [ "$cls" = "business" ] || return 0
  case "$limit" in '' | *[!0-9]*) limit=100 ;; esac

  local words questions refs shas paths mentions normalized
  read -r words questions refs shas paths mentions <<< "$(slack_register_counts "$text")"

  if [ "$(slack_register_unlinked_policy)" != "deny" ] \
     && { [ "$refs" -gt 0 ] || [ "$shas" -gt 0 ] || [ "$paths" -gt 0 ]; }; then
    printf 'UNLINKED_INTERNAL_REF\n'
  fi
  [ "$words" -gt "$limit" ] && printf 'OVER_100_WORDS\n'
  [ "$questions" -ge 2 ] && printf 'MULTI_QUESTION\n'

  # Lowercased with both apostrophe spellings deleted, so "here's", "here’s"
  # and "heres" all normalize to one form.
  normalized="$(LC_ALL=C printf '%s' "$text" | LC_ALL=C tr '[:upper:]' '[:lower:]' \
    | LC_ALL=C sed "s/'//g; s/\xe2\x80\x99//g")"
  if LC_ALL=C grep -qE \
    '(you asked me to|heres the first one|sorry this is late|quick update|great question)' \
    <<< "$normalized"; then
    printf 'BANNED_PREAMBLE\n'
  fi
  return 0
}

# slack_register_reason <class> <text>
#
# Echoes the deny reason, or "" when there is nothing to deny. The reason states
# the measurement, quotes what it matched, and states the escape hatch — sending
# the same text again always goes through, which is the only override an author
# cannot forget, because the reason they have already read states it.
slack_register_reason() {
  local cls="${1:-unknown}" text="${2:-}" findings warns code evidence
  findings="$(slack_register_findings "$cls" "$text")" || return 0
  [ -n "$findings" ] || return 0

  local words questions refs shas paths mentions
  read -r words questions refs shas paths mentions <<< "$(slack_register_counts "$text")"
  evidence="$(slack_register_evidence "$text")"

  local out="This Slack post goes to a channel someone outside engineering reads."
  out+=$'\n'"Measured: ${words} word(s), ${refs} issue/PR ref(s), ${shas} commit SHA(s), ${paths} repo path(s), ${mentions} plain-text mention(s)."
  out+=$'\n'

  while IFS= read -r code; do
    case "$code" in
      UNLINKED_INTERNAL_REF)
        out+=$'\n'"• UNLINKED_INTERNAL_REF — ${evidence}. These name things the reader cannot look up. Link each one, or say what it is in words: <https://github.com/mollowai/monorepo/pull/8800|the Latency tile fix>." ;;
      PLAIN_AT_MENTION)
        out+=$'\n'"• PLAIN_AT_MENTION — ${mentions} name(s) written as plain text \"@name\". Slack notifies NOBODY for that form; it renders as grey text. Use the user-ID form <@U…>, looked up with the Slack user search rather than guessed." ;;
    esac
  done <<< "$findings"

  warns="$(slack_register_warnings "$cls" "$text")"
  if [ -n "$warns" ]; then
    out+=$'\n'
    out+=$'\n'"Also worth a look, but not blocking: $(printf '%s' "$warns" | LC_ALL=C paste -sd ',' - | LC_ALL=C sed 's/,/, /g')."
  fi

  out+=$'\n'
  # The BUNDLED path, not the authoring repo's docs/. A customer who enables the
  # gate with their own register gets this reason, and docs/development/ is not
  # in their bundle — a deny pointing at a file the reader does not have is a
  # deny they cannot act on.
  out+=$'\n'"The norm: skills/messages-to-humans/SKILL.md"
  out+=$'\n'"To post it as written, send the same text again — an identical retry is never challenged twice."
  printf '%s\n' "$out"
}

# slack_register_gate_enabled
#
# Echoes "false" when MOLLOW_SLACK_REGISTER_GATE switches the lint off, else
# "true". Session-wide, for a job that deliberately relays machine-shaped text.
slack_register_gate_enabled() {
  case "${MOLLOW_SLACK_REGISTER_GATE:-on}" in
    off | OFF | 0 | false | no) echo "false" ;;
    *) echo "true" ;;
  esac
}

# =============================================================================
# Once-per-message marker machinery
# =============================================================================
#
# Deliberately NOT borrowed from scripts/forge/hooks/lib/slack-thread-decision.sh,
# which is where the three sibling Slack gates get theirs. That lib is not part
# of the plugin, so a customer install — or a session on a branch that predates
# it — would source a file that is not there. The semantics below are the same
# and the suite asserts the behaviour rather than the implementation.
#
# The namespace is this gate's own. Sharing one with a sibling meant a session
# that spent its formatting challenges had none left for a register defect, and
# the reverse.

_slack_register_safe_session() {
  local s="${1:-}"
  [ -n "$s" ] || return 1
  case "$s" in
    *[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

_slack_register_marker_dir() {
  local base="${TMPDIR:-/tmp}"
  printf '%s' "${MOLLOW_SLACK_REGISTER_GATE_DIR:-${base%/}/mollow-slack-register-gate}"
}

# _slack_register_digest <channel> <text> <blocks>
#
# 12 hex chars over the three fields joined with \037, so a reworded message
# mints a new digest and a byte-identical resend hits the existing marker. That
# is the escape hatch: the deny reason tells the author to send the same text
# again, and this is what makes that true.
_slack_register_digest() {
  local sep payload hash=""
  sep=$(printf '\037')
  payload="${1:-}${sep}${2:-}${sep}${3:-}"
  # sha1sum is absent on macOS; shasum is present there and on CI. cksum is the
  # last resort — weaker, but this keys a local advisory marker, not anything
  # security-bearing.
  if command -v sha1sum >/dev/null 2>&1; then
    hash=$(printf '%s' "$payload" | sha1sum 2>/dev/null | tr -dc '0-9a-f' | cut -c1-12) || hash=""
  elif command -v shasum >/dev/null 2>&1; then
    hash=$(printf '%s' "$payload" | shasum 2>/dev/null | tr -dc '0-9a-f' | cut -c1-12) || hash=""
  elif command -v cksum >/dev/null 2>&1; then
    hash=$(printf '%s' "$payload" | cksum 2>/dev/null | tr -dc '0-9a-f' | cut -c1-12) || hash=""
  fi
  printf '%s' "$hash"
}

_slack_register_marker() {
  local session="${1:-}" digest="${2:-}" dir
  [ -n "$digest" ] || return 0
  _slack_register_safe_session "$session" || return 0
  case "$digest" in *[!0-9a-f]*) return 0 ;; esac
  dir="$(_slack_register_marker_dir)"
  [ -n "$dir" ] || return 0
  printf '%s' "${dir}/slack-register-${session}-${digest}"
}

# Atomic create. A message whose marker already exists cannot be claimed twice,
# which is what makes an identical resend fall through to allow.
_slack_register_claim() {
  local path="${1:-}"
  [ -n "$path" ] || return 1
  mkdir -p "$(dirname "$path")" 2>/dev/null || return 1
  (
    set -o noclobber
    : >"$path"
  ) 2>/dev/null || return 1
  return 0
}

# Counting marker files needs no counter file, so there is no
# read-modify-write race between concurrent tool calls in one turn.
_slack_register_deny_count() {
  local session="${1:-}" dir
  if ! _slack_register_safe_session "$session"; then printf '0'; return 0; fi
  dir="$(_slack_register_marker_dir)"
  if [ -z "$dir" ] || [ ! -d "$dir" ]; then printf '0'; return 0; fi
  find "$dir" -maxdepth 1 -name "slack-register-${session}-*" 2>/dev/null | wc -l | tr -d ' ' || printf '0'
}
