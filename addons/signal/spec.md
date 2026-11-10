# Add-on: Signal as a chat channel

You are Pi, in the sandboxed VM you already built. This is an **optional
add-on** to that build. Both agents' vendors ship their own Signal
adapters; your job is to install the dependency they share — **signal-cli**
— run it as a daemon, and point the configured adapter(s) at it.

**You are not writing a Signal client.** Hermes' Signal adapter is bundled.
OpenClaw's is an official plugin. If you find yourself implementing Signal
protocol anything, stop — you have taken a wrong turn.

Your **deliverable is `~/agent-bootstrap/setup-signal.sh`** — a new,
idempotent script. Put every change in it and run the script.

## Rules

1. **Do not touch `~/agent-bootstrap/setup.sh`.** It is the base build's
   deliverable and its idempotence is measured separately. Your work goes
   in a second script that stands alone.
2. **Do not touch the Telegram configuration.** Both agents keep their
   Telegram channels exactly as they are. This add-on adds a channel; it
   replaces nothing.
3. **Never run `link`, `register`, `verify`, `startLink` or `finishLink`.**
   Linking already happened — a human scanned a QR code before you were
   started. Running it again creates a second device and a mess only they
   can clean up. If the account looks unlinked, **say so and stop**.
4. **Never print a phone number, and never print a credential.** Phone
   numbers are personal data, your whole session is logged on the host, and
   a number in a transcript cannot be un-written. Report shapes and counts:
   "1 account registered", "allowlist has 1 entry", `test -s`, `stat -c %a`.
   Never `cat` the signal-cli data directory, `~/.hermes/.env`, or
   `~/.config/agent-sandbox/*.env`.
5. **Restrict before enabling.** The allowlist must be in place before any
   adapter can answer. A reachable agent has shell access and no permission
   prompts; who may message it is the only control. Same rule as Telegram
   in the base spec.
6. **Do not weaken the sandbox.** No egress change is needed — everything
   Signal needs is TLS on 443, and squid already allows the public web
   there. If you believe otherwise, show the failing request first. Never
   run `agent-egress unlock`.
7. **Guard every step before acting**, so a second run changes nothing.

## What you have been given

`~/.config/agent-sandbox/signal.env` (0600), holding:

| Name | Meaning |
|---|---|
| `SIGNAL_AGENT` | `hermes`, `openclaw`, or `both` — who gets a Signal channel |
| `SIGNAL_MODE` | `note-to-self` or `dedicated` |
| `SIGNAL_HERMES_NUMBER` | the account Hermes answers on, E.164 |
| `SIGNAL_OPENCLAW_NUMBER` | the account OpenClaw answers on, E.164 |
| `SIGNAL_ALLOWED_USERS` | who may message the agents, comma-separated E.164 |

Read values from it; never echo them.

## What to build

### 1. Install signal-cli and a JRE

**Java 25, not 17.** signal-cli 0.14 requires JRE 25 and the package
depends on it explicitly. Anything older fails with a class-file-version
error. Hermes' own documentation says "Java 17+" and is wrong; trust the
package.

`openjdk-25-jre-headless` is in **`noble-updates`**, not base `noble`.

signal-cli is not in Ubuntu's archive. Use the signed apt repository, which
is the only route that supplies a working **aarch64** build — upstream
publishes no arm64 release, and its bundled native library is x86-64 only:

```sh
curl -sL -o /etc/apt/trusted.gpg.d/morph027-signal-cli.asc \
  https://packaging.gitlab.io/signal-cli/gpg.key
echo "deb https://packaging.gitlab.io/signal-cli signalcli main" \
  > /etc/apt/sources.list.d/morph027-signal-cli.list
apt-get update && apt-get install -y signal-cli-jre
```

Fetch the key **to a file** and record its SHA256 in your summary — the
repo's rule is download-then-verify, never pipe. A signed apt repo with
per-package SHA256 satisfies that rule; piping a key into `apt-key` would
not.

Then prove the install actually works:

```sh
signal-cli --version
```

That single command is the real test. It loads the native library, so it
fails with `UnsatisfiedLinkError` if the architecture is wrong — which is
exactly the failure this repo would otherwise discover much later. Quote
its output.

### 2. Give the JVM the proxy — the step that silently breaks everything

**signal-cli will not use `http_proxy` or `https_proxy`.** It is a Java
program and the JVM does not read those variables. Without the settings
below it opens a direct socket, the uid lockdown rejects it, and the error
is `java.net.SocketException: Network is unreachable` — with no mention of
a proxy anywhere, because it never believed it had one.

Pass them as JVM system properties through `JAVA_OPTS`:

```
JAVA_OPTS=-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128 \
          -Dhttp.proxyHost=127.0.0.1  -Dhttp.proxyPort=3128
```

This is confirmed working against squid specifically. It covers both of
signal-cli's network stacks in current versions: the HTTP client reads the
properties directly, and signal-cli passes them into the Signal library's
own networking for the chat websocket and contact discovery. Versions
before 0.13.22 did not, and leaked those connections around the proxy; we
are on 0.14.x.

### 3. Run the daemon as a systemd user service

```
signal-cli daemon --http 127.0.0.1:<port>
```

Requirements:

- a **user** service, enabled, so it survives reboot (linger is already on);
- `JAVA_OPTS` from step 2 in the unit — a user service does not read
  `~/.profile`, which is the documented way for this to work in your shell
  and fail in service;
- **no `-a` flag.** Without it the daemon serves every local account, and
  requests carry an `account` parameter. That is what lets one service
  serve two numbers if a second is ever added;
- bound to **127.0.0.1 only**. The HTTP interface has no authentication —
  it says so at startup — so the loopback bind plus the adapters'
  allowlists are the whole control. `verify.sh` fails the build on anything
  bound to a wildcard address;
- the data directory stays **0700**. It holds the account keys.

Confirm the daemon is answering before configuring anything against it, and
confirm it from the journal rather than from the fact that systemd says
`active`. A running service is not a connected one — that distinction has
cost this repo a day before.

### 4. Configure the adapter(s) named by `SIGNAL_AGENT`

**Hermes** (if `hermes` or `both`): its Signal adapter is bundled, so this
is configuration, not installation.

```
SIGNAL_ACCOUNT        = the Hermes number
SIGNAL_HTTP_URL       = the daemon's http endpoint
SIGNAL_ALLOWED_USERS  = from signal.env
```

Credentials and channel settings go in `~/.hermes/.env` at 0600, the same
place Telegram's live. Do not invent another location: `verify.sh` decides
whether to check the allowlist by looking there, so settings elsewhere mean
a live channel and a skipped safety check.

`SIGNAL_ALLOWED_USERS` must be non-empty. The vendor's own words: *"Without
`SIGNAL_ALLOWED_USERS` or DM pairing, the gateway denies all incoming
messages as a safety measure."* Denying everything is the safe failure, but
it is not what the user asked for — set it.

If `SIGNAL_MODE` is `note-to-self`, nothing extra is needed: Hermes handles
it automatically when `SIGNAL_ACCOUNT` matches the user's own number. Do
not try to configure it specially.

**OpenClaw** (if `openclaw` or `both`): install the official plugin, then
configure the channel.

```sh
openclaw plugins install @openclaw/signal
```

- `channels.signal.dmPolicy` = `allowlist`, `allowFrom` = the allowed
  numbers. Exactly the shape the Telegram channel already uses.
- **`transport.kind` must be `external-native`**, pointed at the daemon
  from step 3. Not `managed-native`: that spawns a *second* signal-cli,
  which collides with the daemon on the account data lock and fails with
  *"Config file is in use by another instance."*
- Enable the channel **last**, after the allowlist is set and read back,
  exactly as the base spec requires for Telegram.
- If `SIGNAL_MODE` is `note-to-self` and OpenClaw is selected, **stop and
  report it**. OpenClaw ignores the account owner's own messages by design;
  the combination cannot work. The installer should have refused this, so
  if you see it, something upstream of you is wrong.

### 5. Restart each gateway once, at the end

Not after each step. Restarting twice inside a short window leaves the
Telegram adapter logging `Conflict: terminated by other getUpdates request`
while it reconnects — harmless, but it makes a real Telegram fault
invisible in `verify.sh`, and the bot is unreachable while it lasts.

Make all your config edits, then restart once.

### 6. Prove it

Report the actual output of each:

- `signal-cli --version` succeeded (proves the native library loaded);
- the daemon is active, enabled, and listening on **loopback only**;
- squid's access log shows a `CONNECT chat.signal.org:443` tunnel — this is
  the proof the JVM proxy settings took effect, and the only cheap one;
- for each configured agent, the allowlist read back from its config, with
  the numbers **redacted**: report the count and whether it matches the
  configured one, not the values;
- `hermes doctor`, and `openclaw doctor --lint --all --json` if OpenClaw was
  touched. Judge both on parsed output, never exit code: `hermes doctor`
  exits 1 whenever any optional integration is absent, and `openclaw doctor`
  exits 0 even when `ok:false`.

Do **not** send a test message to the user, and do not message the agents to
try them out. The user does that; it is the one check no script performs.

## When something will not work: stop and hand it back

**Three failures of the same thing is the limit.** Not thirty. If a command
fails the same way three times, you have the information you are going to
get by running it again. Two earlier runs of another add-on's spec spent 56
and 45 attempts on one failing call; neither attempt 4 nor 45 told anyone
anything attempt 3 had not, and both root causes were defects in the spec
that no amount of retrying could reach.

When you hit that limit, **stop and write up what you know**, in your
summary rather than in more commands:

- what you ran and the exact error;
- the narrowest thing you proved works, and the narrowest that does not;
- what you ruled out, and the evidence that ruled it out;
- what you would try next if you had another layer to look at.

A supervising coding agent reads that and can check things you cannot reach
from in here — the host, the repo, the vendors' documentation, this spec
itself. Handing back a clear impasse is a result. Grinding on is not.

**Do not invent a root cause for a failure you could not fix.** A wrong
explanation reads like a finding and gets believed, which is worse than an
honest impasse.

Four specific cases, so you do not spend the three attempts finding out:

- **`UnsatisfiedLinkError` from `signal-cli --version`** — the native
  library does not match this architecture. Report it and stop; the fix is
  in the installer, not in here.
- **A class-file-version error** — wrong Java. You need 25.
- **`Network is unreachable` or a hang with no proxy mentioned** — step 2
  did not take effect. Check that the *service* has `JAVA_OPTS`, not just
  your shell.
- **`Link request error: Connection closed!`** — this looks like a Signal
  outage and is not. It is the library falling back to domain-fronting
  through a host the allowlist denies. Report it; do not widen the
  allowlist.

## Idempotence

Run `setup-signal.sh` twice. The second run must change nothing, restart no
service and reinstall nothing. Verify that before you finish, and say so.

## When you are done

Say what you did, what you proved and how, and what you skipped. Quote the
command output behind each claim. Name anything you did differently from
this document and why — that is useful, not a failure. If this spec was
wrong about something, say so plainly; it has been before.

Do not claim the channel works because the daemon is running. Running is
not connected, and connected is not answering.
