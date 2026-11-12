# Conference operations for LuoJi — what it must do

**Status: specified, not built.** This is the requirement, not the design.
`PLAN.md` beside it is the design.

**Provenance matters here.** Everything in *Settled* came out of a grilling
session with the owner on 2026-11-11, before any of it was built — his
decisions, in response to being pushed on them. It is not a summary of a
conversation and it is not an agent's inference. Where something was
*not* decided, it is in *Open* rather than quietly filled in.

**`GRILLING.md` beside this file is the full record** — every question as
asked, the recommendation offered, and the owner's answer verbatim. This
file is the distillation; that one is the evidence. If they ever
disagree, `GRILLING.md` is right and this is the error.

The rule for whoever picks this up: **do not re-derive the settled items,
and do not invent answers to the open ones.** Ask.

---

## The job

LuoJi is a **conference-operations assistant for TPC27**. Not "an agent
with Google access" — that is the plumbing, and it is done
(`addons/google-openclaw/`).

Its duties, as stated:

1. **Watch the proposals form** for new talk submissions.
2. **Screen each abstract** against a rubric the owner provides.
3. **Respond to authors** who submit.
4. **Answer general questions** about the event.
5. **Curate per-track spreadsheets**, splitting proposals by the track the
   author chose, so each track leader has a sheet showing only their own.
6. **Maintain an inventory** of all proposed talks and their status —
   reviewed, accepted, rejected, fix-requested.
7. **Email track leaders** regularly with updates on their tracks.
8. **Graph registration**: compare 2027 against 2024/2025/2026, normalised
   by days-before-event, as a line graph generated daily.

### Scale, measured not guessed

From TPC26: **135 proposed talks**, of which **7 were flagged as sales
pitches** and **1 as out of scope**. All seven pitches were resolved with a
single interaction between the owner and the author; the out-of-scope one was
declined politely.

Two consequences that shape everything:

- **This is a light screen, not peer review.** The rubric checks for (a)
  sales pitches and (b) out-of-scope topics. Nothing else.
- **The human-approval queue is tiny** — on last year's numbers, about
  eight messages across a season. Human review of every sensitive message
  is therefore entirely practical, not a bottleneck. Do not design around
  avoiding it.

---

## Settled

### The email boundary

The most consequential decision, and the one most likely to be eroded by a
later "simplification". LuoJi emails real people — authors who submit, and
strangers who ask questions.

| Traffic | Handling |
|---|---|
| Stock acknowledgement of a received proposal | **auto-send** |
| Track-leader digests | **auto-send** |
| Registration graphs to the programme committee | **auto-send** |
| Answers to general questions about the event | **auto-send, CC a human** |
| **Acceptances** | **draft only — human sends** |
| **Rejections** | **draft only — human sends** |
| **Requests for changes to a proposal** | **draft only — human sends** |

The owner's framing: *"regular informational updates such as track digests
and updates to the program committee such as the daily registration graphs
will be auto-sent. Answers to questions about the conference should be
auto-sent but cc'ing me and/or another human to clarify or correct if
needed. Rejections and acceptance notes must be reviewed by humans."*

### Answer from the source, draft when unsure

Agreed as a rule after being raised as a risk: auto-answering strangers
means the model will eventually invent a deadline, a fee, or a policy in
the conference's own voice, and a CC is an *after-the-fact* control.

**LuoJi answers questions only from a canonical FAQ document.** If the
answer is not in it, LuoJi does not infer one — it drafts a reply for a
human and says what it could not confirm.

**The FAQ document does not exist yet.** This is a hard dependency: the
rule is worthless without it, and an agent told to answer only from a
source it does not have will either refuse everything or improvise.

### Data ownership

- **The owner owns** the Forms and the response spreadsheets they generate.
- **LuoJi owns** the artifacts it derives from them — track sheets, the
  status inventory.
- Derived artifacts live in a **`TPC27` folder**, with a `TPC28` folder to
  be created in 2028. **Kept indefinitely.**

A consequence raised and accepted: artifacts LuoJi owns live in an account
that exists to run an agent. If that account is lost, they go with it, and
track leaders cannot be granted access by the owner — only by LuoJi. A
mitigation exists and was not adopted: create them inside a folder the owner
owns and shares, so the container has a durable owner.

### Registration data

- A Google Sheet maintained **~daily by registration staff**.
- Columns for **2024, 2025, 2026, 2027**; rows from **t-150 days to t-0**.
- The first three columns are complete; 2027 is filled in a day at a time.
- **Registration had not opened** as of 2026-11-11 — expect 2–3 months.

This is already counts-only by construction, so the exposure question
(attendee PII) does not arise. The graphing work has a hard dependency on
someone else's timeline.

### The separate Google account

The agent's own account, consented 2026-11-12 (the address is in
`config/openclaw-google.env`, which is gitignored). The owner's reasons, verbatim
in substance: **no clutter in his personal Google space**, and **mail that
comes from the agent rather than from him**.

**Explicitly not containment.** Both agents run as one Unix user and can
read each other's credentials. Do not describe this as isolation.

### Gmail scope

LuoJi holds `gmail.modify` — read, draft, **and send**. Google publishes no
draft-but-cannot-send scope, so the approval boundary above **cannot be
enforced by the grant**. It is an instruction in LuoJi's `SOUL.md` or it is
nothing. Accepted knowingly.

---

## Open — ask, do not invent

These never came up, or came up and were deferred:

1. **The rubric itself.** The owner provides it. What are the actual
   criteria for "sales pitch" and "out of scope", in words an agent can
   apply consistently?
2. **Proposal state transitions.** The states are known (reviewed,
   accepted, rejected, fix-requested). Who moves a proposal between them,
   and does LuoJi ever do so unprompted?
3. **What track leaders see.** The proposals and their status — but also
   the rubric verdicts? These are judgements about named people.
4. **Digest cadence.** "Regularly" was never pinned to a schedule.
5. **The FAQ document** — who writes it, where it lives, and how LuoJi is
   told its id.
6. **Who the second human is.** The Q&A tier says "CC me and/or another
   human".
7. **Retention of personal data.** The inventory is kept indefinitely and
   contains names, addresses, abstracts, and verdicts. No deletion policy
   was set; none may be needed, but it was never decided.
8. **Where track sheets live** — the unadopted mitigation above.

---

## Things already true that constrain the build

- **The plumbing is done.** `gog` as an MCP server, consented, verified.
  Services: gmail, calendar, drive, docs, sheets, forms, contacts.
- **Forms ids must be listed in config, never discovered.** The Forms API
  has no "list my forms" call, and Drive-based discovery needs a
  Restricted scope requiring Google verification. `GOOGLE_FORM_IDS` in
  `config/openclaw-google.env`.
- **Reading responses means polling, not push.** Google's watch mechanism
  needs a billed Pub/Sub project and expires weekly;
  `forms.responses.list` supports a `timestamp > N` filter, and quota is
  180 requests/minute/user.
- **Scheduling is OpenClaw's own** ("automations"). Chosen over system
  cron. Three findings that will otherwise be rediscovered:
  - always pass `--tz`; without it, cron expressions use the host
    timezone and `--at` schedules are UTC;
  - **gate the poll, not the digest** — a `--trigger-script` returning
    `fire: false` skips the model call on quiet ticks, but the vendor is
    explicit that a requested recurring report should deliver at its
    cadence regardless;
  - top-of-hour jobs are auto-jittered up to 5 minutes unless `--exact`.
- **`cron.skipMissedJobs` is set true**, so a suspend does not replay a
  burst of stale messages.

## Where this is not

**This is not an add-on in the installable sense.** The other three
directories here install software. This one describes what one agent
should do, and most of it belongs in LuoJi's own skills, `SOUL.md` and
memory — which the agent owns and edits by being asked
(`docs/personality.md`). The repo ships seeds, never managed files.

What *may* belong in the repo: the seed text, a checkable list of what
should exist, and this specification. See `PLAN.md`.
