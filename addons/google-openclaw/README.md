# Google for the OpenClaw agent

An **optional add-on**. The base build does not need it, does not know
about it, and is not modified by it. The Hermes agent is untouched.

It gives the **OpenClaw agent only** access to one Google account's Gmail,
Calendar, Drive, Docs, Sheets and **Forms**, on an account of its own.

> **NOT YET BUILT.** This directory is a plan and its scaffolding. No part
> of it has been run and the VM has not been touched. Read `PLAN.md` first
> — it records what was measured, what came from vendor documentation, and
> what is still unknown. This file is written as if the add-on works,
> which it has never been observed to do.

> **Build the base system first.** Follow the repo's top-level `README.md`
> and come back when `./verify/verify.sh` reports no failures. If the base
> is not finished and verifying, `install` below refuses to run.

## This is not the Hermes add-on with a switch

There are two Google add-ons and they share almost nothing:

| | `google-hermes` | `google-openclaw` (this one) |
|---|---|---|
| Serves | the Hermes agent | the OpenClaw agent |
| Mechanism | Hermes' own **bundled skill** | **`gog`**, a CLI from the OpenClaw project |
| Credentials | files under `~/.hermes/` | an encrypted keyring |
| Consent | on your machine | **inside the VM** |
| Forms | not supported | **supported** |

The reason is not arbitrary. Hermes ships Google support as a feature of
Hermes; there is nothing in it for another agent to call. OpenClaw ships no
Google support at all, and its documented path is `gog`. Two products, two
mechanisms. Forcing one add-on to serve both would be a switch statement
from top to bottom.

If you want Google for **Hermes**, you are in the wrong directory — see
`addons/google-hermes/`.

## What a separate account does and does not buy you

Use a **dedicated Google account** for the agent. Two real benefits: the
agent's files stay out of your personal Drive, and mail it sends comes from
the agent rather than from you.

**It does not isolate the two agents from each other.** Both run as the
same user inside one VM, so each can read the other's credentials off the
filesystem. OpenClaw's own documentation is blunt about this: an agent that
can run shell commands *"can still run external clients or read host files
that are visible to the execution user."*

What separate accounts give you is a separate identity, separate quotas, a
clean audit trail, and the ability to revoke one without touching the
other. Real containment would need a second Unix user or a second VM —
that is a change to the base build, not to an add-on, and it is recorded in
`todo.md`.

## Your part, then your agent's

Steps 1–4 are yours, because they need a browser, an account and a
decision only you can make. Step 4 ends by handing over. Step 6 is the one
check at the end that no script can do.

Budget about twenty minutes, nearly all of it in the Google Cloud Console.
It is one-off.

### 1. Make the agent a Google account

Create a new Google account for the agent, at
<https://accounts.google.com/signup>. Give it a display name you are happy
for people to see — if it emails anyone, this is the name they will read.

Keep the password somewhere sensible. You will not need it again after
setup, but losing it means losing anything the agent created.

### 2. Make an OAuth client, signed in as that account

At <https://console.cloud.google.com/>, **signed in as the agent's
account**, not yours:

1. Create a project.
2. Enable the APIs the agent needs, in **APIs & Services → Library**.

   **Match on the service name, not the title.** Several titles are one
   search result away from a different product, and the service name —
   the `*.googleapis.com` string on each API's detail page — is unique.
   If a title looks close, click into it and check that string before
   pressing Enable.

   | `GOOGLE_SERVICES` entry | Enable the API titled | **Service name (the identifier)** | Easy to confuse with |
   |---|---|---|---|
   | `gmail` | **Gmail API** | `gmail.googleapis.com` | Gmail MCP API; Gmail Postmaster Tools API |
   | `calendar` | **Google Calendar API** | `calendar-json.googleapis.com` | Calendar MCP API; CalDAV API |
   | `drive` | **Google Drive API** | `drive.googleapis.com` | Drive Activity API; Drive Labels API |
   | `docs` | **Google Docs API** | `docs.googleapis.com` | Docs MCP API |
   | `sheets` | **Google Sheets API** | `sheets.googleapis.com` | Sheets MCP API |
   | `forms` | **Google Forms API** | `forms.googleapis.com` | Forms MCP API |
   | `contacts` | **People API** | `people.googleapis.com` | Contacts API (retired) |

   Two notes that have each cost someone an afternoon:

   - **Calendar's service name really is `calendar-json.googleapis.com`.**
     The `-json` is historical and this is the current v3 API. It is
     **not** CalDAV, which is a different protocol `gog` does not use. If
     a search for "Calendar" only offers you *Calendar MCP API*, search
     the full phrase `Google Calendar API`.
   - **The "MCP API" entries are a different Google product** — hosted
     Model Context Protocol endpoints. Enabling one does nothing here;
     `gog` speaks to the classic REST APIs.

   `docs` and `sheets` both need **Drive** enabled as well, which is why
   `drive` is in the default `GOOGLE_SERVICES` even though the agent is
   not being given Drive as a feature.

   Enable only what you listed in `GOOGLE_SERVICES`. Every entry there
   maps to exactly one row above; `gog`'s own README is the source for
   that mapping, and the service names were read from Google's discovery
   API rather than transcribed.
3. Configure the consent screen (**APIs & Services → OAuth consent
   screen**, filed under **Google Auth Platform → Branding / Audience** in
   newer layouts). User type **External**, any app name, the agent's
   address in both contact fields.
4. **Publish it**, and expect one hurdle.

   Under **Audience**, the publishing status starts at **Testing**. Press
   **Publish app** so it reads **In production**. This matters more than
   it looks: under Testing, Google expires refresh tokens after **seven
   days**, so the add-on would quietly stop working every week with
   `invalid_grant` buried in a log.

   **The button is greyed out until Branding has an App domain.** An
   external app in production needs three links — application home page,
   privacy policy, terms of service — plus the domain listed under
   *Authorised domains*. Google's wording: *"These links are required for
   all external production apps."*

   Measured 2026-11-11: the URLs are **not fetched** when you publish, so
   pages that do not exist yet are accepted. The domain does have to be
   one you own and have verified. If you have no domain at all, staying
   in Testing is defensible — it just means re-consenting every seven
   days, deliberately rather than by surprise.

   The logo stays empty. It is optional, and a custom logo is one of the
   things that pushes an app into Google's verification review, which a
   single-account app does not otherwise need.
5. **Credentials → Create credentials → OAuth client ID**, type **Desktop
   app**. Press the **download icon** beside the new client and put the
   file in `secrets/`. That directory is gitignored, and nothing is
   retyped.

   **Leave the "Use this client for an AI-powered agent" box
   unchecked.** Its own help text says to tick it *"if your client uses
   Google MCP tools"* — `gog` does not; it calls the classic REST APIs
   you enabled above. The label misleads here, because the agent *is* an
   AI agent; the setting describes the API surface, not the caller.
   Google's accompanying advice to *"use separate OAuth clients for
   each"* implies the flag changes how the client is treated, so the
   plain Desktop client is the known-good configuration — it is what the
   Hermes add-on uses against the same APIs today.

   **If you run both Google add-ons, rename the file.** The two clients
   arrive with near-identical names and you will not be able to tell
   them apart later:

   ```
   secrets/client_secret_<agent>-<vendor>-<project-number>.json
   ```

   Keep the `client_secret_` prefix and the `.json` suffix — both
   installers glob on those — and put whatever you like in between. The
   installer does not trust the name anyway: it identifies the *other*
   agent's client by the id inside the file, so a rename cannot cause it
   to pick the wrong one.

   There is nothing to configure for the redirect. Desktop clients accept
   any loopback port by specification, which is what the consent step
   relies on.

### 3. Fill in the config

```sh
./scripts/addon-google-openclaw.sh auth
```

The first run creates `config/openclaw-google.env`, tells you what it
wants, and stops. Fill in:

| Setting | What |
|---|---|
| `GOOGLE_ACCOUNT` | the agent's address, from step 1 |
| `GOOGLE_SERVICES` | which services it may touch — start narrow |
| `GOOGLE_ALLOW_SEND` | leave at `no` unless you are sure |

**On `GOOGLE_ALLOW_SEND`:** with `no` the agent can read mail and write
drafts for you to approve and send; it cannot put mail in front of a real
person by itself. Turning it on later is a one-minute re-consent. If this
agent talks to anyone but you, think about it properly — a wrong message
cannot be unsent, and the model will be confidently wrong occasionally.

**On Forms:** Google publishes no read-only path that `gog` uses, so asking
for Forms grants a scope that can **edit** your forms, not merely read
their responses. Unavoidable, and better known now.

### 4. Consent, then hand over

Run the same command again:

```sh
./scripts/addon-google-openclaw.sh auth
```

It installs `gog` into the VM (a few minutes, ~13 MB), then starts a
two-part handshake:

1. It writes the consent URL to
   `config/.openclaw-google-consent-url.txt`. Open that file, copy the URL
   into a browser, and approve — **signed in as the agent's account**.
2. Your browser lands on a `127.0.0.1` address and fails to load. **That
   is expected**; nothing is listening there. What matters is the URL in
   the address bar.
3. Save that whole failed URL into
   `config/.openclaw-google-redirect-url.txt`, then run the command once
   more.

The URLs go through files rather than the terminal because they are
several hundred characters long and nobody should be retyping them.

**There is a ten-minute timer** on the handshake — `gog` keeps PKCE state
on disk with that TTL. Do not start it and walk away. If it expires, re-run
for a fresh URL; nothing is damaged.

Then:

```sh
./scripts/addon-google-openclaw.sh install
```

This checks the base build is healthy, pushes config into the VM, and
stages the spec Pi will work from. It takes 3–6 minutes, almost all of it
re-running the base `verify.sh`, and prints a log path you can `tail -f`.

**It stops at the hand-over rather than running into the build.** Open your
coding agent in this directory and tell it:

> Install the OpenClaw Google add-on: run
> `./scripts/addon-google-openclaw.sh build`, then supervise Pi and verify
> it as `addons/google-openclaw/README.md` describes.

### 5. Wait

Your coding agent drives Pi for 5–15 minutes, then checks the result.

### 6. The check nothing automated covers

When the agent reports it is done, **ask the OpenClaw agent to read
something from Google** — what is on its calendar, or a row from a sheet.

This one is yours. Every automated check here can pass while the agent
never reaches for the tool: on 2026-11-08 an agent asked for a calendar
picked an unrelated tool from another catalogue and never called Google at
all, with every configuration check green.

---

# Installing it — for the coding agent

The human has done steps 1–4: `gog` is installed and authenticated in the
VM, config is pushed, and the spec is staged at
`~/agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md`. Your job is the build and the
reading of it.

```sh
./scripts/addon-google-openclaw.sh build          # drive Pi (5-15 min)
./scripts/pi-session.sh summary                   # what Pi claims it did
./scripts/pi-session.sh steps                     # what it actually did
./scripts/addon-google-openclaw.sh verify --live --base
```

`build` refuses if the spec or the authentication is missing rather than
starting a turn that cannot succeed. Supervise Pi exactly as `AGENTS.md`
describes: the summary is a claim, `verify.sh` is the evidence, and
`pi-session.sh say` is how you push back.

Pi's deliverable is `~/agent-bootstrap/setup-openclaw-google.sh` — a third
standalone idempotent script, never `setup.sh` and never the Hermes
add-on's `setup-google.sh`.

## What to watch for specifically

**The keyring environment.** `gog` will not unlock its keyring without
`GOG_KEYRING_BACKEND=file`, `GOG_KEYRING_PASSWORD` and
`DBUS_SESSION_BUS_ADDRESS=disabled:` **in the environment of the process
that runs it**. The MCP server re-opens the keyring per call in
subprocesses, so these must be inherited, not set once. The vendor's own
warning is worth remembering: *"A command working in your login shell only
proves that shell has the password."* Symptom is "no auth," which reads
like a credential problem and is not.

**`managed` vs `external`.** Nothing here should spawn a second `gog`
holding the same keyring — it takes a lock and the loser fails with
*"Config file is in use by another instance."*

**Doctors lie by exit code.** `gog auth doctor` *"exits successfully when
it emits a diagnostic report, even if that report has failed checks."*
`openclaw doctor` exits 0 even when `ok:false`; `hermes doctor` exits 1
whenever any optional integration is absent. Parse the output in all three
cases. `verify.sh` does.

`verify --live` makes a real Google read through `gog`. Nothing short of
that proves the credential works. `--base` re-runs the base suite. Then
tell the user to do step 6.

## This add-on touches both gateways' health

It modifies OpenClaw, but both gateways share a machine, so `verify.sh`
runs `openclaw doctor --lint --all --json` **and** `hermes doctor`. Keep
the `--lint --all`: a bare `openclaw doctor` selects 39 of 69 checks and
has reported `ok:true, findings:[]` while the full run found 33.

---

# Reference

## What this installs

| Piece | From |
|---|---|
| `gog` v0.48.0 at `/usr/local/bin/gog` | the gogcli GitHub release, SHA256-pinned |
| a `gog mcp` server registered with OpenClaw | configured by Pi |
| an `EnvironmentFile` holding the keyring password | written by Pi, 0600 |

Nothing is compiled and nothing needs Homebrew or a Go toolchain: the
release ships a statically linked binary. On arm64 this was verified by
hand — downloaded, checksum matched, and `file` reports
`ELF 64-bit LSB executable, ARM aarch64 … statically linked`.

## Why MCP rather than running `gog` as a shell command

`gog mcp` exposes typed tools and is *"read-only by default; writes require
explicit command and tool authorization"*, explicitly *"without a generic
shell or command bridge."* Three reasons it wins:

- read-only by default is the right starting posture;
- it gives per-agent credentials at the server, which is what OpenClaw's
  own security guidance recommends;
- the shell path has a trap — OpenClaw's approval system *"cannot bind
  pipelines, command substitutions, subshells, write redirections"* and
  denies them outright, while `gog`'s documented examples are pipe-heavy.

This is not a reversal of the Hermes add-on's move **off** MCP. That
decision was "use the vendor's own path rather than a third-party MCP
server." Here the vendor's own path *is* `gog`, and `gog mcp` is simply its
typed interface.

## The keyring, and why it is the weak spot

`gog` keeps its OAuth tokens in an encrypted keyring, and on a headless
machine it will only unlock that keyring from an **environment variable**.
There is no password-file option and no password-command option; this was
checked in the source, not assumed.

So the password lives in a 0600 file that systemd reads as an
`EnvironmentFile` — the same pattern as `agents.env`, and the best
available. Be clear-eyed about what it buys: **the password sits on the
same disk, readable by the same user, as the keyring it unlocks.**

**This is a weaker secret story than the Hermes add-on**, where the token
sits at 0600 and no password lives in any process environment. That
asymmetry is stated here rather than glossed, because the repo's standard
is that every setting is either chosen deliberately or its default examined.

## A note on egress

The add-on needs googleapis.com and **adds nothing to the allowlist**.
Squid already allows the public web on 443 in both phases, so no entry is
needed. `verify.sh` asserts none appeared — an optional extra that widens
egress is changing the base system by the back door.

## Forms, and the one design decision behind it

`gog` can read form responses; Hermes' bundled skill cannot do Forms at
all. Two things shape how this is used:

**Form ids are listed in config, not discovered.** The Forms API has no
"list my forms" method, so discovery would mean a Drive scope Google
classifies as **Restricted** and gates behind a verification review.
Naming the ids in `GOOGLE_FORM_IDS` keeps the grant small. Each id is in
the form's own URL: `https://docs.google.com/forms/d/THIS_PART/edit`.

**Reading responses means polling, not push.** Google's watch mechanism
delivers only to Cloud Pub/Sub, needs a billed project, expires weekly, and
carries no data — you still make the same call afterwards. The polling path
supports a `timestamp > N` filter, and quota is 180 requests per minute per
user, which is generous against a poll every few minutes.

## Undoing it

```sh
./scripts/addon-google-openclaw.sh remove
```

Removes the add-on's config and spec, and tells you what to have Pi undo.
It deliberately does **not** delete `gog` or its keyring: the keyring is
the authorisation, and deleting it costs another consent round.

It does not revoke anything at Google's end either — only you can do that,
at <https://myaccount.google.com/permissions>, signed in as the agent's
account. If you are removing this because something went wrong, revoke
there too.
