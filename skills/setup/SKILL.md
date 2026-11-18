---
description: >-
  Set up a new Mollow account end to end: connect, sign in, connect one data
  source, and get a first grounded, cited answer. Reads the current setup
  instructions from the Mollow server so they never go stale. Use when the user
  says "set up Mollow", "onboard me", "run the Mollow setup", or has just added
  the Mollow MCP server and wants to start.
---

# Set up Mollow

The setup instructions live on the Mollow server, not in this skill. Read them
from there, then follow them exactly. This skill only fetches them and says
plainly which copy you are using.

## 1. Read the current instructions from the server

Read the MCP resource **`mollow://prompts/setup-agent`** from the `mollow` server
(in Claude Code, the MCP resource-read tool with server `mollow` and that URI).

- **It returns text** → that text is your instructions. Its first line is a
  version stamp, `<!-- mollow-setup-agent-prompt version=… -->`. Follow everything
  after it, starting with its welcome message. Do not mention the stamp.
- **It fails because the server needs sign-in** (an authorisation error, or the
  server shows as needing authentication) → that sign-in is the one browser
  consent the instructions allow, and only the person can complete it. Tell them
  in one line that a browser page will open and they approve it once (in Claude
  Code, through `/mcp`, choosing `mollow`), wait for them, then read the resource
  again. **If sign-in does not complete** — they decline, or the read still fails
  after one retry — do not keep retrying and do not switch copies quietly: say
  that sign-in did not complete, then either stop there or continue with step 2's
  notice, whichever the person chooses.
- **The `mollow` server is not configured at all** → tell the person the one
  command to run, then stop:
  `claude mcp add -t http mollow https://mollow.ai/mcp/v2`

## 2. If the server cannot be reached — say so, then use the bundled copy

Only when the read fails for a reason other than sign-in (the server is down,
the network is unreachable, the resource is missing) fall back to
[`setup-agent-prompt.md`](setup-agent-prompt.md), the copy bundled with this
plugin.

**Before anything else, tell the person**, in one line, that you could not reach
the Mollow server and are using a local copy of the setup instructions that may
be out of date, and name that copy's version — the `version=` value on its first
line. Then follow it.

Never fall back silently. A local copy that quietly stands in for the server's is
how instructions drift with nobody noticing; saying so is what lets the person
know to retry once the server is back.

## Rules

- Do not paraphrase, shorten or reorder the instructions you read. They are
  written to be followed as given.
- Do not mix the two copies. Use the server's text when you have it; use the
  bundled copy only after saying you are.
