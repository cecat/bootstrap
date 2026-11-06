# Google Workspace for the Hermes agent

An **optional add-on**. The base build does not need it, does not know about
it, and is not modified by it. Nothing here runs unless you ask for it.

It gives the **Hermes agent only** access to one Google account's Gmail,
Calendar, Drive and Forms. OpenClaw gets nothing.

> **Build the base system first.** Follow the repo's top-level `README.md`
> and come back when `./verify/verify.sh` reports no failures. That document
> is the only instructions for the base build; this one does not repeat them
> and deliberately does not summarise them. If the base is not finished and
> verifying, `install` below refuses to run.

## Your part, then your agent's

Steps 1–3 are yours, because they need a browser and a secret that must not
pass through a chat. Then you hand over at step 4, and step 5 is the one
check at the end that no script can do. Everything between is the agent's.

Budget about fifteen minutes of your attention, most of it in the Google
Cloud Console.

### 1. Set up a Google OAuth client (browser, about ten minutes)

At <https://console.cloud.google.com/>:

1. Create a project, or pick one you already have.
2. Enable four APIs. Search for each by name in **APIs & Services →
   Library** and enable exactly these, no others:

   | Search for | Enable the one titled | Its service name | Not these |
   |---|---|---|---|
   | `Gmail` | **Gmail API** | `gmail.googleapis.com` | Gmail MCP API, Gmail Postmaster Tools API, Workspace MCP API |
   | `Google Calendar` | **Google Calendar API** | `calendar-json.googleapis.com` | Calendar MCP API |
   | `Google Drive` | **Google Drive API** | `drive.googleapis.com` | Drive Activity API, Drive Labels API |
   | `Google Forms` | **Google Forms API** | `forms.googleapis.com` | Forms MCP API |

   The near-misses are real and several are one search result away from the
   right answer. Two things to know. The **service name** in the third
   column is the unambiguous identifier — it appears on each API's detail
   page, so check it there if a title looks close but not exact. And the
   Google-hosted **"MCP API"** entries are a different product from the MCP
   server this add-on runs inside your VM; enabling one does nothing for
   you here.
3. Configure the consent screen, under **APIs & Services → OAuth consent
   screen** (recent consoles file this under **Google Auth Platform →
   Branding / Audience**). Choose user type **External** unless you
   administer a Workspace domain, give it any app name, and put your own
   address in both the user-support and developer-contact fields.
4. **Publish it.** On the same screen — **Audience**, in the newer layout —
   the publishing status starts as **Testing**. Press **Publish app** so it
   reads **In production**. This matters more than it looks; see the
   warning below.
5. **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, application type **Desktop app**. Google then shows the client ID
   and client secret once, in a dialog. Leave it open for the next step, or
   download the JSON — you can always re-open the client later to copy the
   ID, and reset the secret if you lose it.

   **If the client offers an "Authorized redirect URIs" field, add exactly
   this:**

   ```
   http://127.0.0.1:8731/
   ```

   That is the port the next step listens on. Google requires the redirect
   to match a registered URI exactly, so a missing or mistyped entry fails
   the consent step with `redirect_uri_mismatch`. (If you had to use a
   different port because 8731 was taken, register that one instead.)

   You can skip the **Data access / Scopes** screen. This add-on requests
   its scopes at consent time; scopes listed in the console do not grant
   anything by themselves.

> **Leave the consent screen in "Testing" and this add-on breaks every seven
> days.** Google expires refresh tokens issued by an unpublished app after a
> week. The failure looks like the agent suddenly being unable to see your
> mail, with `invalid_grant` buried in a log. An External app that requests
> no sensitive scopes for *other people's* accounts does not need Google's
> verification review to be published for your own use.

### 2. Put those two values in a file

```sh
./scripts/addon-google-workspace.sh install
```

The first run creates `config/google.env` from a template, tells you what it
needs, and stops with exit 2 — the same handshake `bootstrap.sh` uses. Open
that file in an editor and fill in `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET`.

**Type them into the file, never into a chat with your coding agent.** A
secret pasted into a conversation is a secret in a transcript you do not
control.

### 3. Consent, in a browser

Consent needs a real Google login in a real browser. You cannot `curl` it:
the URL returns Google's sign-in *page*, not a token.

Almost nobody runs this on a machine with a browser — the usual setup is a
headless Linux host reached over SSH from a laptop — so that is the path
described first.

**You need two terminals.** Open the tunnel *before* you open the URL. The
order matters: Google redirects to `127.0.0.1:8731` at the end of consent,
and without the tunnel that address means your laptop, where nothing is
listening.

**Terminal A — on your laptop.** Forward the port to the remote host and
leave it open:

```sh
ssh -N -L 8731:127.0.0.1:8731 you@remote-host
```

**Terminal B — on the remote host, over SSH.** Start the consent flow:

```sh
./scripts/addon-google-workspace.sh auth
```

It detects there is no display, writes the consent URL to
`config/google-consent-url.txt`, and waits ten minutes.

**Then, on your laptop:** open that URL in your browser and approve. The
URL is long, so read it out of the file rather than retyping it — for
example `scp you@remote-host:…/config/google-consent-url.txt .`, or just
`cat` it in terminal B and copy. When you approve, your browser is sent to
`127.0.0.1:8731`, the tunnel carries that to the waiting command, and
terminal B finishes on its own and writes the tokens. Close terminal A
afterwards.

If the machine running `auth` *does* have a browser, none of the above
applies: the command opens the page itself and no tunnel is needed.

**If something goes wrong,** the error tells you which layer:

| What Google or the browser says | What it means |
|---|---|
| `Error 401: invalid_client` — "The OAuth client was not found" | The client ID is wrong — very often a stray space or a partial paste. `auth` now checks the format first and refuses before sending you to a browser. |
| `Error 400: redirect_uri_mismatch` | `http://127.0.0.1:8731/` is not registered on the OAuth client. Add it in step 1. |
| Consent succeeds, then "can't reach this site" at 127.0.0.1:8731 | The tunnel is not up, or was opened after the fact. Start terminal A, then re-run `auth`. |
| `auth` says the port is in use | Something else holds 8731. Pick another with `GOOGLE_OAUTH_PORT=8732`, and register *that* port in the Cloud Console and use it in the `ssh -L` line. |

### 4. Hand over to your coding agent

Now switch. Open your coding agent in this directory and tell it:

> Read `addons/google-workspace/README.md` and install the Google Workspace
> add-on.

It takes over from here, and will come back to you once at the end with the
one check no script can perform.

### 5. The check nothing automated covers

When the agent reports it is done, **message the Hermes bot on Telegram and
ask it what is on your calendar today.** Every automated check in this repo
has passed at some point while an agent sat mute, so this one is yours and
it is not optional.

---

# Installing it — for the coding agent

The human has done steps 1–3 above: `config/google.env` holds a client ID,
a client secret and a refresh token, and a `google-credentials-*.json` sits
beside it. Your job is the rest.

```sh
./scripts/addon-google-workspace.sh install        # preconditions, push, drive Pi
./scripts/pi-session.sh summary                    # what Pi claims it did
./scripts/addon-google-workspace.sh verify --live --base
```

`install` checks its preconditions and refuses rather than half-installing:
the base build must be present and verifying, and the Hermes Telegram
allowlist must not be empty. It then pushes the pinned requirements and the
credential store into the VM and hands Pi the spec in
`addons/google-workspace/spec.md`, through the ordinary
`./scripts/pi-session.sh say`.

Supervise Pi exactly as `AGENTS.md` describes for the base build: its
summary is a claim, `verify.sh` is the evidence, and `pi-session.sh say` is
how you push back. Pi's deliverable is
`~/agent-bootstrap/setup-google.sh` — a second, standalone idempotent
script, never `setup.sh`, so base idempotence stays a measurement of the
base build.

`verify --live` makes one real Google call (it reads a Gmail label and
writes nothing), because a registered tool list proves nothing about the
credentials. `--base` re-runs the base suite to confirm this add-on broke
nothing. Then tell the user to do step 5.

---

# Reference

## What this installs

The MCP server is **[taylorwilsdon/google_workspace_mcp][upstream]** (MIT),
installed from PyPI as `workspace-mcp`, pinned to one version. This add-on is
the wiring: host-side consent, credential plumbing, the Hermes registration,
and the checks.

[upstream]: https://github.com/taylorwilsdon/google_workspace_mcp

There is no official Google or Anthropic MCP server for Workspace. Google
publishes MCP servers for databases and gcloud, not for Gmail or Drive;
Anthropic's `gdrive` reference server was archived. This is the de-facto
standard — and depending on it beats maintaining a few hundred lines of
Google API plumbing here.

### The tradeoffs of that choice

**Supply chain.** An optional add-on now pulls a third-party package into a
VM whose whole premise is a sandbox. Mitigations: the version is pinned, the
server runs in a venv of its own, it gets exactly one account's credentials,
and it is confined by the same egress rules as everything else. It is not
audited, and nobody here reviews its releases.

**The pin is load-bearing.** Every restriction below is a claim about *one
reviewed version's* tool surface. A floating dependency could add a delete
tool in a release nobody read. So `verify.sh` asserts both the version and
the surface, re-derived from the running server — a bump that widens what the
agent can do fails the checks rather than passing quietly.

**Tool names are upstream's.** They change between releases, so `verify.sh`
names them explicitly and a version bump becomes a verify-and-adjust step
rather than a no-op. That friction is deliberate.

## What the agent can do

| Service | It can | It cannot |
|---|---|---|
| **Gmail** | search, read, send, draft, label, move, archive, trash | delete permanently |
| **Calendar** | list, read, create, update, delete events | — |
| **Drive** | search, read, create, update, copy, share | delete, trash |
| **Forms** | create a form, edit questions, read responses | submit a response |

Archiving is removing the `INBOX` label; trashing is adding `TRASH`. Both go
through `modify_gmail_message_labels`.

Two of those limits are worth being precise about, because they are not the
same kind of limit.

**Gmail cannot permanently delete, and Google enforces it.** The token
carries `gmail.modify`, under which the API refuses `messages.delete`.
Trashed mail is recoverable for 30 days. The upstream package defines no
full-mailbox scope at all, so it cannot ask for more — `verify.sh` checks
both that fact and the scopes actually granted to your token.

**Drive cannot delete, because no such tool exists.** Google publishes no
"everything except delete" scope for Drive, so the token carries the full
`drive` scope and the restriction is that the server implements no delete or
trash tool — verified against the installed package, not taken on trust. But
the agent has a shell and can read the credentials, so this is a guardrail
against mistakes, not a boundary against intent. If that is not good enough
for the account you are connecting, connect a different account.

The narrower alternative is `drive.readonly` + `drive.file`, where Google
itself refuses to touch anything the agent did not create — at the cost of
the agent no longer being able to edit your existing documents. To switch,
drop the `drive` scope from `SCOPES` in `auth/google-oauth.py` and re-run
`auth --force` and `install`.

**Forms cannot be submitted.** The agent builds forms and reads what others
submitted. Google publishes no API for filling one in, and driving a real
browser does not work in this VM (the computer-use driver fails on a missing
`libXi.so.6`). Filling in arbitrary web forms is not part of this add-on.

### A note on egress

The add-on needs pypi.org (to install the server) and googleapis.com (to use
it), and **adds nothing to the allowlist for either**. Squid's rules end with
`http_access allow all` after denying the private ranges, so the public web on
80/443 is already reachable in both the bootstrap and runtime phases; the
allowlist only names destinations on other ports. `verify.sh` asserts that no
Google domain was added, because an optional extra that widens egress would be
changing the base system by the back door.

One stale note to be aware of: `docs/gotchas.md` (2026-10-30) says pypi.org is
"bootstrap allowlist only", and `spec/pi-target-state.md` says the same. That
predates the squid change of 2026-10-31 that opened the public web. Verified
on 2026-11-06: a runtime-phase VM reports "public web is reachable through
squid". Those base files are left alone here deliberately — this add-on
changes nothing in the base system — but the install does not need the
bootstrap phase, and you should not switch to it.

## What `install` refuses to do

It stops rather than half-installing if the base build is missing or
failing, if there is no refresh token yet, or if the Hermes bot has an empty
`TELEGRAM_ALLOWED_USERS`.

That last one is not bureaucracy. Once this add-on is in place, whoever can
message the Hermes bot can read your mail, so the allowlist stops being a
configuration detail and becomes the whole exposure. If the Hermes channel
is deliberately off, either turn it on or leave this add-on uninstalled.

## Where the credentials live

Consent happens **on your machine**, never in the VM — the VM has no browser
and no display, and this is why it never needs one. The flow writes two files
into `config/`, both 0600 and both gitignored:

- `google.env` — client id, secret, refresh token, account email
- `google-credentials-<you>@<domain>.json` — the same refresh token in the
  layout the server's credential store reads

Both are copied into the VM (`~/.config/agent-sandbox/`, the store directory
at 0700), and the Hermes gateway gets the OAuth client values through a
systemd `EnvironmentFile=`. The store file necessarily holds the refresh
token in the clear, because that is the format the server reads; file modes
are what protect it, and `verify.sh` checks them.

Never paste any of these values into a conversation with an agent. A token in
a chat is a token in a transcript.

## Undoing it

```sh
./scripts/addon-google-workspace.sh remove
```

Deregisters the server, deletes the credentials and the store from the VM,
and restarts the Hermes gateway. It does **not** revoke the token at Google's
end — only you can do that, at
<https://myaccount.google.com/permissions>. If you are removing this because
something went wrong, revoke there too, then delete the two files in
`config/`.

## For Workspace admins

If you administer a Google Workspace domain you may prefer a service account
with domain-wide delegation: no consent screen, no refresh-token expiry, no
per-user browser step. This add-on does not implement that path, though the
upstream server supports more auth modes than are used here. Service-account
keys are long-lived secrets with a much larger blast radius than one user's
refresh token.
