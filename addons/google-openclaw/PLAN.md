# Google for the OpenClaw agent — the plan

**Status: planned, not built. Nothing in this directory has run, and the VM
was not touched.** Written 2026-11-11 from vendor documentation, a grilling
session with the repo owner, and the host-side measurements below.

Read this before `README.md`. The README is written as if the add-on works;
this file is why it should, what was decided and why, and where it could go
wrong.

## If you read only this box

- **OpenClaw ships no Google capability.** Not a plugin, not bundled — an
  agent enumerated all ~190 plugins in its docs. Its path to Google is an
  external CLI, **`gog`** (gogcli), which is now an OpenClaw-org project.
- **So this cannot reuse the Hermes add-on.** Gandalf's Google access *is*
  a Hermes feature (a bundled skill running inside Hermes). There is
  nothing for OpenClaw to call. Two add-ons, deliberately.
- **`gog` does Forms; Hermes cannot.** The capability that motivated this
  work is only available on this path.
- **arm64 is fine** — a statically-linked aarch64 binary exists, verified
  by download. No Homebrew, no Go toolchain, no glibc dependency.
- **The weak spot is the keyring**: `gog` needs its password in the
  process environment, with no file or command indirection. This is a
  worse secret story than the Hermes add-on and the README must say so.
- **Scope is plumbing only.** Google reachable, scheduler working, checks
  passing. The conference operation LuoJi is being built for is a separate
  piece of work, taught to the agent rather than installed.

---

## What was measured, and what is taken on trust

### Measured on this host

| Claim | How |
|---|---|
| gogcli v0.48.0 is current (2026-11-05) | GitHub releases API |
| A **linux_arm64** asset exists | release asset list |
| Its published SHA256 is correct | downloaded 13.5 MB tarball, `sha256sum` matched `fc405243…9b68` |
| The binary is genuinely aarch64 | `file` → `ELF 64-bit LSB executable, ARM aarch64 … statically linked` |
| It needs no glibc | `ldd` → `not a dynamic executable` |
| The inner binary matches the vendor's own inventory | `sha256sum` → `1137f6e9…620c`, equal to `ASSET-INVENTORY.json` |
| The repo is live and MIT-licensed | GitHub API: `MIT`, not archived, pushed 2026-11-05 |
| The rename of the Hermes add-on broke nothing | `addon-google-hermes.sh verify` → 28 passed, 0 failed |

The arm64 check matters because the Signal add-on hit exactly this wall
(upstream signal-cli publishes no aarch64 build). Here there was no wall —
but it was checked rather than assumed, and the binary was **not executed**,
only inspected.

### Taken from vendor documentation, not yet observed

Everything about `gog`'s runtime behaviour: the keyring, the split consent
flow, the MCP server, and OpenClaw's scheduler semantics. Treat the first
build as the measurement.

### One thing already known to be wrong elsewhere

The repo owner's earlier `OpenClaw-Tutorial` used **two** OAuth clients —
a hand-rolled Python path for Gmail/Contacts and `gog` for Sheets/Drive —
and its own notes concede they *"cannot share a single authorization code.
A combined renewal script handles both in one session."* That split is not
reproduced here: `gog` covers Gmail, Calendar, Drive, Docs, Sheets **and**
Forms, so **one OAuth client** serves everything. Decided during grilling.

---

## Why this is a second add-on rather than a flag on the first

The obvious request — "make the Google add-on take an `--agent` flag" — was
considered and rejected, on evidence rather than taste.

| | `google-hermes` | `google-openclaw` |
|---|---|---|
| Mechanism | Hermes' **bundled skill** | **`gog` binary** + its MCP server |
| Lives | inside Hermes' Python env | `/usr/local/bin`, called over MCP |
| Credentials | `~/.hermes/*.json`, 0600 | encrypted keyring + password in env |
| Consent | our `auth/google-oauth.py`, host-side | `gog auth add --remote --step 1/2`, **in the VM** |
| Forms | **not supported** | **supported** |
| Verified by | `setup.py --check-live` | `gog auth doctor --check` parsed with `jq` |

Four of five rows differ. A single add-on would be a switch statement from
top to bottom with almost no shared body. The Signal add-on's `SIGNAL_AGENT`
pattern does not transfer, because there both agents genuinely shared one
daemon; here they share nothing but the Cloud Console walkthrough.

What *is* shared is documentation — creating a project, enabling APIs, and
the "publish the consent screen or refresh tokens die after 7 days" warning.
Shared by reference, not by code.

**`addons/google-workspace/` was renamed to `addons/google-hermes/`**
(commit `81a9097`) so the pair is symmetric and neither name implies
generality. Host-side only; the running agent was unaffected.

---

## What LuoJi is for, and why that shapes the scope

From the grilling, recorded because it explains decisions below: LuoJi is a
**conference-operations assistant** for TPC27 — watching a proposals form,
light-screening abstracts for sales pitches and out-of-scope topics,
curating per-track sheets, tracking proposal status, emailing track leaders,
and graphing registration against prior years.

Two facts from that discussion change the design:

**It emails real people.** Authors who submit, and strangers asking
questions. This is categorically different from Gandalf, which reads the
owner's mail and talks to the owner. An agent with shell access and a
send-capable mailbox pointed at conference attendees is the
highest-consequence thing in this repo.

**The owner set the boundary himself**, and it maps onto scopes:

| Traffic | Handling |
|---|---|
| Stock acknowledgements, track-leader digests, registration graphs | auto-sent |
| Answers to general questions | auto-sent, CC a human |
| **Acceptances, rejections, fix-requests** | **drafted, human approves** |

Plus a rule agreed during grilling: **answer from a canonical source, draft
when unsure.** LuoJi gets a FAQ document and may not improvise event facts.
That is a line in its `SOUL.md` and a document id in its config — not
machinery, and not this add-on's job.

**None of this is installed by the add-on.** Scope is plumbing; the
conference operation is configuration of an agent, and by this repo's own
rule (`docs/personality.md`) that belongs to the agent and its user. The
add-on ends at "LuoJi can reach Google and the scheduler works."

The sequencing argument for that split: the plumbing is verifiable with a
script, the conference logic is only verifiable by running a conference. Ship
them together and the add-on can never be declared done.

---

## Scopes: start narrow, and one real constraint

`gog` takes per-service scopes at `auth add` time, with `--readonly` and
`--gmail-scope send|read-send` available to narrow them.

Proposed starting set, from the duties above:

| Service | Scope | Why |
|---|---|---|
| Gmail | `gmail.modify` | read, label, **and create drafts**. Google refuses permanent deletion under `modify` — its rule, not ours |
| Calendar | `calendar` | its own calendar |
| Sheets | `spreadsheets` | track sheets are the job |
| Docs | `documents` | drafting from proposals |
| Drive | `drive` | required by `gog` for docs/sheets |
| Forms | `forms.body` + `forms.responses.readonly` | reading responses |

Three things the owner should know before consenting:

**Gmail `send` is deliberately omitted from the first consent.** Drafts need
only `modify`. Auto-sent acknowledgements *will* need send eventually, and
adding it is a re-consent — but starting without it means the first live
test cannot accidentally email a speaker. Widening later is one command.

**`forms.body` is a write scope.** Google publishes no read-only path that
`gog` uses for Forms, so "read the responses" brings "edit the form" with
it. Unavoidable; worth stating rather than discovering.

**Form enumeration would force a much larger grant.** There is no
`forms.list` method — the Forms API cannot list a user's forms. Discovery
requires Drive `files.list` with a `mimeType` filter, and the usable Drive
scopes for that are **Restricted**, needing Google verification. The design
consequence: **do not enumerate.** Store the form id in config; it is
visible in the form's own URL. This keeps the grant small and is the single
decision that avoids a verification review.

### The matching fact about reading responses

Polling beats push here, and not as a compromise. Google's watch mechanism
delivers only to Cloud Pub/Sub, needs a billed Cloud project, expires
weekly, and carries no data — you still call `responses.list` afterwards.
Meanwhile `forms.responses.list` supports a filter, verbatim from the
discovery document: *"`timestamp > N` which means to get all form responses
submitted after (but not at) timestamp N"*, RFC3339 Zulu. Google's own
suggested usage for watches collapses to the same call.

Quota is generous: `responses.list` is an *expensive read* at **180/min per
user**, against a poll every few minutes.

---

## Deployment shape

### Install

Download the pinned release tarball, verify SHA256, extract, install to
`/usr/local/bin/gog`. Fits the repo's *download, checksum, then execute —
never pipe* rule exactly. Pin both the tarball digest and the inner binary
digest; the vendor publishes both.

### Consent — in the VM, not on the host

This differs from the Hermes add-on and the difference is forced.
`gog auth add --remote --step 1` writes PKCE state to disk at
`$ConfigDir/oauth-manual-state-<state>.json` with a **10-minute TTL**, and
step 2 reads it back. The docs are explicit that both steps need *"the same
`gog` home and client"*. So:

- **step 1 and step 2 both run in the VM**;
- only the **consent URL** crosses to the host, for the owner to open in a
  browser;
- the browser lands on a `127.0.0.1` URL that fails to load — expected,
  nothing listens — and the owner copies that whole redirect URL back.

Neither step opens a listener. The 10-minute TTL is the real constraint on
the hand-off, and the installer must say so.

**This conflicts with a standing user constraint and needs a decision.** The
owner cannot copy text out of his terminal (`~/.claude` memory, and the
Signal add-on solved the same problem with a QR code). Here, two long
strings must cross: a consent URL out, and a redirect URL back. A QR solves
the outbound leg. The inbound leg — a ~400-character redirect URL typed by
hand — is not acceptable. **Options, for the owner to choose:**

1. **Write both to files.** The installer writes the consent URL to a file
   he opens in an editor and copies from there; he pastes the redirect URL
   into a second file the installer reads. No terminal copying either way.
   Ugly, works, consistent with "write the file yourself".
2. **`--redirect-uri` with a stable value**, registered in the Cloud
   console, pointing at something that captures the code. Needs a listener
   somewhere; the VM has no inbound reachability, so this means the host.
3. **Do the consent on the host** with `gog` installed there too, then copy
   the keyring into the VM. Rejected unless nothing else works: it puts
   Google credentials on the host, which the Hermes add-on deliberately
   avoids, and the keyring is explicitly single-writer.

Recommendation: **(1)**. It is the least clever and the most likely to work
first time.

### Runtime — MCP, not shell exec

`gog mcp` exposes typed tools (`gmail_search`, `docs_get`,
`sheets_read_range`) and is *"read-only by default; writes require explicit
command and tool authorization"*, explicitly *"without a generic shell or
command bridge"*. Writes need `--allow-write`, Gmail send needs
`--allow-gmail-send`.

Preferred over shell-exec for three reasons: read-only default is the right
starting posture; it gives per-agent credentials at the server, which is
what OpenClaw's own security guidance recommends; and the exec path has a
trap — OpenClaw's approval system *"cannot bind pipelines, command
substitutions, subshells, write redirections"* and denies them outright,
while `gog`'s documented examples are pipe-heavy.

**Is this a reversal of the Hermes MCP→skill decision?** No, and the
distinction is worth stating because it looks like one. That decision was
*"use the vendor's own path instead of a third-party MCP server."* Here the
vendor's own path **is** `gog`, and `gog mcp` is simply its typed interface.
Choosing shell-exec instead would not be more "native" — it would be the
same binary with worse ergonomics and a weaker safety posture.

### The keyring — the weakest part of this add-on

`gog` stores tokens in an encrypted keyring. Headless, that requires
`GOG_KEYRING_BACKEND=file` plus `GOG_KEYRING_PASSWORD` **in the environment
of every process that runs `gog`**. Verified in the source by a research
agent: there is no `--password-file`, no password-command, no indirection of
any kind — env var or an interactive TTY prompt, nothing else. The MCP
server re-opens the keyring **per call** in subprocesses, so the variable
must be inherited, not unlocked once.

Decided: **`EnvironmentFile=` on the systemd unit, 0600**, same pattern as
`agents.env`. It keeps the value out of the unit file and out of
`systemctl show`, and `verify.sh` can assert the mode.

Three things to be honest about in the README rather than gloss:

- **This is weaker than the Hermes add-on**, where the token sits at 0600
  and no password lives in any process environment.
- The encryption buys little here. The password file sits on the same disk,
  readable by the same user, as the keyring it unlocks.
- `gog` treats an **empty** password as valid and intentional (`auth doctor`
  warns rather than errors). Rejected: a future reader cannot distinguish
  "deliberate" from "broken", and the repo's standard is that every setting
  is either chosen or its default examined.

### Isolation: what the second Google account does and does not buy

The owner's reasons, stated during grilling: **no clutter in his personal
Google space, and mail that comes from the agent rather than from him.**
Identity and tidiness — explicitly *not* containment.

The README must say that plainly, because a reader will assume otherwise.
Both agents run as the **same Unix user** in one VM. OpenClaw's own docs:
skill allowlists *"are not a shell-time authorization boundary… If an agent
can run host `exec`, that shell can still run external clients or read host
files that are visible to the execution user."* So LuoJi can read Gandalf's
`~/.hermes/google_token.json`, and Gandalf can read LuoJi's keyring and its
password file.

What separate accounts *do* buy, and these are real: a distinct sending
identity, separate quotas, a clean audit trail, and independent revocation.

Real containment would need a second Unix user in the VM or a second VM —
a change to the base build, not to an add-on. **Belongs in `todo.md`**, not
quietly implied here.

---

## Scheduling

OpenClaw has its own scheduler ("Automations", config key `cron`,
CLI `openclaw automations`), and the owner chose it over system cron. Jobs
live in SQLite, not a config file.

Four findings that should shape the spec rather than be rediscovered:

**`skipMissedJobs` defaults to `false`.** On startup, overdue recurring
slots are caught up. This is the same failure class Hermes needed
`cron.catch_up_missed: false` for — after a VM suspend, every missed slot
fires. OpenClaw is gentler (one overdue occurrence per job, staggered,
deferred two minutes) but the default is still "replay". **Set it to
`true`** and say why.

**Timezone must be explicit.** *"Cron expressions without `--tz` use the
Gateway host timezone"* and `--at` schedules without a zone are **UTC**.
The base build already sets an agent timezone for exactly this class of bug
(a calendar event landed on the wrong day). Always pass `--tz`.

**Gate the poll, not the digest.** A `--trigger-script` returning
`fire: false` skips the payload *and its model call* on quiet ticks — the
right shape for polling a form that is usually unchanged. But the vendor is
explicit the opposite way for reports: *"Do not use a change-only gate for
an explicitly requested recurring report or digest: that job should deliver
at its requested cadence even if the observations are unchanged."*

**Top-of-hour jobs are auto-jittered** up to 5 minutes unless `--exact`.
Harmless for a daily graph; worth knowing before someone debugs it.

These are notes for the *conference* layer, not the add-on. The add-on's
only scheduler responsibility is proving the scheduler runs at all.

---

## Checks worth having

Against `AGENTS.md`'s four questions. Each traces to a named failure.

| Check | Catches |
|---|---|
| `gog --version` runs | wrong architecture — the thing that killed the Signal add-on's first design |
| `gog auth doctor --check` parsed with `jq`, never exit code | the vendor documents the trap: it *"exits successfully when it emits a diagnostic report, even if that report has failed checks"* |
| keyring directory is 0700, password file 0600 | the add-on's weakest surface |
| no Google credential in any OpenClaw config file | the shape the base suite already checks for bot tokens |
| MCP server registered **and reachable** | OpenClaw's own words: *"Saving a definition proves nothing about reachability — the check does"* (`openclaw mcp doctor <name> --probe`) |
| Gmail **send** is not granted unless asked for | the one scope that can email a stranger |
| the scheduler is alive (`openclaw automations status`) | a silent scheduler means every duty silently stops |
| no Google domain added to the allowlist | an add-on widening egress by the back door |
| `openclaw doctor --lint --all --json`, and `hermes doctor` | required after any add-on; `--lint --all` is not optional (39 of 69 checks otherwise) |
| a live Google call (`--live`) | everything above passes with a dead token |

**Deliberately not written:** whether the agent *uses* Google when asked —
left to the human, like the Telegram check, for the reason `AGENTS.md`
gives. And nothing asserting `gog`'s output wording.

One existing check **must change**: `addons/google-hermes/verify.sh` asserts
`OpenClaw has NO Google access` and fails if `openclaw.json` mentions
google. Correct when written, wrong the day this ships. It should become
"OpenClaw has no access to *Hermes'* Google account" — still a real
assertion, since the two accounts are meant to be distinct.

---

## Risks, honestly

1. **A second Google integration to maintain.** Two add-ons, two
   mechanisms, two renewal paths. Mitigated only by their being genuinely
   different products; unavoidable given OpenClaw ships nothing.
2. **The keyring password in a process environment.** Weaker than the
   Hermes side. No vendor fix available.
3. **`gog` is young and moves fast** — v0.48.0, pushed the day before this
   was written. Pin the version and the digest; expect to bump it.
4. **The consent hand-off is clumsy** and conflicts with the owner's
   no-copy-paste constraint. Unresolved; options above.
5. **An agent that can email the public.** Not a plumbing risk, but the
   add-on creates the capability, so the README should carry the warning
   even though the policy lives with the agent.

## Deliberately deferred

- **The conference layer** — rubric, state machine, track sheets, digests,
  FAQ source, registration graph. Taught to LuoJi, not installed.
- **Gmail send scope** — added on request, after drafts are proven.
- **Contacts** — `gog` supports it; no stated need.
- **Real isolation between the two agents** — `todo.md`, not here.

## Open questions

1. **How should the consent hand-off work?** Options above; I recommend
   writing both URLs to files.
2. **Confirm the scope list**, particularly that Gmail starts without
   `send`.
3. **Is a third-party binary from an OpenClaw-org repo acceptable?** MIT,
   statically linked, digest-pinned, verified by hand. I would take it;
   there is no alternative that reaches Forms.
