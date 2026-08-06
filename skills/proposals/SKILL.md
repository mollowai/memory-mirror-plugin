---
description: >-
  Capture a follow-up action that came up mid-session but is not being done now,
  and close it if it gets handled. Use when something is deferred — "we should
  fix that later", "leaving that for now", "TODO", "let's come back to this",
  "out of scope for this change" — or when wrapping up a session and open items
  need sweeping.
argument-hint: <what to capture, or "sweep" to review open items>
---

# Proposals

Record follow-ups the moment they are deferred, so they are not lost when the
session ends.

Without this, a follow-up only survives if the end-of-session summarizer happens
to notice it in the transcript. Something raised at minute 10 and abandoned at
minute 40 usually does not make the summary.

## When to capture

Capture the moment something is **deferred**, not at the end:

- a bug or smell noticed while doing something else
- a cleanup, refactor, or test explicitly postponed
- a question parked because the answer was not needed yet
- anything cut as out of scope for the current change

Do **not** capture what you are about to do in this session, or what you just
did. Those are not follow-ups.

## Instructions

1. Call `capture_proposal` with `content` and this session's `session_id`.
2. Write `content` as one self-contained imperative that still makes sense days
   later, in a different session, with none of this context loaded:
   - Good — "Finish extracting the embedding helper from ActionManager"
   - Bad — "finish that refactor", "fix the thing above", "come back to this"
3. Add `rationale` (one sentence on why it matters) and `refs` (file paths,
   issue ids, PR numbers) when you have them.
4. If you handle it later in the same session, close it with `resolve_proposal`.

## Sweeping before you wrap up

Before ending a substantial session, call `list_proposals` and close what you
actually handled:

- `resolve_proposal(hash, outcome: "done")` — the work happened
- `resolve_proposal(hash, outcome: "dropped")` — it turned out not to be worth
  doing

The difference is recorded, so do not use `done` to dismiss something.

Also call `list_proposals` after a long stretch of work: earlier captures scroll
out of context as the conversation compacts, and this is the only way to see
them again.

Anything left open resurfaces later as unfinished work — which is the point. Do
not close items just to leave a clean list.

## If the tools return "not enabled"

Proposals are off for this user. Nothing was recorded — say so rather than
treating the item as captured.
