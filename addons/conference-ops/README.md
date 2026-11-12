# Conference operations for the OpenClaw agent

**Not an installable add-on, and not yet built.** The other directories
here install software. This one specifies what one agent should *do*.

Read in this order:

| File | What it is |
|---|---|
| **`SPEC.md`** | what LuoJi must do — the requirement, with settled and open items separated |
| **`GRILLING.md`** | the full record of the session that produced it: every question, every answer, verbatim |
| `PLAN.md` | how to build it. Not written yet. |

## Why this is in the repo rather than in someone's head

The hard part of this work is not the code. It is a set of decisions a
human made about what an agent may do unsupervised — whether it can email
a stranger, what it may answer, who owns the data, what happens to
personal information about people who did not consent to any of it.

Those decisions took real time, cannot be re-derived from documentation,
and would otherwise survive only in a chat transcript. Research findings
can be regenerated in twenty minutes; judgement cannot be regenerated at
all.

So the rule for anyone picking this up: **do not re-derive the settled
items, and do not invent answers to the open ones.** Ask.

## Its relationship to the other add-ons

`addons/google-openclaw/` is the **plumbing** — it gives LuoJi a Google
account, and it is built and verified. That split was deliberate
(`GRILLING.md` Q12): the plumbing is provable by script and useful to
anyone, while the conference layer is only provable by running a
conference and is useful to one person.

## Where the work will actually live

Mostly **not here**. Most of this belongs in LuoJi's own skills, `SOUL.md`
and memory, which the agent owns and changes by being asked — see
`docs/personality.md`. The repo ships seeds, never managed files.

What plausibly belongs in this directory: the seed text to hand the agent,
a checkable list of what should exist once it is set up, and the two
specification documents above.

One piece is already written and waiting:
`agent-backup/luoji-SOUL-email-policy.md` holds the email-boundary text for
LuoJi's `SOUL.md`. It is gitignored, because it names a real person and a
real address.

## Before building anything

Two dependencies that are not code:

- **The FAQ document does not exist.** The "answer from the source, draft
  when unsure" rule is unenforceable without it.
- **Registration data starts in 2–3 months** from 2026-11-11. The graphing
  duty cannot be exercised before then.
