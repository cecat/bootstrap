# Google Workspace for the Hermes agent

An **optional add-on**. The base build does not need it, does not know about
it, and is not modified by it. Nothing here runs unless you run it.

It gives the **Hermes agent only** access to one Google account's Gmail,
Calendar, Drive and Forms. OpenClaw gets nothing.

```sh
./bootstrap.sh && ./scripts/pi-session.sh build   # the base system, first
./scripts/finish-build.sh
./verify/verify.sh                                 # clean before you start

./scripts/addon-google-workspace.sh auth           # one browser consent
./scripts/addon-google-workspace.sh install        # build it
./scripts/addon-google-workspace.sh verify --live  # the evidence
```

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

## Before you start

The base system must be built and verifying, and the Hermes bot must have a
non-empty Telegram allowlist. `install` checks both and refuses otherwise.

That second one is not bureaucracy. Once this add-on is in place, whoever can
message the Hermes bot can read your mail. The allowlist is the only thing
deciding who that is.

## One-time setup in Google Cloud Console

This is the part only you can do. It is all in a browser, and you do it once.

1. Create a project at <https://console.cloud.google.com/>.
2. Enable four APIs: **Gmail**, **Google Calendar**, **Google Drive**,
   **Google Forms**.
3. Configure the OAuth consent screen. Choose **External** unless you are a
   Workspace admin, add your own address as the account, and then —
   importantly — **publish it**. Set publishing status to **In production**.
4. Create credentials → **OAuth client ID** → application type **Desktop
   app**. Copy the client ID and client secret.
5. Put those two values into `config/google.env`. Run `install` once with no
   config and it will create that file from the template and tell you.

> **Leave the consent screen in "Testing" and this add-on breaks every seven
> days.** Google expires refresh tokens issued by an unpublished app after one
> week. The failure looks like the agent suddenly being unable to see your
> mail, with `invalid_grant` buried in a journal. Publishing is the fix. An
> External app requesting no sensitive scopes for *other people's* accounts
> does not need Google's verification review to be published for your own use.

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
