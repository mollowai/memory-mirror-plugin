---
description: >-
  How to write a message an agent sends to a person — in Slack, in email, or on a
  tracker issue — when somebody outside engineering will read it. Load it before
  drafting or sending any such message, and before posting into a shared channel.
  Owns: the audience test (a channel with a non-engineer in it is governed, a
  one-to-one between engineers is not), the six rules every message follows, the
  four shapes a message can take, what the companion hook denies versus warns
  about, and the two defects it will stop you on. Triggers — "post this in",
  "reply to them", "draft a message to", "send an update", "tell the team",
  "@-mention", "write this up for".
---

# Messages to humans

**The question this answers:** a message is about to reach somebody who does not
read code. What has to be true of it?

A message naming a pull request number, a tracker id and a commit hash is
complete to its author and unreadable to its reader. Nothing errors. The author
sees a message; the reader sees tokens that resolve to nothing, and the usual
outcome is that it goes unanswered.

## Scope — the audience, not the rail

This binds a message **where a reader outside engineering is present**. A
one-to-one between engineers is **not** governed, and that is deliberate: people
get to decide between themselves how they work together. What has to be legible
is the shared surface.

| Surface | Governed |
|---|---|
| A channel with a non-engineer in it | yes |
| A group message with a non-engineer in it | yes |
| A one-to-one between engineers | **no** |
| Email or a tracker comment addressed to a person | yes |

A dense, jargon-heavy message is not a defect in a one-to-one with a colleague
who prefers it that way. The same message in a four-person channel is, because
the other three did not choose it.

## Every message

1. **Plain words, in your own voice.** No pull request numbers, commit hashes,
   branch names, file paths or internal shorthand. Name a thing by what it does.
   First person, directly: say what you need, and in one sentence why it matters
   to the people involved. Prose, not headers and bullets, unless you are posting
   a list for people to react to.
2. **Numbers explained.** Say what each figure means for them. State bad news
   plainly.
3. **Real mentions, so they are notified.** In Slack the user-ID form `<@U…>`
   renders as @name and notifies them. **Plain text `@name` notifies nobody** —
   it renders as grey text and the person never sees it. Look the id up with the
   user-search tool; never guess it.
4. **No preamble about the message itself** — no "you asked me to", "here's the
   first one", "sorry this is late", "quick update", "great question". A sentence
   connecting to something they already know is not preamble; it is the opening.
5. **Real dates.** A date you ask them to meet is when *they* must act, not when
   the work is due. Work backwards from the deadline, subtracting what happens
   after their answer, plus buffer. Give a weekday, a date and a time in their
   zone, and say why that date in a few words. If you cannot estimate what
   follows their answer, say so rather than quoting the deadline.
6. **Under 100 words.** The test: could they answer it from their phone, in one
   line?

## The four shapes

### A — you need a decision

- **One decision per message.** If several are waiting, send the one whose answer
  may make the others moot.
- **Open from what they know, then the issue.** First sentence connects to a
  comment they saw, a meeting they were in, or the work and how close it is. The
  next says what changed.
- **One ask**, answerable in a few words, with the date you need it. If the ask
  is not itself your recommendation, give your recommendation too.

### B — replying in someone's thread

- Reply **in the thread**, never at the channel's top level.
- **The first sentence answers what they asked** — yes, no, a date, or the fact.
  Reason afterwards, one sentence at most.
- Do not restate their question or recap the thread. They were there.
- **Mention them**, even in a thread, so they are notified.
- If you cannot answer yet, say when you will, with a real time, then do it in
  the same thread.
- A decision you need back is **one** question. If it is about something else,
  start a new message rather than burying it here.
- Close the loop in the same thread, in one sentence, when it is done.

### C — an update that needs nothing

- Open with **"No action needed:"**, then one or two sentences.
- Send one **only if it changes what they would do or believe.** Otherwise do not
  send it.

### D — does it belong on this rail at all

- A shared channel carries four things: a decision someone must make, an answer
  to someone's question, a short list to react to, or an update that changes what
  someone would do.
- **The paste test.** If a reader would have to paste your message into an AI to
  understand it or reply, do not send it. Cut it to the question or the list it
  contains.
- **Converging: post the list, not the document.** Say so in the first line
  ("Converging on X:"). A numbered list, seven items or fewer, one line each, and
  ask people to react by number. Each round, repost the revised list in the same
  thread and mark what changed. Do not link a longer version.
- **Brainstorming may run longer, if you say so.** Open with "Brainstorm, not a
  decision:". When it is time to converge, switch to the rule above.
- **Plan before building something new.** When the work shifts into a kind you
  have not done before, stop and post the plan as a short numbered list. Start
  when someone reacts. Urgency is not a reason to skip it.
- **Handing over AI output: attach it, then explain it in plain words.** Attach a
  `.md` file rather than pasting it. Name it for what it is. The message still
  follows every rule above and has to stand on its own: what the file is, the one
  thing in it that matters to them, and what you want them to do. Nobody should
  have to open the attachment to reply.

## What the hook stops you on

A Slack register lint runs before a message is sent — the
`slack-register-gate` hook shipped with this plugin. **Two rules
deny. Three warn. Everything else is yours.**

| Rule | Behaviour |
|---|---|
| A name written as plain text `@name` instead of `<@U…>` | **deny** |
| A pull request number, tracker id, commit hash or file path with no link, in a channel a non-engineer reads | warn, or deny — your choice |
| Over 100 words · more than one question · an opening preamble phrase | warn |

The unlinked-reference rule ships as a **warning**. It is the one rule here
reasonable people disagree about — a team that works in the open may want every
bare identifier rejected, and a team whose channels are mostly engineers will
find that noisy. Set `"unlinked_refs": "deny"` in the register below to make it
block, or leave it as a warning.

A deny tells you what it counted and quotes what it matched, and **sending the
identical text again always goes through.** It is a challenge, not a veto — so
if you have read it and still mean it, resend.

### Why only two deny

The other rules are opinions about writing, and a lint that argues about writing
gets switched off — taking the rules that work with it. The two that deny are
defects rather than preferences: a plain-text mention silently fails to notify
anyone, and an unlinked internal reference names something the reader has no way
to look up. Neither can be deliberate.

**"Say what each number means" is enforced nowhere, not even as a warning.**
Every mechanical form of it fires on every message containing a figure, including
every correctly-written one, so the warning would carry no information. It stays
a rule you follow rather than one you are reminded of.

### It is inert without a channel register

The gate reads a JSON file mapping channel ids to `business` or `direct`. If that
file is absent — it is not shipped with this plugin, because it describes one
team's channels — the gate has **no opinion** and emits nothing. To switch it on,
create a `channel-register.json` in the plugin's hooks directory, beside the
gate itself:

```json
{
  "_default": "business",
  "mention_names": ["alex", "sam", "jordan"],
  "channels": {
    "C0ABCDEF123": "business",
    "D0ABCDEF456": "direct"
  }
}
```

`mention_names` is how the plain-mention rule knows a colleague's handle from a
package name or an email address — without it, that rule stays silent too. An
unlisted channel falls to `_default`, and `business` is the safer default: a new
shared channel is then covered rather than quietly exempt.

Point `MOLLOW_SLACK_REGISTER_FILE` elsewhere to override the path, and set
`MOLLOW_SLACK_REGISTER_GATE=off` to disable the lint for a session that
deliberately relays machine-shaped text.

## What this does not decide

**Whether to send.** Show the draft and let the person you are acting for approve
the wording. Agreeing with a decision is not approving the words, and on most
rails a sent message cannot be quietly withdrawn.
