# Google Workspace for the Hermes agent

An **optional add-on**. The base build does not need it, does not know about
it, and is not modified by it. Nothing here runs unless you ask for it.

It gives the **Hermes agent only** access to one Google account's Gmail,
Calendar, Drive, Docs, Sheets and Contacts. OpenClaw gets nothing.

> **Build the base system first.** Follow the repo's top-level `README.md`
> and come back when `./verify/verify.sh` reports no failures. That document
> is the only instructions for the base build; this one does not repeat them
> and deliberately does not summarise them. If the base is not finished and
> verifying, `install` below refuses to run.

## Your part, then your agent's

Steps 1–4 are yours, because they need a browser, a secret that must not
pass through a chat, and a file only you can edit. Step 4 ends by handing
over, and step 5 is the one check at the end that no script can do.
Everything in between — Pi building, and the reading of what it claims
against what the checks measure — belongs to your coding agent.

Budget about twenty minutes of your attention: roughly ten clicking
through the Google Cloud Console, and ten on the consent step, which is
fiddly on a headless host and is described in full before you start it.
Both are one-off — once there is a refresh token, none of this recurs.

### 1. Set up a Google OAuth client (browser, about ten minutes)

At <https://console.cloud.google.com/>:

1. Create a project, or pick one you already have.
2. Enable six APIs. Search for each by name in **APIs & Services →
   Library** and enable exactly these, no others:

   | Search for | Enable the one titled | Its service name | Not these |
   |---|---|---|---|
   | `Gmail` | **Gmail API** | `gmail.googleapis.com` | Gmail MCP API, Gmail Postmaster Tools API, Workspace MCP API |
   | `Google Calendar` | **Google Calendar API** | `calendar-json.googleapis.com` | Calendar MCP API |
   | `Google Drive` | **Google Drive API** | `drive.googleapis.com` | Drive Activity API, Drive Labels API |
   | `Google Sheets` | **Google Sheets API** | `sheets.googleapis.com` | Sheets MCP API |
   | `Google Docs` | **Google Docs API** | `docs.googleapis.com` | Docs MCP API |
   | `People` | **People API** | `people.googleapis.com` | Contacts API (legacy, retired) |

   The near-misses are real and several are one search result away from the
   right answer. Two things to know. The **service name** in the third
   column is the unambiguous identifier — it appears on each API's detail
   page, so check it there if a title looks close but not exact. And the
   Google-hosted **"MCP API"** entries are a wholly different product;
   enabling one does nothing for you here.

   No Forms API: the bundled skill has no Forms support. If you enabled it
   for an earlier version of this add-on, it is now unused.
3. Configure the consent screen, under **APIs & Services → OAuth consent
   screen** (recent consoles file this under **Google Auth Platform →
   Branding / Audience**). Choose user type **External** unless you
   administer a Workspace domain, give it any app name, and put your own
   address in both the user-support and developer-contact fields.
4. **Publish it.** On the same screen — **Audience**, in the newer layout —
   the publishing status starts as **Testing**. Press **Publish app** so it
   reads **In production**. This matters more than it looks; see the
   warning below.

   **The button is greyed out until Branding has an App domain.** An
   external app in production needs three links — application home page,
   privacy policy, terms of service — plus that domain under *Authorised
   domains*. Google: *"These links are required for all external
   production apps."* Measured 2026-11-11: the URLs are **not fetched**
   at publish time, so pages that do not exist yet are accepted; the
   domain does have to be one you own and have verified. Leave the logo
   empty — it is optional, and a custom one invites the verification
   review this setup does not otherwise need.
5. **APIs & Services → Credentials → Create credentials → OAuth client
   ID**, application type **Desktop app**. Google then shows the client ID
   and client secret once, in a dialog. Leave it open for the next step, or
   download the JSON — you can always re-open the client later to copy the
   ID, and reset the secret if you lose it.

   **There is nothing to configure for the redirect.** A Desktop app client
   has no "Authorized redirect URIs" field, and does not need one: loopback
   redirects are matched on everything *except* the port, so
   `http://127.0.0.1:<anything>/` is accepted automatically. That is what
   the next step relies on, and why changing `GOOGLE_OAUTH_PORT` needs no
   console change. (RFC 8252 §7.3 and §8.4, which Google implements.)

   You can also skip the **Data access / Scopes** screen. This add-on
   requests its scopes at consent time; scopes listed in the console do not
   grant anything by themselves.

> **Leave the consent screen in "Testing" and this add-on breaks every seven
> days.** Google expires refresh tokens issued by an unpublished app after a
> week. The failure looks like the agent suddenly being unable to see your
> mail, with `invalid_grant` buried in a log. An External app that requests
> no sensitive scopes for *other people's* accounts does not need Google's
> verification review to be published for your own use.

### 2. Download the client JSON into `secrets/`

On the Credentials page, press the **download icon** beside the client you
just made, and put the file in `secrets/`:

```
secrets/client_secret_<long-id>.apps.googleusercontent.com.json
```

Leave the name as Google gives it — the add-on finds it by that pattern.
`secrets/` is gitignored. Nothing to retype, and nothing to mistype: a
client ID copied by hand arrived with a leading space once and cost an
afternoon of `invalid_client`.

The next command reads this file, copies the two values into
`config/google.env`, and checks the client is a **Desktop app** — a Web
application client is rejected here rather than at the redirect.

If you would rather do it by hand, run
`./scripts/addon-google-hermes.sh install` once; it creates
`config/google.env`, tells you what it wants, and stops with exit 2 — the
same handshake `bootstrap.sh` uses. Fill in `GOOGLE_CLIENT_ID` and
`GOOGLE_CLIENT_SECRET` there instead.

**Either way, never paste these into a chat with your coding agent.** A
secret in a conversation is a secret in a transcript you do not control.

### 3. Consent, in a browser

> **Read this before you start it.** If the machine running the add-on is
> headless — the usual case — this step is the awkward one, and it is
> awkward for a reason nothing here can remove: Google will only hand over
> a token to a logged-in browser, and it insists on delivering it to
> `127.0.0.1`, which has to mean the machine that asked. Your browser is on
> your laptop; the thing that asked is the remote host. Bridging that gap
> is an SSH tunnel, and the ten minutes it takes are a one-off.
>
> You need: **the terminal you run `auth` in**, and **one shell on your
> laptop** for the tunnel. The tunnel backgrounds itself, so that shell is
> yours again immediately. The URL is printed in full for you to select —
> no file to open, nothing to scp, nothing to retype.
>
> **You do this once, ever.** The refresh token it produces does not
> expire once the consent screen is published, and it survives re-running
> `install`, rebuilding the add-on, and `remove`. If a later step fails and
> you have to start over, `auth` sees the existing token and exits without
> doing any of this again. Only `auth --force` repeats it, and only
> revoking access at Google makes that necessary.
>
> Do them in that order. Approving before the tunnel exists fails *after*
> you have consented, and the grant is spent — you would re-run `auth` and
> do it again.

You cannot `curl` your way through this: the URL returns Google's sign-in
*page*, not a token.

**On your laptop**, open the tunnel. It backgrounds itself and hands your
prompt straight back, so this shell is not tied up:

```sh
ssh -f -N -L 8731:127.0.0.1:8731 you@remote-host
```

It must run on the laptop, in a shell that is *not* already SSH'd into the
remote host — the command dials out from the laptop. Run inside an existing
remote session it would forward that host to itself and silently do
nothing.

**On the remote host**, start the consent flow:

```sh
./scripts/addon-google-hermes.sh auth
```

It notices there is no display and prints the consent URL in full, then
waits ten minutes.

**Back on your laptop:** select that URL, paste it into your browser, and
approve. Your browser is sent to `127.0.0.1:8731`, the tunnel carries it to
the waiting command, and `auth` finishes on its own and writes the tokens.

Then close the tunnel, on the laptop:

```sh
pkill -f 'ssh -f -N -L 8731'
```

That matches the forwarding command and nothing else, so it leaves any
other SSH session alone. (If you dropped the `-f`, the tunnel is in the
foreground of a shell you can see — Ctrl-C there instead.)

Not `ssh -O exit`: that speaks to a ControlMaster socket, and this tunnel
is a plain process with no control path. On macOS it answers *"No
ControlPath specified for -O command"* and the tunnel keeps running.

Any sessions you already had open on the remote host are beside the point —
they are neither used nor disturbed.

If the machine running `auth` *does* have a browser, ignore all of the
above: the command opens the page itself and there is no tunnel.

**If something goes wrong,** the error tells you which layer:

| What Google or the browser says | What it means |
|---|---|
| `Error 401: invalid_client` — "The OAuth client was not found" | The client ID is wrong — very often a stray space or a partial paste. `auth` now checks the format first and refuses before sending you to a browser. |
| `Error 400: redirect_uri_mismatch` | The client is not a **Desktop app**. Web application clients do require every redirect URI to be registered; desktop ones accept any loopback port. Check the client type in Credentials, and make a new Desktop client if it is wrong. |
| Consent succeeds, then "can't reach this site" at 127.0.0.1:8731 | The tunnel is not up, or was opened after the fact. Start terminal A, then re-run `auth`. |
| `auth` says the port is in use | Something else holds 8731. Pick another with `GOOGLE_OAUTH_PORT=8732` and use the same number in the `ssh -L` line. Nothing to change in the Cloud Console. |

### 4. Run `install`, then hand over

```sh
./scripts/addon-google-hermes.sh install
```

This checks the base build is healthy, pushes your credentials into the VM,
and stages the spec Pi will work from. It takes 3–6 minutes, almost all of
it re-running the base `verify.sh`, and it prints a log path you can
`tail -f` while you wait.

**It stops at the hand-over rather than running on into the build**, and
tells you so. That boundary is deliberate: what remains is Pi building and
someone reading its claims against the evidence, and that is a coding
agent's job, not yours. Open your coding agent in this directory and tell
it:

> Install the Google Workspace add-on: run
> `./scripts/addon-google-hermes.sh build`, then supervise Pi and verify
> it as `addons/google-hermes/README.md` describes.

It will come back to you once, at the end, with the one check no script can
perform.

### 5. The check nothing automated covers

When the agent reports it is done, **message the Hermes bot on Telegram and
ask it what is on your calendar today.** Every automated check in this repo
has passed at some point while an agent sat mute, so this one is yours and
it is not optional.

---

# Installing it — for the coding agent

The human has done steps 1–4 above: credentials are in `config/`, pushed
into the VM, and the spec is staged at `~/agent-bootstrap/GOOGLE-ADDON.md`.
They stopped at the hand-over on purpose. Your job is the build and the
reading of it.

```sh
./scripts/addon-google-hermes.sh build          # drive Pi (5-15 min)
./scripts/pi-session.sh summary                    # what Pi claims it did
./scripts/pi-session.sh steps                      # what it actually did
./scripts/addon-google-hermes.sh verify --live --base
```

The user has already run `install`, which checked preconditions, staged the
credentials at `~/google-skill-push/`, and put the spec at
`~/agent-bootstrap/GOOGLE-ADDON.md`. `build` refuses if any of that is
missing rather than starting a turn that cannot succeed.

`build` drives Pi through the ordinary `./scripts/pi-session.sh say`, so
supervise it exactly as `AGENTS.md` describes for the base build.

**It goes quiet for 5–15 minutes while Pi works, and that is not a hang** —
gaps of a minute between tool calls are normal, and the silence watchdog
only kills a turn after 600s of *no* output. Watch it from another shell
with `./scripts/pi-session.sh steps` if you want to.

Supervise Pi exactly as `AGENTS.md` describes for the base build: its
summary is a claim, `verify.sh` is the evidence, and `pi-session.sh say` is
how you push back. Pi's deliverable is
`~/agent-bootstrap/setup-google.sh` — a second, standalone idempotent
script, never `setup.sh`, so base idempotence stays a measurement of the
base build.

`verify --live` runs the skill's own `setup.py --check-live`, which makes a
real Calendar call and writes nothing. Credentials sitting in place prove
nothing by themselves. Note that `--check` is **not** a substitute: it only
refreshes the token, over a library that honours proxy variables natively,
so it can pass while every real API call fails. `--base` re-runs the base
suite to confirm this add-on broke nothing. Then tell the user to do step 5.

## Adding another add-on

**Re-run the vendor's own doctor for every gateway the add-on touched.**
An add-on is the moment for it: a doctor that was clean beforehand says
nothing about afterwards, and these change config, install into an
agent's interpreter, and patch bundled files. `verify.sh` here runs
`hermes doctor` for exactly that reason, because this add-on is
Hermes-only.

An add-on that touches OpenClaw must run `openclaw doctor --lint --all
--json` as well — copy the check from `verify/verify.sh`, and keep the
`--lint --all`: a bare `openclaw doctor` selects 39 of 69 checks and has
reported `ok:true, findings:[]` while the full run found 33.

Neither doctor can be judged by its exit code. `hermes doctor` exits 1
whenever any optional integration is unconfigured, and `openclaw doctor`
exits 0 even when `ok:false`. Parse the output against an exclusion list
and print how many findings were filtered, so the list stays honest.

The base suite's exclusions are the ones to copy. Needing a *new*
exclusion for an add-on is a signal the add-on broke something, not a
reason to widen the list.

This matters because the gap is silent in both directions: the four
configuration defects the doctors caught on 2026-11-09 had all shipped
past a 41-check suite, and every one of them surfaced later as the agent
behaving oddly rather than as anything failing.

---

# Reference

## What this installs

Nothing, in the sense that matters: the Google integration is **Hermes' own
bundled `google-workspace` skill**, which ships with Hermes and is seeded
into every profile. This add-on is the wiring around it — host-side
consent, getting the credentials into the VM, the two settings the sandbox
needs, and the checks.

That is a deliberate change of direction. Until 2026-11-08 this add-on
installed a third-party MCP server (`workspace-mcp`) instead, pinned to one
version, in a venv of its own. It worked, but it was a parallel stack: the
agent never found it by name, the vendor's own path kept improving without
us, and the first scheduled cron job failed because the agent reached for
the bundled skill — the obvious thing — and found no credentials where that
skill looks for them.

The bundled skill is what Hermes documents, what `hermes skills list`
shows, and what the agent reaches for unprompted. Using it means upstream
maintains the Google plumbing and we maintain almost nothing.

### What we still own, and why

**One host-side consent script**, `auth/google-oauth.py`. The skill ships
its own (`setup.py --auth-url` / `--auth-code`), and we do not use it for
the consent step, for two reasons.

It redirects to `http://localhost:1`, where nothing listens — the browser
is *expected* to fail, and you copy the authorization code out of the URL
bar by hand. Google deprecated exactly that pattern: "the manual copy/paste
option, also referred to as an out of band (OOB) redirect method, is no
longer supported" (February 2022), and their current guidance is that a
loopback redirect with a real listener "is the recommended mechanism for
obtaining the authorization code". Ours does that — loopback, a real
listener, PKCE. Second, the skill's flow needs a ~400-character redirect
URL carried back by hand from the browser; ours captures the code itself.

It runs **once**, on the host, and contributes nothing to the runtime. The
skill's own `setup.py --check` and `--check-live` are used unchanged.

## What the agent can do

| Service | It can | It cannot |
|---|---|---|
| **Gmail** | search, read, send, reply, label, archive, trash | delete permanently |
| **Calendar** | list, read, create, delete events | — |
| **Drive** | search and read files | — |
| **Docs** | read | — |
| **Sheets** | read, write, append | — |
| **Contacts** | list | create, amend or delete |

Archiving is removing the `INBOX` label; trashing is adding `TRASH`.

**Gmail cannot permanently delete, and Google enforces it.** The token
carries `gmail.modify`, under which the API refuses `messages.delete`.
Trashed mail is recoverable for 30 days. This is Google's rule, not ours,
and `verify.sh` checks the granted scope rather than taking it on trust.

**Drive deletion is no longer withheld, and you should know that.** The
previous MCP-based version of this add-on exposed no Drive delete or trash
tool, so deletion was impossible through the tool surface. The bundled
skill takes the full `drive` scope and runs a CLI, so the agent *can*
delete Drive files. In practice this is a smaller change than it sounds —
the old restriction was already, in this repo's own words, "a guardrail
against mistakes, not a boundary against intent", because the agent has a
shell and can read the credentials either way. But it was a real guardrail
and it is gone. If that is not acceptable for the account you are
connecting, connect a different account.

**Contacts is read-only.** The skill requests `contacts.readonly` and
implements one subcommand, `contacts list`. The MCP version could create,
amend and delete contacts; that capability is not available here. Regaining
it means either patching the skill's `google_api.py` (the People API calls
would mirror the existing `contacts_list`) or asking upstream. Deferred
deliberately rather than forgotten.

**Forms is gone.** The skill has no Forms support at all. The MCP version
could create forms and read responses.

**Docs and Sheets are new.** Neither was available before.

### A note on egress

The add-on needs googleapis.com, and **adds nothing to the allowlist**.
Squid's rules end with `http_access allow all` after denying the private
ranges, so the public web on 80/443 is already reachable in both the
bootstrap and runtime phases; the allowlist only names destinations on
other ports. `verify.sh` asserts that no Google domain was added, because
an optional extra that widens egress would be changing the base system by
the back door.

### Two things the sandbox needs that a normal machine does not

Both are applied by Pi from `spec.md`, and both are checked.

**PySocks, installed where Hermes will load it.** The skill reaches Google
through `google-api-python-client`, which builds a bare `httplib2.Http`.
httplib2 does `try: import socks / except ImportError: socks = None`, and
when `socks` is None its `isgood()` returns false and the HTTPS path opens
a **direct socket without saying so**. Under this VM's uid-scoped iptables
that connection is refused or hangs, with no proxy error anywhere, because
httplib2 never believed it had a proxy. PySocks is not a Hermes dependency,
so nothing else installs it.

**`terminal.env_passthrough` naming the proxy variables.** Hermes strips
most environment variables from the children of its `terminal` and
`execute_code` tools, and `http_proxy` / `https_proxy` match none of its
safe prefixes. The skill's scripts run as exactly such a child. Without
this they get no proxy at all.

These two are also why `setup.py --check` is not an acceptable test and
`--check-live` is. `--check` only refreshes the token, and refreshing goes
through `requests`, which honours proxy variables natively — so it can pass
while every real API call fails on the httplib2 path above.

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

- `google_token.json` — the refresh token, in the `authorized_user` shape
  google-auth reads
- `google_client_secret.json` — the OAuth client, as Google issued it

Both names are the skill's, declared in its `SKILL.md` under
`required_credential_files`, and are not ours to change. `install` pushes
them into the VM and Pi installs them at 0600 in the home the Hermes
gateway resolves (`$HERMES_HOME`, normally `~/.hermes`).

`google_client_secret.json` is never read at runtime — refreshing uses the
client id and secret inside the token file. It has to exist anyway, because
Hermes' **cron preflight refuses to start any job whose attached skill has
a declared credential file missing**. That refusal is what blocked the first
inbox digest, and it is why `verify.sh` checks for the file by name.

The token file necessarily holds the refresh token in the clear, because
that is the format google-auth reads; file modes are what protect it, and
`verify.sh` checks them.

Never paste any of these values into a conversation with an agent. A token in
a chat is a token in a transcript.

## Undoing it

```sh
./scripts/addon-google-hermes.sh remove
```

Deletes the credentials from the VM, clears away anything left from the old
MCP-server layout, and tells you the two config edits to have Pi undo. It
does **not** revoke the token at Google's end — only you can do that, at
<https://myaccount.google.com/permissions>. If you are removing this because
something went wrong, revoke there too, then delete the two files in
`config/`.

## For Workspace admins

If you administer a Google Workspace domain you may prefer a service account
with domain-wide delegation: no consent screen, no refresh-token expiry, no
per-user browser step. This add-on does not implement that path.
Service-account keys are long-lived secrets with a much larger blast radius
than one user's refresh token.
