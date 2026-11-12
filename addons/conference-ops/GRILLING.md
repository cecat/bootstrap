# The grilling session, 2026-11-11 — full record

**This is the raw material. `SPEC.md` is the distillation.** If the two
ever disagree, this one is the evidence and the spec is the error.

Captured because the thinking here cost the owner real time and is the part
an agent cannot regenerate. Research findings can be re-derived from
vendor docs in twenty minutes; a decision about whether an agent may email
a stranger cannot be derived at all.

Conducted with the `mattpocock-skills:grilling` skill: the agent asks the
whole answerable frontier each round, the user answers, the answers
reshape the tree. Questions are reproduced with the recommendation that
accompanied them, because what the owner *rejected* is as informative as
what he accepted.

Format: **Q** as asked (abridged where it was long), ➡️ the recommendation
offered, **A** the owner's answer as given.

---

## Round 1 — Q1: What is LuoJi actually for?

**Q.** You gave a capability list — Forms, Sheets, Docs, Calendar, Gmail.
Gandalf has *duties*: it reads your mail and manages your calendar. That is
a job. "Gmail access" is a permission. What is the job? Start the sentence
with a verb. If there is something you currently do by hand that you want
taken over, say that instead — it is more useful than an abstraction.

*(Note: an earlier version of this round asked five questions at once,
pre-filled with recommendations, and the owner rejected the approach:
"I thought you were grilling me. Instead you gave me a lengthy homework
assignment to read all of your assumptions about what you think I meant."
The restart — one question, then wait — is the version that worked.)*

**A.** "Luoji will be an assistant helping to manage parallel technical
tracks at a conference. This will mean watching forms that people use to
propose talks, reviewing abstracts using a rubric I provide, responding to
authors who submit, responding to general questions about the event,
curating separate track spreadsheets based on the track suggested by an
author in their proposal to give a talk (giving track leaders a dedicated
sheet just showing their track proposed talks), keeping an inventory of all
proposed talks and their status (reviewed, accepted/rejected/fix-requested),
and regularly emailing track leaders with updates on their tracks. Luoji
will also compare registration counts from 2024, 2025, and 2026 —
normalized to the number of days prior to the event — against registration
counts for 2027. This will mean checking a status spreadsheet maintained by
the registration staff, which will have the prior three event registration
numbers for n days prior to the event, starting at about 125 days prior to
the event (Luoji will generate a line graph each day)."

**What this changed.** Three things the agent had not scoped: a review
rubric, a proposal state machine, and scheduled outbound email to named
third parties. Also surfaced that LuoJi would email *strangers*, which is
categorically different from Gandalf, and that "responding to general
questions" is unbounded inbound.

---

## Q2: Does LuoJi send mail autonomously, or does everything pass you first?

**Q.** Three positions: (1) fully autonomous; (2) drafts only, you approve
and send; (3) split — autonomous for mechanical predictable traffic,
drafts for anything addressed to a person about *their* proposal.

This is the one to sit with, because it is expensive to reverse. A wrong
rejection email cannot be unsent, and the model will be confidently wrong
occasionally. It also decides whether the OAuth consent includes a send
scope, which is baked at account-creation time.

**A.** "3 — Luoji will send stock ack messages but other notes about
acceptance or needing more information will be drafted and approved by me"

---

## Q3: What exactly may LuoJi send without you?

**Q.** "Stock" is doing load-bearing work. Three categories unaccounted
for: track-leader digests (routine, but generated prose going to people who
act on it); **rejections** (you named acceptance and fix-requests, not
these — the highest-stakes message of the lot); and answers to general
questions (unbounded, from strangers, not coverable by a template).

Sharper version: is the autonomous set a **fixed template with variables
filled in**, or may LuoJi *compose* freely? That is the difference between
a bad generation being a typo and being an incident.

**A.** "regular informational updates such as track digests and updates to
the program committee such as the daily registrtion graphs will be
auto-sent. Answers wot questions about the coference should e auto-sent but
cc'ing me and/or another human to clarify or correct if needed. Rejections
and acceptance notes must be reviewed by humans."

---

## Q4: Where does LuoJi get the facts it answers questions with?

**Q.** Pushed back on one part of the previous answer: CC is an
*after-the-fact* control. By the time you read it, a stranger has the
answer, and "correct if needed" means contradicting yourself to someone who
may have acted. This is also the only unbounded category. The repo's own
principle applies — an automated check that passes teaches you to stop
looking, and a CC you skim 200 times becomes a CC you do not read.

So: if LuoJi answers from an **authoritative source you control**, auto-send
is defensible — it is a lookup with a polite wrapper, and the failure mode
is "did not find it", which is recoverable. If it answers **from the
model**, it will invent a submission deadline eventually.

➡️ Proposed rule: **answer from the source, draft when unsure.** A line in
`SOUL.md` and a document id in config, not new machinery.

**A.** "Proposed rule makes sense"

**Consequence:** a canonical FAQ document is now a hard dependency and does
not exist.

---

## Q5: Who owns the data?

**Q.** Two arrangements. (1) You own everything, LuoJi is granted access —
revoke the shares and it is inert; given the two agents share a Unix user
and can read each other's tokens, that revocability is the only real
containment available. (2) LuoJi owns the working artifacts it creates.

A Google account is a container with a lifetime: anything LuoJi *owns* dies
with the account. Relevant fact: reading form responses requires editor
access, so "share, don't own" still means real write access to the form.

➡️ **(1), you own everything.**

**A.** "I own the Forms and the speadsheets they create - Luoji owns the
artifacts it creates from them."

**Agent's follow-up, accepted without objection:** the track sheets will be
the conference's working record living in an agent's account; track leaders
cannot be given access by the owner, only by LuoJi. A cheap mitigation —
create them inside a folder the owner owns and shares — was raised and left
unadopted.

---

## Q6: What happens to proposals when the conference is over?

**Q.** LuoJi will hold names, addresses, abstracts and verdicts about
people who did not consent to an AI processing them; the scores are the
sensitive part. Does anything need deleting? Do track leaders see the
rubric scores? And is there anything LuoJi should be unable to read — e.g.
if the registration sheet holds attendee PII, does it need all of it, or
only the counts it graphs?

➡️ Ask registration staff for a counts-only sheet. Seven numbers a day does
not require a sheet of attendee records.

**A.** "Luoji will keep the data in a 'TPC27' folder and then in 2028 will
create a TPC28 folder. The folder will be kept indefinitely. This is not a
peer-review process, only a light review that checks for (a) sales pitches
or (b) out-of-scope topics. In 2026 we received 135 proposed talks, 7 were
flagged as sales pitches, 1 was out of scope. All seven pitches were fixed
with one interaction from me to the author, and the out of scope was kindly
rejected."

**What this changed.** Materially lowered the stakes — a screen, not peer
review — and made the human-approval queue ~8 messages a season, so human
review is practical rather than a bottleneck. The registration half of the
question went unanswered and was re-asked.

---

## Q7: What does LuoJi actually get from the registration staff?

**Q.** The graph needs a handful of numbers per day. If the staff sheet is
their working document it may hold names, addresses, payment detail — and
LuoJi would be granted read access to all of it to extract four numbers.
Can you ask for a counts-only tab? Easier now than after they have shared
the working document. Also: does the 2027 sheet even exist yet?

**A.** "There will be a google sheet updated ~daily by the registration
staff, and it will have columns for 2024, 2025, 2026 and 2027. THe first 3
columsn will be filled in all the way from t minus 150 days to 0 days
(start date of event). Each day, the new number will be added for that day
for 2027. Registration has not yet begun - we have 2-3 months unti that
happens."

**Resolution:** counts-only by construction; the PII question does not
arise. Graphing has a dependency on someone else's timeline.

---

## Q8: Is an external binary acceptable for Google access?

**Q.** Research came back unambiguous: OpenClaw ships **no** Google
capability — all ~190 plugins enumerated. Its path is `gog`, now an
OpenClaw-org project, so the repo's prefer-the-vendor rule points at it.
A statically-linked arm64 binary exists and was verified by download; it
does Forms, which Hermes cannot.

➡️ Yes, take it — but flagging the thing that should make you hesitate:
this is **a different mechanism from Gandalf's**, so one add-on would carry
two unrelated implementations indefinitely.

**A.** "Review ../OpenClaw-Tutorial to see how I did Google in the past,
then figure out if this is still the best way to do it. If we can use the
same mechanism that Gandalf uses that would be ideal. Otherwise we have two
addons - google-hermes and google-openclaw (that's fine)"

**Finding from that review:** the owner's earlier tutorial used *two* OAuth
clients — hand-rolled Python for Gmail/Contacts plus `gog` for
Sheets/Drive — and its own notes conceded they "cannot share a single
authorization code". Not a model to copy; evidence of what to avoid. Since
`gog` covers everything including Forms, **one OAuth client** suffices.

---

## Q9: Rename the existing add-on?

**Q.** With a second Google add-on, `addons/google-workspace/` is
misleadingly generic — it sounds general and is Hermes-only.

➡️ Rename to `google-hermes`. Cheap, reversible, `verify.sh` will say
immediately if it broke. The alternative leaves a permanent trap.

**A.** "Agree with the single client improvement. Rename."

---

## Q10: The keyring password has nowhere good to live

**Q.** `gog` requires `GOG_KEYRING_PASSWORD` in the environment of every
process that runs it — verified in source, no file or command indirection
exists. This collides with the repo rule against secrets in config files.
Options: (1) `EnvironmentFile=` at 0600, same as `agents.env`; (2) a
`.gog_pw` file as the old tutorial did; (3) an empty password, which `gog`
treats as valid.

➡️ (1). Rejected (3) despite its honesty: a future reader cannot
distinguish "deliberate" from "broken".

**A.** Implicitly accepted; no objection raised. Recorded in
`addons/google-openclaw/PLAN.md` as the weakest part of that add-on.

---

## Q11: Who schedules the recurring work?

**Q.** Most of LuoJi's job is periodic. Options: OpenClaw's own scheduler
if it has one; a cron job in the VM; or you prompt it. This decides whether
LuoJi acts **while you are asleep** — an agent emailing track leaders on a
schedule is doing unobserved work with real recipients.

**A.** "My reasons for the separate Google account should be clear by now.
I don't want to clutter my personal Google space AND I want the agent to
send messages not from me but from the agent. Re scheduling, OpenClaw has
its own scheduler and we should use it."

**Two decisions in one answer.** The separate-account rationale is
**identity and tidiness, not containment** — which matters, because the
README must not imply isolation the system does not provide.

---

## Q12: How much is the add-on's job, and how much is LuoJi's?

**Q.** The work splits into **plumbing** (install `gog`, OAuth, keyring,
MCP wiring, the scheduler existing, the checks) and **the conference
operation** (rubric, state machine, sheet curation, digest content, FAQ,
graph). The second is configuration of an agent, and by this repo's own
rule belongs to LuoJi — taught by talking to it, since `docs/personality.md`
says the repo ships a seed and never a managed file.

Options: (1) plumbing only; (2) plumbing plus a conference starter kit;
(3) build the conference system properly as a separate layer.

➡️ (1), with (3) as the follow-on. The plumbing is verifiable by script;
the conference logic is only verifiable by running a conference. Shipping
them together means the add-on can never be declared done.

**A.** "Agree, 1 first as that will be useful to people down the line who
want their OpenClaw agent to have Google access. Then once that is done we
can work on my specialized case."

**This document is the start of (3).**

---

## Decisions made outside the grilling, same session

Recorded here because they bear on the conference layer:

- **Gmail scope is `gmail.modify`** — read, draft **and send**. Google
  publishes no draft-but-not-send scope: drafting requires modify, and
  modify permits sending. The owner: *"We need to give Luoji full gmail
  access and rely on instructions and good behavior, which I am
  comfortable doing."* So the approval boundary from Q3 is an instruction,
  not a grant.
- **`contacts` added** to the service list when the owner asked for contact
  management. Costs three scopes including full read/write and
  `directory.readonly`; no read-only variant exists on `gog`'s path.
- **The two agents share a Unix user** and can read each other's
  credentials. Mitigated by a line in each `SOUL.md`; the real fix (second
  Unix user or VM) was costed and deferred — see `todo.md` §4. the owner:
  *"I want to keep it simple - let's rely on SOUL.md behavior. The stakes
  here are not very high."*

---

## What was never asked

Gaps in the grilling itself, listed so the next session can close them
rather than assume they were considered:

1. The rubric's actual criteria.
2. Who moves a proposal between states, and whether LuoJi ever does so
   unprompted.
3. Whether track leaders see rubric verdicts or only status.
4. Digest cadence — "regularly" was never pinned down.
5. Who writes the FAQ document, and where it lives.
6. Who the "other human" on the Q&A CC is.
7. Any retention or deletion policy for proposal data.
8. What happens to a proposal that arrives after the deadline, or twice.
9. Whether LuoJi ever talks to track leaders *interactively*, or only
   broadcasts to them.
