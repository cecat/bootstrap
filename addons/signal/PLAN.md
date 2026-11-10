# Signal add-on — the plan

**Status: planned, not built. Nothing in this directory has run, and the VM
was not touched.** Written 2026-11-09/10 while the repo owner was away, from
vendor documentation and a handful of host-side measurements described below.

Read this before `README.md`. The README is written as if the add-on works;
this file is why it should, what is still unknown, and where it could go
wrong.

## If you read only this box

- **Both vendors already ship Signal.** Hermes has a bundled Signal
  adapter, OpenClaw an official plugin; both drive **signal-cli**. We
  install one dependency and configure their adapters. Nothing bespoke.
- **Hermes can run on your own number**, via Signal's *Note to Self* —
  no second phone number, no SIM, no captcha, one QR scan. It is a
  documented Hermes feature. **OpenClaw cannot do this.** Recommended
  starting point.
- **Two agents on Signal would need two numbers**, because Signal
  broadcasts every message to every linked device and both would reply.
- **arm64 works** — the third-party apt package already bundles a real
  aarch64 `libsignal_jni.so`, verified by unpacking it. Without that,
  this would have meant a Rust build. Needs **Java 25** (Hermes' docs
  say 17 and are wrong).
- **The likeliest failure is silent:** the JVM ignores `http_proxy`, so
  signal-cli must get `-Dhttps.proxyHost` or it bypasses squid and dies
  with a misleading "Network is unreachable".
- **Two decisions are waiting on you** — see *Open questions* at the end.
  Nothing else blocks starting.

---

## The short version

Both vendors already ship Signal. **We are installing almost nothing.**

- **Hermes** has a bundled Signal platform adapter: `plugins/platforms/signal/`,
  configured with `SIGNAL_ACCOUNT`, `SIGNAL_HTTP_URL`, `SIGNAL_ALLOWED_USERS`.
  Its docs: *"Hermes connects to Signal through the signal-cli daemon running
  in HTTP mode. The adapter streams messages in real-time via SSE and sends
  responses via JSON-RPC."* No extra Python packages — *"The Signal adapter
  uses `httpx` (already a core Hermes dependency)."*
- **OpenClaw** has an official Signal channel plugin, `@openclaw/signal`,
  with `channels.signal.dmPolicy` / `allowFrom` — the same allowlist shape
  Telegram already uses here. *"OpenClaw does not embed libsignal."*

Both drive the same external dependency: **signal-cli**. So the add-on is
one package install, one daemon, one human linking step, and the config and
checks around them. That is the same shape the Google add-on ended up with
after it moved off its bespoke MCP server, and for the same reason
(`AGENTS.md`: *prefer the vendor's built-in mechanism*).

The expensive part is not software. It is that **Signal has no bot API**:
an account is a phone number, and getting one for an agent is a human
errand with real trade-offs. Most of this plan is about that — and about
the one route that avoids the errand entirely, which Hermes supports and
OpenClaw does not.

---

## What was actually measured, and what is taken on trust

Pat's standing instruction is to prefer verifiable statements. So,
explicitly:

### Measured on this host tonight

| Claim | How |
|---|---|
| signal-cli 0.14.10 is current (2026-11-07) | GitHub releases API |
| Upstream publishes **no** arm64 asset | release asset list: JVM, `Linux-native`, `Linux-client`, json-schemas, and `.asc` files — nothing aarch64 |
| An arm64 apt repo exists and is current | `packaging.gitlab.io/signal-cli`, `Release` names `Architectures: arm64 amd64`, dated 2026-11-07 |
| `signal-cli-jre` 0.14.10 exists for arm64 | its `Packages` entry |
| **That deb bundles an aarch64 `libsignal_jni.so`** | downloaded the 137 MB deb, `dpkg-deb -x`, `unzip -l` the jar, `file` the library → `ELF 64-bit LSB shared object, ARM aarch64` |
| Its published SHA256 is correct | `sha256sum` matched `644581…d270` byte for byte |
| It needs exactly Java 25 | `Depends: java-runtime-headless (= 25)` |
| `openjdk-25-jre-headless` exists for arm64 | in **`noble-updates`**, not `noble` |
| The VM is aarch64 and has no Java at all | `limactl list`; `grep -i java lima/agents.yaml spec/` finds nothing |
| The base build is currently green | `./verify/verify.sh` — 0 failed, 2 skipped |

That `libsignal_jni.so` finding is the one that decides whether this add-on
is a weekend or a fortnight, so it was checked by hand rather than believed.
**Upstream's own tarball would not work here**: it bundles
`libsignal_jni_amd64.so` and nothing for Linux arm64, and AsamK confirms
(issue #1986) *"libsignal-client doesn't include a Linux aarch64 native
library."* The usual arm64 workaround is to download a third-party
prebuilt `.so` and rewrite it into the jar, or build libsignal with Rust
(~40 min, several GB). **The morph027 arm64 deb has already done that
work** — its jar carries a real aarch64 `libsignal_jni.so` alongside the
upstream amd64 one. That removes the single largest risk in this add-on,
and it is why the plan uses apt rather than the release tarball.

### Tested, where testing was possible without the VM

The scripts in this directory have never been run against a real build,
but the parts that can be exercised in isolation were:

- **the E.164 validator**, against 14 inputs — accepts
  `+15551234567`, `+447911123456`; rejects `(555) 123-4567`,
  `+1 555 123 4567`, a bare `15551234567`, an over-long number, and
  `+1555$(whoami)`;
- **the `signal.env` parser**, which reads values with `awk` rather than
  sourcing the file — confirmed it strips quotes and whitespace, returns
  empty for absent keys, and does **not** execute a `$(...)` planted in a
  value. The Google add-on parses its env file the same way for the same
  reason;
- **the config handshake end to end**, in a scratch repo: blank config
  exits 2 with the STOP message, `note-to-self` plus OpenClaw is refused
  with an explanation, a malformed number is refused, and a valid config
  proceeds to the real preconditions;
- **the allowlist comparison**, against five list shapes.

Two real bugs were found this way and fixed, both of which would have
been invisible on a reading:

- `grep -c … || echo 0` prints **`00`** when nothing matches, because
  `grep -c` already prints `0` *and* exits 1. The caller compared that to
  `0`, found a difference, and would have reported an **unlinked account
  as linked** — the precondition that gates everything else. Now
  `|| true`.
- the allowlist check grepped for the whole comma-separated list as one
  string, so any user with two allowed numbers would have been told their
  correctly-restricted agent was misconfigured. Now each number is
  checked separately, and a non-E.164 entry skips with a reason rather
  than failing confusingly.

### Taken from vendor documentation, not yet observed

Everything about how the two adapters behave once running. In particular
the Hermes SSE/JSON-RPC wiring and the OpenClaw `transport.kind` modes are
documented but unexercised here. Treat the first build as the measurement.

The one place the scripts guess rather than know is the exact output of
`signal-cli listAccounts`, which `linked_accounts()` pattern-matches. The
match is deliberately loose, and the first real run should confirm it.

### One vendor doc is wrong

Hermes' Signal page says *"Java 17+ runtime — required by signal-cli"*.
signal-cli 0.14's README says **JRE 25**, its Gradle build pins
`VERSION_25`, and the arm64 deb hard-depends on `java-runtime-headless (= 25)`.
Java 17 fails with a class-file-version error. Follow signal-cli, not Hermes,
and expect to need `noble-updates` — Java 25 is not in base `noble`.

---

## The sandbox question, which could have killed this

The VM's iptables chain ACCEPTs loopback, DNS, and the model gateway, then
REJECTs. Everything else must traverse squid on `127.0.0.1:3128`, which
allows 80/443 and `CONNECT` only to 443. **signal-cli is a Java program and
the JVM does not read `http_proxy`/`https_proxy`** — confirmed in signal-cli
issues #1856 and #1494, where the symptom is
`java.net.SocketException: Network is unreachable` from a raw socket, with
no mention of a proxy anywhere. That is exactly this repo's worst failure
shape: the silent bypass, the same class of bug as the httplib2/PySocks
problem in the Google add-on.

**It does work, with two conditions.**

1. **Proxy via JVM system properties**, passed through `JAVA_OPTS`:
   `-Dhttps.proxyHost=127.0.0.1 -Dhttps.proxyPort=3128` (and the `http.*`
   pair). Confirmed working *against Squid specifically* in signal-cli
   issue #1772.
2. **Version ≥ 0.13.22.** signal-cli has two network stacks: OkHttp (which
   falls through to `ProxySelector.getDefault()` and honours the properties)
   and libsignal's Rust `Network` for the chat websocket and CDSI. The
   second only started honouring the proxy when signal-cli began pushing
   the JVM setting into it —
   `libSignalNetwork.setProxy("http", addr.getHostName(), addr.getPort(), …)`
   in `SignalDependencies.java`. Before that, CDSI resolved DNS locally and
   connected by raw IP, bypassing the proxy. Fixed in libsignal 0.81.0,
   shipped in signal-cli 0.13.22. We are installing 0.14.10, comfortably
   past it.

Everything Signal needs for text messaging is TLS on **443** —
`chat.signal.org`, `cdsi.signal.org`, `storage.signal.org`, `svr2.signal.org`,
`cdn*.signal.org`. Nothing needs a non-standard port and nothing needs raw
UDP (that is voice/video, which we are not enabling). Since squid already
allows the public web on 443, **this add-on should need no allowlist change
at all** — the same happy accident the Google add-on had, and `verify.sh`
should assert it, because an optional extra that widens egress is changing
the base system by the back door.

**Certificate pinning is fine and is in fact the supported configuration.**
Signal pins its own CA. AsamK: *"as long as the proxy just passes through
the https stream it should work."* Our squid does no TLS interception.
Interception is what breaks signal-cli (issue #1565, unresolved) — we do
not do it.

One documented trap worth pre-empting: if the direct connection fails,
libsignal falls back to domain-fronting via
`reflector-signal.global.ssl.fastly.net`. Under a narrow allowlist that is
denied and surfaces as `Link request error: Connection closed!`
(issue #2074) — a message that looks like a Signal outage and is not.

**The cheapest possible evidence that the proxy path works** is a line in
squid's own access log: `TCP_TUNNEL/200 CONNECT chat.signal.org:443`. If
signal-cli hangs and that line is absent, the JVM properties did not take
effect. That single grep separates "proxy misconfigured" from "allowlist too
narrow" from "Signal is down", and it costs nothing. It belongs in
`verify.sh`.

---

## The hard part: one agent or two, and whose phone number

This is the decision that shapes the add-on, and it is the user's to make,
so the add-on asks rather than assumes (`SIGNAL_AGENT` in `signal.env`).

**Short answer, if you read nothing else in this section:** start with
Hermes alone, linked to your own number, and talk to it through Signal's
*Note to Self*. It needs no second phone number, no captcha, and nothing
bought — Hermes supports it as a documented feature. Everything below is
why, and what the alternatives cost.

### Why two agents cannot share one Signal account

Telegram gives you unlimited free bots, so the base build gives each agent
its own. Signal gives you neither. And the natural workaround — link
signal-cli twice to one account as two devices — **does not work**, because
Signal delivers every message to *every* linked device. That is the entire
point of linked devices. Two agents on one account therefore both see every
message and both reply: the user gets doubled answers, and two agents with
shell access may end up talking to each other. Signal has no per-device
addressing to separate them with.

This was checked in signal-cli's source rather than assumed. The SSE
fan-out in `SseEventBuffer.java` sends each event to *every* connected
client whose manager set contains the account —

```java
receivers = clients.stream().filter(c -> c.managers.contains(m)).toList();
for (final var client : receivers) { client.send(event); }
```

— with no arbitration and no at-most-once delivery, and `subscribeReceive`
registers an additional independent listener per subscriber. Hermes' own
troubleshooting table says the same thing from the other end: *"Duplicate
messages | Ensure only one signal-cli instance is listening on your phone
number."* Two agents, one account, is a certain double-reply.

So: **two agents on Signal means two phone numbers.** That is a real cost
to put in front of the user before they start, not after. The add-on
defaults to one agent (Hermes, which has the richer Signal adapter and
already owns the Google add-on) and supports adding the second later.

### One daemon, though, not two

`signal-cli daemon` without `-a` loads **all** local accounts (man page:
*"If no `-a` account is given, all local accounts will be loaded"*), and in
that mode the JSON-RPC interface takes an `account` parameter —
`signal-cli-jsonrpc(5)`: *"In multi-account mode, requests for a single
account require an additional `account` param"*, and *"Receive events
identify them by ACI in the `account` field."* So even the two-number case
is **one systemd service**, one data directory, two accounts. That is much
better than two daemons and is the shape to build toward.

The opposite constraint is enforced in code, not just advised: `SignalAccount`
takes a `fileChannel.tryLock()` and throws *"Config file is in use by another
instance"*. Single-writer, per data directory. Two consequences:

- the daemon is the only thing that touches account data; both adapters
  speak to it over HTTP;
- **OpenClaw must use `transport.kind: "external-native"`, never
  `managed-native`** — the managed mode spawns its own signal-cli, which
  would collide on that lock. This is the single easiest way to get this
  wrong and it fails at runtime, not at config time.

One thing to check at build time rather than assume: the SSE endpoint
filters by account server-side, but it is unconfirmed whether Hermes'
adapter passes an account query parameter. If it does not, a two-account
daemon would show Hermes both accounts' traffic and it would have to filter
client-side. Irrelevant for a single-account install; verify before adding
the second.

### Getting a number: link, don't register

| | Link (secondary device) | Register (primary) |
|---|---|---|
| What it is | signal-cli becomes a linked device, like Signal Desktop | signal-cli owns the number outright |
| Human step | scan a QR once | SMS/voice code **plus a captcha** |
| Needs a phone | yes — the number must already run Signal | no |
| Captcha | none | solved in a browser, and *"you need to open the page on the same device that runs the register command (or at least a device that has the same external IP address)"* |
| Side effect | none | **de-authenticates the Signal app on that number** |

**Link.** The captcha's same-external-IP requirement is close to fatal here:
the VM has no browser, and its traffic leaves through squid, so a captcha
solved on a laptop may be rejected outright. Linking avoids it completely.
Registration also silently evicts the phone app from that number, which is
a nasty surprise to hand anyone. Registration stays documented in the README
as the path for someone who has a spare number and no spare handset, but
the add-on does not automate it.

### Linking headlessly, given this user cannot copy text

`signal-cli link` prints a `sgnl://linkdevice?uuid=…&pub_key=…` URI, and
since 0.14.0 also renders a QR code in the terminal — **but only when
stdout is a TTY**, which it will not be when a script captures it. The man
page says so: *"If signal-cli is not running in a terminal, only the URI is
printed and you can create a QR code from it yourself (e.g. with qrencode)."*

So the add-on renders the QR itself, host-side, with `qrencode -t UTF8`, and
prints it into the SSH session for the user to point a phone at. This suits
the constraint in memory that **Pat cannot copy text out of his terminal** —
a QR is scanned, not transcribed. A 100-plus-character `sgnl://` URI is
exactly the thing never to hand him as text.

Two further notes:
- the JSON-RPC `startLink`/`finishLink` pair returns the URI as JSON with no
  TTY dependency, which is cleaner than scraping stdout if the daemon is
  already running. Worth preferring if it works; fall back to parsing
  `link` output.
- *"Do not kill the `signal-cli link …` process until linking is finished"* —
  it exits by itself. A timeout that kills it early leaves a half-linked
  account.

### The zero-cost option, which turns out to be real — for Hermes only

"Link it to my own number" costs nothing and needs no second phone, so it
occurs to everyone. The expectation was that it fails on loop protection.
**For Hermes it does not fail: it is a documented, named feature**, and
that changes the recommendation.

Hermes' Signal page, verbatim (`llms-full.txt` line 33045):

> **Note to Self (Single-Number Setup)**
> If you run signal-cli as a **linked secondary device** on your own phone
> number (rather than a separate bot number), you can interact with Hermes
> through Signal's "Note to Self" feature. Just send a message to yourself
> from your phone — signal-cli picks it up and Hermes responds in the same
> conversation.
>
> - "Note to Self" messages arrive as `syncMessage.sentMessage` envelopes
> - The adapter detects when these are addressed to the bot's own account
>   and processes them as regular inbound messages
> - Echo-back protection (sent-timestamp tracking) prevents infinite loops
>   — the bot's own replies are filtered out automatically
>
> **No extra configuration needed.** This works automatically as long as
> `SIGNAL_ACCOUNT` matches your phone number.

That removes the entire second-phone-number errand for a Hermes-only
install. The user links signal-cli to the Signal account already on their
phone, scans one QR, and talks to the agent in Note to Self. No new SIM, no
captcha, no de-authentication, nothing to buy.

**OpenClaw explicitly does not support this.** Its docs: *"Running the bot
on your personal Signal account makes it ignore your own messages (loop
protection). For 'I text the bot and it replies,' use a separate bot
number."* There is no Note-to-Self handling in its Signal adapter.

So there are two sane configurations, and the add-on should offer both:

| | Note to Self | Dedicated number |
|---|---|---|
| Agents | **Hermes only** | either, or both |
| Costs | nothing | a number per agent, each with Signal on a phone |
| Identity | shares yours | the agent has its own |
| Talk to it by | messaging yourself | messaging its number |
| Caveat | agent replies appear in your own Note to Self thread on all your devices | — |

**Recommendation: start with Note to Self on Hermes.** It is the shortest
path to a provably working channel, it needs nothing bought or registered,
and it is reversible — unlinking is one action in the phone's Linked
Devices screen. Move to a dedicated number if the shared identity grates,
or when OpenClaw is added, which requires one.

A consequence worth stating, because it is a real downside and the kind of
thing a user discovers at the wrong moment: in Note-to-Self mode, the
agent's replies are sent *as you*, so they appear in your own Note to Self
thread on your phone, your desktop, everywhere. It is not a separate
conversation. For a personal assistant that is mostly fine; for anyone who
uses Note to Self as a scratchpad it will be an intrusion.

**If a dedicated number is chosen**, the cheapest real-world routes are a
second number on a dual-SIM phone, an old handset with a prepaid SIM, or a
VoIP number. On VoIP, be straight with the user: Signal publishes no policy
— its stated requirement is only that the number *"must be able to receive
an insecure SMS or phone call"* — and anti-abuse behaviour is deliberately
opaque and varies by range. Treat VoIP as try-it-and-see with a real SIM as
the fallback, and do not design around it working.

---

## What gets built

Same five pieces as the Google add-on, same division of labour.

```
addons/signal/
  README.md          the user's half, then the coding agent's half
  PLAN.md            this file
  spec.md            what Pi builds inside the VM
  install.sh         link / install / build / verify / remove
  verify.sh          the evidence
  signal.env.example the config template
scripts/addon-signal.sh    one-line wrapper, so the committed
                           Bash(./scripts/*.sh*) permission already covers it
```

Nothing in `bootstrap.sh`, `lima/agents.yaml`, `spec/pi-target-state.md` or
`verify/verify.sh` changes. That is the rule the Google add-on established
and it is what makes an add-on optional in fact rather than in name.

### Division of labour

Per `AGENTS.md`: the user does only what a human must; the coding agent runs
everything else.

**The user** (needs a phone, a second number, and a scan):
1. gets a number and puts Signal on a phone with it;
2. fills in `config/signal.env`;
3. runs `link` and scans the QR with that phone;
4. at the very end, messages the agent and watches it answer.

**The coding agent**: `install`, `build`, supervising Pi, `verify`, and
reading Pi's claims against the evidence.

`install` stops at the hand-over and prints the sentence to give the coding
agent — the same boundary the Google add-on draws, for the same reason.

### Execution order, with what each step proves

1. **`link`** — host-side? **No. This one is the exception, and it matters.**

   Linking must happen *inside the VM*, because the account keys it creates
   are the thing signal-cli uses forever and they belong in the VM's data
   directory. Copying a linked data dir around is explicitly discouraged
   (single-writer), and pushing keys in from the host would make the host a
   place where Signal account material lives. So the flow is: the script
   asks the VM to start a link, gets the `sgnl://` URI back, and renders the
   QR **on the host terminal** where the user can see it. Only the URI
   crosses the boundary, and it is single-use and short-lived.

   This is a real difference from the Google add-on, where consent happens
   host-side precisely *because* the VM has no browser. Here there is no
   browser involved at all — just a QR on a screen and a camera. Worth
   stating plainly in the README so nobody "fixes" it later.

2. **`install`** — preconditions and staging. Refuses on: base build absent
   or failing, `SIGNAL_ALLOWED_USERS` empty, no number configured, not yet
   linked. Re-runs the base `verify.sh` first (3–6 min, and it must say so —
   silence reads as a hang). Stages `spec.md` at
   `~/agent-bootstrap/SIGNAL-ADDON.md`, then stops and hands over.

3. **`build`** — one short Pi turn. Pi's deliverable is
   `~/agent-bootstrap/setup-signal.sh`, a second standalone idempotent
   script, never `setup.sh`.

4. **`verify --live`** — the evidence.

### What Pi does, and what it must not

Pi installs the apt repo key and source, installs `openjdk-25-jre-headless`
and `signal-cli-jre`, writes a systemd **user** service running
`signal-cli daemon --http 127.0.0.1:<port>` with `JAVA_OPTS` carrying the
proxy properties, and wires whichever adapter(s) `SIGNAL_AGENT` names.

Hard rules in the spec, each tracing to something that has already gone
wrong in this repo:

- **never print a credential** — and here that extends to **phone numbers**,
  which are personal data and would otherwise land in a host-side Pi
  transcript. Report counts and shapes, not values.
- **never run `link`, `register` or `verify`.** Linking is the human's step
  and is already done by the time Pi runs. A second link would create a
  second device and a second mess.
- **restrict before enabling.** The allowlist is set before the adapter can
  ever answer, exactly as the base spec requires for Telegram.
- **do not touch `setup.sh`**, and do not change Telegram config.
- **three failures of the same thing, then stop and write up.** The 56- and
  45-attempt grinds are in `docs/gotchas.md`; the spec says so explicitly.
- **restart each gateway once, at the end**, not per step.

An honest flag for the spec: the apt route conflicts slightly with this
repo's *"download, checksum, then execute — never pipe"* rule, which is
written for `curl | sh` installers. apt-with-a-signing-key is the stronger
form of the same idea (signed repo, per-package SHA256), and the key is
fetched to a file rather than piped. The spec should say that out loud
rather than appear to ignore the rule. The repo key's SHA256 should be
pinned in the spec so a swapped key is visible.

---

## Checks worth having, and checks deliberately not written

`AGENTS.md` is blunt that a suite which checks everything becomes the thing
you debug. So, against its four questions:

**Worth having:**

| Check | Which failure it catches |
|---|---|
| `SIGNAL_ALLOWED_USERS` / `allowFrom` non-empty **and** matches the configured number | the repo's one non-negotiable: a reachable agent anyone can message |
| squid log shows `TCP_TUNNEL/200 CONNECT chat.signal.org:443` | the silent JVM-proxy bypass — the single most likely failure, and invisible otherwise |
| no Signal domain added to the allowlist | an add-on widening egress by the back door |
| no phone number written into any config file in plaintext | the repo already checks this shape for bot tokens |
| signal-cli data dir is 0700 | *"contains account credentials — protect it like a password"* |
| `hermes doctor` **and** `openclaw doctor --lint --all --json`, parsed not exit-coded | `AGENTS.md` requires both after any add-on that touches both gateways. This one does, unlike Google's. |
| a live send from the daemon to the allowed number (`--live`) | everything above can pass with a dead link |

**Deliberately not written:**

- *Does the agent reply on Signal?* Left to the human, like Telegram. An
  automated version teaches the user to stop looking, and the base suite's
  own history is that every automated check passed while an agent sat mute.
- *Is signal-cli the newest version?* Breaks on the vendor's release
  schedule, not on our bug.
- *Message-content assertions.* Appearance, not behaviour.

---

## Risks, honestly

1. **The arm64 story depends on a one-maintainer third-party apt repo.**
   This is the real exposure. Mitigations: the repo is GPG-signed, the
   per-package SHA256 is published and verified, and it tracks upstream
   within days. The fallback — upstream tarball plus a hand-swapped
   aarch64 `.so` from `exquo/signal-libs-build`, with the libsignal version
   parsed from the jar filename rather than hardcoded — should be written
   into the README as a documented Plan B rather than discovered later.
   On amd64 hosts the upstream native build works and none of this applies.
2. **Java 25 plus signal-cli is ~400 MiB** and a JVM daemon's RSS is
   plausibly 250–450 MB, unmeasured. The VM has 8 GiB and 60 GiB shared
   with two agents. Probably fine; cap with `-Xmx` and measure rather than
   assume.
3. **No vendor blessing.** Signal publishes no bot API, and its terms
   prohibit "auto-messaging" without carving out personal assistants.
   One human, low volume, is widely practised and far from bulk messaging —
   but there is no documented permission, and an account could in principle
   be restricted. Say so in the README; it is the user's risk to accept.
4. **Hermes' Signal page is thinner than its Telegram page**, and its Java
   version is already demonstrably wrong. Expect at least one thing in it
   not to match the installed build. The spec tells Pi to trust the software
   over the document and say so — the same instruction that has worked
   before.
5. **Messages can be missed while the daemon is down.** Signal queues
   server-side and delivers on reconnect, which is the good case. The bad
   case is documented for the REST wrapper's `on-start` mode, where messages
   arriving with no subscriber attached are *"silently dropped"*. We are not
   using that wrapper, but the receive-mode choice should be deliberate
   rather than defaulted — which is precisely the standard
   `docs/config-audit-2026-11-09.md` sets.

---

## Deliberately deferred

- **Attachments, groups, reactions, typing indicators.** All supported by
  both adapters; none needed to prove the channel works. One-to-one text
  first.
- **Registration-as-primary automation.** Documented, not scripted.
- **Signal for OpenClaw in the first pass.** The plumbing is written to
  support it and `SIGNAL_AGENT=both` is accepted, but the first build should
  prove one agent end to end. OpenClaw also needs a plugin install from
  ClawHub/npm, which is a second moving part — and it cannot use Note to
  Self, so it forces the dedicated-number path on the whole install.
- **Making Telegram an add-on.** Pat's stated next task, and it is the right
  order: do this one first and let it establish the pattern. Notes toward it
  are in `README.md` under *What this means for Telegram* — the short
  version is that `bootstrap.sh`'s exit-2 gate, `agents.env.example`,
  `spec/pi-target-state.md`'s Telegram section and six `verify.sh` checks
  are what hold Telegram in the base, and that the honest hard part is not
  moving them but keeping *"never reachable without an allowlist"* provable
  when zero, one or two channels may exist.

---

## Open questions for Pat

Four decisions. Only the first two block starting.

1. **Note to Self, or a dedicated number?** I recommend **Note to Self on
   Hermes**: no second number, no captcha, nothing bought, one QR scan, and
   it is a documented Hermes feature rather than a trick. The cost is that
   the agent shares your Signal identity and its replies land in your own
   Note to Self thread on every device you own. If that is unappealing, the
   alternative is a dedicated number — say which and I will build for it.
2. **OpenClaw too, or Hermes only?** OpenClaw cannot do Note to Self, so
   adding it means a dedicated number and a second linked account. I would
   leave it out of the first pass and prove one agent end to end.
3. **Is the third-party apt repo acceptable?** It is the difference between
   a clean install and a jar-patching exercise on arm64. I would take it —
   GPG-signed, per-package SHA256 verified, and I confirmed its arm64 deb
   ships a genuine aarch64 `libsignal_jni.so` by unpacking it tonight. The
   documented fallback stays in the README either way.
4. **Is Signal's lack of an official bot API an acceptable risk?** Low
   volume, one human, but unblessed by Signal and not something this repo
   can promise around.

Nothing here is urgent and nothing has been built. Answer 1 and 2 and the
rest follows.

---

## When you come back: the order to run things

Assuming Note to Self on Hermes, which needs nothing bought.

```sh
# you, once -- fill in SIGNAL_MODE, your number, and the allowlist
./scripts/addon-signal.sh install      # exits 2, tells you what it wants
$EDITOR config/signal.env

# you, once -- installs signal-cli (3-8 min), then shows a QR code
./scripts/addon-signal.sh link         # scan it: Signal > Settings >
                                       # Linked devices > +

# you -- preconditions, push, stage, then it hands over
./scripts/addon-signal.sh install

# your coding agent from here
./scripts/addon-signal.sh build
./scripts/pi-session.sh summary
./scripts/addon-signal.sh verify --live --base

# you, last -- message yourself on Signal and ask the agent for a web page
```

Two things I would watch on the first run, because they are the most
likely to be wrong and the least likely to announce themselves:

1. **Does `signal-cli --version` work after install?** That one command
   proves the aarch64 native library loaded. I verified the library is in
   the package by unpacking it here, but "present in the deb" and "loads
   on that VM" are different claims.
2. **Does squid's log show `CONNECT chat.signal.org:443`?** If not, the
   JVM proxy properties did not take effect and everything will hang with
   a misleading error. `verify.sh` checks this, and it is the check I
   would read first.

If the build fails, the likeliest causes in order are: Java 25 missing
because `noble-updates` is not enabled, the proxy properties not reaching
the *service* (as opposed to the shell), and `listAccounts` output not
matching the pattern `linked_accounts()` expects. All three are cheap to
diagnose and none require touching the VM by hand.
