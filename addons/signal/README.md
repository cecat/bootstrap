# Signal as a chat channel

An **optional add-on**. The base build does not need it, does not know
about it, and is not modified by it. Nothing here runs unless you ask for
it.

It lets you talk to your agents over **Signal** instead of, or as well as,
Telegram. Telegram stays exactly as it is.

> **NOT YET BUILT.** This directory is a plan and its scaffolding. No part
> of it has been run and the VM has not been touched. Read `PLAN.md` first
> — it says what was measured, what was taken from vendor documentation,
> and what is still unknown. This file is written as if the add-on works,
> which it has never been observed to do.

> **Build the base system first.** Follow the repo's top-level `README.md`
> and come back when `./verify/verify.sh` reports no failures. If the base
> is not finished and verifying, `install` below refuses to run.

## What you are getting, and the one thing to decide first

Both agents' vendors already ship Signal support — Hermes has a bundled
Signal platform adapter, OpenClaw has an official Signal channel plugin.
Both drive the same thing underneath: **signal-cli**, which joins your
Signal account as a linked device, the way Signal Desktop does. This
add-on installs signal-cli, links it, and wires the adapters to it.

The decision that shapes everything else is **how you want to reach the
agent**, because Signal, unlike Telegram, has no bots and no free second
identity. An account is a phone number.

### Option A — Note to Self (recommended; costs nothing)

Link signal-cli to **your own** Signal account, then talk to the agent by
**messaging yourself**. Hermes supports this as a documented feature: it
reads your Note-to-Self messages and replies in the same thread, with
echo-protection so it does not answer its own messages.

- No second phone number, no new SIM, no captcha, nothing to buy.
- One QR scan from the phone you already have.
- **Hermes only.** OpenClaw deliberately ignores your own messages and has
  no equivalent.
- The trade-off: the agent shares your Signal identity. Its replies are
  sent *as you* and appear in your Note to Self thread on **every device
  you own**. If you use that thread as a scratchpad, you will notice.

### Option B — a dedicated number

The agent gets its own number and its own identity, and you message it like
any other contact.

- Required for OpenClaw, and required if you want **both** agents on Signal.
- Needs a second number that already has Signal running on a phone — an old
  handset, a cheap prepaid SIM, or a second number on a dual-SIM phone.
- On VoIP numbers (Google Voice, Twilio, TextNow): Signal publishes no
  policy and its anti-abuse behaviour is deliberately opaque. Some work,
  some are refused. Treat it as try-it-and-see with a real SIM as the
  fallback.

Set your choice as `SIGNAL_MODE` in `config/signal.env`. Start with A
unless you have a reason not to; switching later is one unlink and one
re-link.

### Why both agents cannot share one number

Signal delivers every message to **every** linked device — that is what
linked devices are for. Two agents on one account would both see every
message and both reply, and two agents with shell access may end up
answering each other. There is no per-device addressing to separate them
with. So two agents on Signal means two numbers. Hermes' own
troubleshooting guide says the same thing: *"Duplicate messages — ensure
only one signal-cli instance is listening on your phone number."*

## Your part, then your agent's

Steps 1–3 are yours, because they need a phone, a camera and a number that
only you can supply. Step 3 ends by handing over. Step 5 is the one check
at the end that no script can do. Everything in between — Pi building, and
the reading of what it claims against what the checks measure — belongs to
your coding agent.

Budget about ten minutes, nearly all of it on the linking step, and that
step is a one-off.

### 1. Decide, and fill in `config/signal.env`

Run this once; it creates the file, tells you what it wants, and stops with
exit 2 — the same handshake `bootstrap.sh` uses:

```sh
./scripts/addon-signal.sh install
```

Then edit `config/signal.env`:

| Setting | What to put |
|---|---|
| `SIGNAL_AGENT` | `hermes` (recommended to start), `openclaw`, or `both` |
| `SIGNAL_MODE` | `note-to-self` or `dedicated` |
| `SIGNAL_HERMES_NUMBER` | in Note-to-Self mode, **your own** number; in dedicated mode, the agent's |
| `SIGNAL_ALLOWED_USERS` | your own Signal number — who is allowed to talk to the agent |

All numbers in **E.164**: a leading `+`, country code, no spaces or dashes.
`+15551234567`, not `(555) 123-4567`.

`SIGNAL_ALLOWED_USERS` cannot be blank and `install` refuses if it is. That
is not bureaucracy: a live agent has shell access and no permission
prompts, so whoever may message it can run commands on it. In Note-to-Self
mode it is your own number, which looks redundant and is not — the
allowlist still has to say so.

Nothing here is a secret in the password sense, but a phone number is
personal data, so the file is 0600 and gitignored like everything else
under `config/`.

### 2. Link, by scanning a QR code

```sh
./scripts/addon-signal.sh link
```

This prints a **QR code in your terminal**. On your phone: **Signal →
Settings → Linked devices → +** and point the camera at your screen.

That is the whole step. Nothing to copy, nothing to retype — the code is
scanned off the screen. (If your terminal renders the QR too small or the
characters are mangled, make the window bigger and re-run; the QR is drawn
with block characters and needs the room.)

A few things worth knowing:

- **Let it finish.** signal-cli exits by itself when linking completes.
  Interrupting it leaves a half-linked account, and the fix is to re-run.
- **This happens inside the VM, deliberately.** The account keys it creates
  belong in the VM and should never exist on your host. Only the
  short-lived `sgnl://` link URI crosses the boundary, to be drawn as a QR
  on your screen. (This is the opposite of the Google add-on, where consent
  happens on the host because the VM has no browser. Here no browser is
  involved at all — just a camera and a screen.)
- **You do this once.** The link survives reboots, re-running `install`,
  and `remove`. Only unlinking from your phone, or deleting the VM,
  requires doing it again.
- **Five linked devices maximum** per Signal account, shared with Signal
  Desktop and iPad. If you are at the limit, remove an old one first.

### 3. Run `install`, then hand over

```sh
./scripts/addon-signal.sh install
```

This checks the base build is healthy, checks you are linked, and stages
the spec Pi will work from. It takes 3–6 minutes, almost all of it
re-running the base `verify.sh`, and it prints a log path you can `tail -f`
while you wait.

**It stops at the hand-over rather than running on into the build**, and
says so. What remains is Pi building and someone reading its claims against
the evidence, and that is a coding agent's job. Open your coding agent in
this directory and tell it:

> Install the Signal add-on: run `./scripts/addon-signal.sh build`, then
> supervise Pi and verify it as `addons/signal/README.md` describes.

### 4. Wait

Your coding agent drives Pi for 5–15 minutes and then checks the result.

### 5. The check nothing automated covers

When the agent reports it is done, **message the agent on Signal and ask it
to fetch a web page.** In Note-to-Self mode that means messaging yourself.

This one is yours and it is not optional. Every automated check in this
repo has passed at some point while an agent sat mute — on 2026-11-04
`verify.sh` read 37 passed, 0 failed with one agent completely silent. A
script can prove the daemon is connected and the config is right. Only you
can prove the agent answers.

Record its exact words. If it mentions a workaround, a fallback, a reader
proxy or rate-limiting, quote that — an agent reporting success by routing
around a block is a finding, not a pass.

---

# Installing it — for the coding agent

The human has done steps 1–3: `config/signal.env` is filled in, signal-cli
is linked, and the spec is staged at `~/agent-bootstrap/SIGNAL-ADDON.md`.
They stopped at the hand-over on purpose. Your job is the build and the
reading of it.

```sh
./scripts/addon-signal.sh build            # drive Pi (5-15 min)
./scripts/pi-session.sh summary            # what Pi claims it did
./scripts/pi-session.sh steps              # what it actually did
./scripts/addon-signal.sh verify --live --base
```

`build` refuses if the spec or the link is missing, rather than starting a
turn that cannot succeed. It drives Pi through the ordinary
`./scripts/pi-session.sh say`, so supervise it exactly as `AGENTS.md`
describes for the base build: the summary is a claim, `verify.sh` is the
evidence, and `pi-session.sh say` is how you push back.

**It goes quiet for 5–15 minutes while Pi works, and that is not a hang.**
Gaps of a minute between tool calls are normal. Watch it from another shell
with `./scripts/pi-session.sh steps`.

Pi's deliverable is `~/agent-bootstrap/setup-signal.sh` — a second,
standalone idempotent script, never `setup.sh`, so base idempotence stays a
measurement of the base build.

## What to watch for specifically

Three failures are much more likely than the rest, and two of them are
silent.

**The JVM ignores `http_proxy`.** signal-cli is a Java program, and the JVM
does not read the proxy environment variables everything else here uses. If
Pi does not pass `-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128` via
`JAVA_OPTS`, signal-cli opens a direct socket, the uid lockdown REJECTs it,
and the error is `java.net.SocketException: Network is unreachable` — with
no mention of a proxy anywhere. This is the same shape as the
httplib2/PySocks bug in the Google add-on. The cheapest proof it is working
is a line in squid's access log: `TCP_TUNNEL/200 CONNECT chat.signal.org:443`.
`verify.sh` checks for it.

**The wrong Java.** Hermes' Signal page says "Java 17+". That is wrong —
signal-cli 0.14 requires **Java 25**, and the arm64 package hard-depends on
it. Java 17 fails with a class-file-version error. Java 25 is in
`noble-updates`, not base `noble`.

**OpenClaw spawning its own signal-cli.** If OpenClaw is configured with
`transport.kind: "managed-native"` it starts a second signal-cli, which
collides with the daemon on the account data lock
(*"Config file is in use by another instance"*). It must be
`external-native`, pointed at the daemon Pi already runs.

`verify --live` sends a real Signal message to the allowed number. Nothing
short of that proves the link works — credentials and config can all be in
place over a dead link. `--base` re-runs the base suite to confirm this
add-on broke nothing. Then tell the user to do step 5.

## Adding another add-on

**Re-run the vendor's own doctor for every gateway this touched.** Unlike
the Google add-on, which is Hermes-only, this one can touch **both** — so
`verify.sh` runs `hermes doctor` *and* `openclaw doctor --lint --all
--json` when OpenClaw is configured. Keep the `--lint --all`: a bare
`openclaw doctor` selects 39 of 69 checks and has reported
`ok:true, findings:[]` while the full run found 33.

Neither doctor can be judged by its exit code. `hermes doctor` exits 1
whenever any optional integration is absent, and `openclaw doctor` exits 0
even when `ok:false`. Parse the output against the base suite's exclusion
list and print how many findings were filtered. Needing a *new* exclusion
is a signal the add-on broke something, not a reason to widen the list.

---

# Reference

## What this installs

| Piece | Where it comes from |
|---|---|
| `signal-cli` 0.14.x + a JRE 25 | the `packaging.gitlab.io/signal-cli` apt repo |
| a `signal-cli daemon --http` systemd **user** service | written by Pi |
| Hermes' Signal adapter | **bundled with Hermes** — nothing installed |
| OpenClaw's Signal channel | `openclaw plugins install @openclaw/signal`, only if OpenClaw is configured |

The adapters are the vendors' own. We install the dependency they both
name and configure them to use it. That is deliberate: this repo's rule is
to take the vendor's first-class mechanism rather than keep bespoke
scaffolding alive beside it.

### Why an apt repo, and the fallback if you do not want it

This repo's rule is *download, checksum, then execute — never pipe an
installer into a shell*. apt with a signing key is the stronger form of
that: a GPG-signed repository with a published SHA256 per package. The key
is fetched to a file, not piped.

The reason it is worth it is **arm64**. Upstream signal-cli publishes no
aarch64 build at all, and the Java library it depends on bundles a native
`.so` for x86-64 Linux only — AsamK confirms *"libsignal-client doesn't
include a Linux aarch64 native library"*. The usual workaround is to fetch
a third-party prebuilt `.so` and rewrite it into the jar, or build it from
Rust source (~40 minutes, several GB).

The arm64 package from this repo has already done that work. Verified by
unpacking it on 2026-11-09: its `libsignal-client-0.106.1.jar` contains a
`libsignal_jni.so` that `file` reports as
`ELF 64-bit LSB shared object, ARM aarch64`, and the published SHA256
matched the download byte for byte.

**If you would rather not use a third-party repo**, the documented fallback
is: take the upstream `signal-cli-0.14.x.tar.gz` and its `.asc`, verify
against AsamK's GPG key, read the exact libsignal version from the
`lib/libsignal-client-*.jar` filename, fetch the matching aarch64 `.so`
from `exquo/signal-libs-build`, and swap it into the jar. Do not hardcode
the libsignal version — it changes with signal-cli releases. On an x86-64
host none of this applies: upstream's native build works directly.

## A note on egress

The add-on needs Signal's servers, and **adds nothing to the allowlist**.
Everything Signal needs for text messaging is TLS on 443 —
`chat.signal.org`, `cdsi.signal.org`, `storage.signal.org`,
`svr2.signal.org`, `cdn*.signal.org` — and squid already allows the public
web on 443 in both phases. Nothing needs a non-standard port, and nothing
needs raw UDP (that is voice and video, which this does not enable).
`verify.sh` asserts no Signal domain was added, because an optional extra
that widens egress is changing the base system by the back door.

Signal pins its own certificates, which is fine here and is in fact the
supported configuration: our squid tunnels `CONNECT` without TLS
interception. Interception is what breaks signal-cli.

One failure mode to recognise: if the direct connection fails, Signal's
library falls back to domain-fronting through
`reflector-signal.global.ssl.fastly.net`, which the allowlist denies. That
surfaces as `Link request error: Connection closed!` — a message that looks
like a Signal outage and is not.

## Where the account data lives

Inside the VM, under signal-cli's data directory
(`~/.local/share/signal-cli/`), at 0700. It holds the account keys — the
thing that *is* your linked device. Treat it like a password; signal-cli's
own docs say so.

Consequences worth knowing:

- **Losing it means re-linking.** One more QR scan; nothing else is lost.
- **Do not copy it anywhere.** signal-cli takes a lock and refuses to run
  two instances against one data directory, and two processes sharing one
  device's keys will desynchronise the encryption ratchet.
- **It is not backed up by this repo**, and should not be. See
  `docs/snapshots.md` for why snapshots are not a reliable undo here.

## Two numbers, one daemon

If you do run both agents on Signal, it is still **one** signal-cli
service. Started without `-a`, the daemon loads every local account and the
JSON-RPC interface takes an `account` parameter per request. One service,
one data directory, two accounts — not two daemons.

## What the agent can and cannot do over Signal

| | |
|---|---|
| Text, both directions | yes |
| Attachments | supported by both adapters; not exercised by this add-on |
| Groups | supported; off unless you configure it |
| Live "tool progress" updates | **no** — Signal cannot edit a sent message, so Hermes suppresses progress bubbles. You get the final answer, not a running commentary. |
| Threads | no — Signal is DM-only in this sense |
| Voice and video | no, and no egress is opened for it |

Phone numbers are automatically redacted in Hermes' logs
(`+15551234567` → `+155****4567`).

## What `install` refuses to do

It stops rather than half-installing if the base build is missing or
failing, if `SIGNAL_ALLOWED_USERS` is empty, if no number is configured for
the agent you selected, if you have not linked yet, or if you asked for
`note-to-self` with OpenClaw — which cannot work, rather than appearing to
and then ignoring you.

## A risk to accept knowingly

**Signal publishes no bot API and does not bless third-party clients.**
Its terms prohibit "auto-messaging" without carving out personal
assistants. One human having a conversation with one assistant is a long
way from bulk messaging and is widely practised, but there is no documented
permission, and an account could in principle be restricted. That is your
risk to take, not something this repo can promise around. It is one more
reason to prefer a dedicated number over an account you depend on — though
Note to Self points the other way, so weigh it yourself.

## Undoing it

```sh
./scripts/addon-signal.sh remove
```

Stops and removes the daemon, deletes the add-on's config, and tells you
what to have Pi undo. It does **not** unlink from Signal's side — only you
can do that, from your phone: **Signal → Settings → Linked devices**, swipe
the device, remove. Do that too if you are removing this because something
went wrong.

---

## What this means for Telegram

The next task is making Telegram an add-on like this one, so a user can
choose their channel instead of getting Telegram whether they want it or
not. Notes toward that, recorded here because building Signal is what
surfaced them:

Telegram is currently held in the base build in six places:

1. `bootstrap.sh` — exits 2 on blank `*_TELEGRAM_BOT_TOKEN` and
   `TELEGRAM_ALLOWED_USER_ID`. This is the load-bearing one: it is the only
   cue a user gets that the build is waiting on them.
2. `config/agents.env.example` — three Telegram values, documented as "part
   of the base build, not an extra".
3. `spec/pi-target-state.md` — a *Telegram channels* section, plus the
   `TELEGRAM_BOT_TOKEN`-vs-`OPENCLAW_TELEGRAM_BOT_TOKEN` trap.
4. `verify/verify.sh` — six checks, including both "never reachable without
   an allowlist" assertions.
5. `config/allowlist-*.conf.example` — `api.telegram.org` in both phases.
6. `scripts/check-telegram-tokens.sh` and `check-telegram-polling.sh`.

Moving the files is the easy part. **The hard part is keeping "never
reachable without an allowlist" provable when zero, one or two channels may
exist.** Today those checks can assume Telegram and fail if it is wrong. In
an add-on world they have to become "for each configured channel, assert
its allowlist", and a build with no channel at all must pass without that
reading as a silent skip — `AGENTS.md` is explicit that a SKIP looks like a
PASS in a thirty-line run.

The second question is what the base build's final manual check becomes. It
is currently "message each bot and watch it fetch a web page", and it is
the single most valuable check in the repo precisely because it is not
automated. With no channel in the base, there is nothing to message, and
the base build can no longer prove an agent answers *anything*. That needs
an answer before Telegram moves, not after.

Suggested order: build Signal, prove it, then move Telegram using whatever
shape Signal settled on. Doing it the other way round means designing the
general case from one example.
