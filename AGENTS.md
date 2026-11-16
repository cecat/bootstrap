# Build instructions for a coding agent

*(`CLAUDE.md` is a symlink to this file. `AGENTS.md` is the cross-tool
convention — Codex, Cursor, Warp, Gemini CLI and Aider look for it; Claude
Code looks for `CLAUDE.md`. Same content either way.)*

## What this is

A Lima VM that cannot see the host filesystem and cannot reach the host or
its local network. Inside it live an OpenClaw agent and a
Hermes agent, reaching the same models you are using right now — installed
not by you but by **Pi**, a coding agent running *inside* the VM, working
from `spec/pi-target-state.md`.

You are the supervisor. Pi builds; you check.

```sh
./bootstrap.sh                      # deterministic steps; stops before Pi
./scripts/pi-session.sh build       # Pi builds, headless, ~30 min
./scripts/pi-session.sh summary     # what Pi claims it did
./scripts/pi-session.sh steps       # what it actually did, tool call by tool call
./scripts/pi-session.sh say "..."   # push back, same session
./scripts/finish-build.sh           # idempotence, narrow egress, verify
./verify/verify.sh --models         # the evidence
```

`bootstrap.sh` never prompts. It stops once, early, with exit 2 if
`config/agents.env` needs filling in — two agent names, a Telegram bot
token per agent, and a numeric user id. Telegram is part of the base
build: blank tokens give you mute agents and make the one manual check
(message an agent, watch it fetch a web page) impossible.

**That file is the user's to edit, and relaying the stop is your job.**
Nothing else will cue them. When you hit that exit, say plainly that the
build is paused and waiting on them, name the four values, point at
`config/agents.env`, and then *stop and wait* — do not fill it in, do not
guess names, and do not carry on to the next command. Re-running
`./bootstrap.sh` is how they tell you they are done.

Never ask for a secret in conversation; a token pasted into a chat is a
token in a transcript. Ask them to type it into the file, in an editor,
where you will not see it.

## Who runs what — the division this repo is built on

**You run the scripts. The user does only what a human must.**

That is the whole shape of this thing, and it holds for add-ons as much
as the base build. A human must: make an account, click through a
browser consent screen, type a secret into a file, and message a bot to
see whether it answers. **Everything else is yours** — running
`bootstrap.sh`, driving Pi, reading its summary against `verify.sh`,
pushing back when it over-claims, and diagnosing what broke.

The failure mode is yours, not theirs: handing a command back with
"now run this" when nothing stopped you from running it. If you are
about to ask the user to run something, first say why — and *"it feels
like their decision"* is not a reason. A real reason is one of:

- it needs a browser, an account, or a phone;
- it needs a secret that must not pass through this conversation;
- it is destructive or hard to reverse (see the rules below);
- the permission allowlist denies it, which is deliberate and narrow.

`.claude/settings.json` allows `./bootstrap.sh`, `./scripts/*.sh`,
`./verify/verify.sh`, `git`, and two read-only `limactl` probes
unattended. Any other `limactl shell agents -- ...` is deliberately not
on that list, so it stops for the user's approval — and that prompt is
the "fix the spec, not the VM" rule surfacing. Being stopped there means
stop reaching into the VM: do not ask the user to approve it, and do not
hand them a shell command to run on your behalf.

A long-running script is not a reason to hand it over either. Run it in
the background and say how long it will take.

**Where the hand-off does belong**, the script makes it, and says so:
the user supplies what only they can, the script stops, and it prints
what it is waiting for. `bootstrap.sh`'s exit 2 is one. The Google
add-on's `auth` is another: it exits 2 until the user has made an OAuth
client, then prints a consent URL only their browser can open — you run
it, they click. Mid-procedure is the wrong place to invent a new one.

(That add-on's `install` used to end by telling the *user* to go and
brief their coding agent. Nothing in it needed a human; it was this
section's failure mode with the direction reversed.)

## Tell the user which models their agents run

**Name the models when you report a build.** Not the endpoint, the
models — "Hermes and OpenClaw are both on `argo:claude-5-opus`". It is
one line and it closes a hole that cost a user weeks: both agents were
silently built on `argo:gpt-4o`, an installer default nobody chose, and
nothing in the build ever said so. The suite was green the whole time,
because it only asked whether a completion succeeded.

`verify.sh` now prints both in its summary. Repeat it in your own
report rather than assuming they read it.

**The user may change a model, and should be told they can.**
`config/agents.env` names `argo:claude-5-opus` as `AGENT_MODEL`; the
gateway offers more (its `/v1/models` lists them). When they ask for a
different one, that value is the one place it lives — the spec and
`verify.sh` both read it — so: they edit it, you re-run `./bootstrap.sh`,
have Pi re-apply, and re-run the suite (`docs/updating.md`). Changing it
only inside the VM is the "fix the spec, not the VM" violation, and the
next build silently reverts it.

## Work out where you are first

```sh
limactl list                                            # does the VM exist?
limactl shell agents -- cat /etc/agent-sandbox/phase    # bootstrap | runtime
./verify/verify.sh                                      # costs nothing, says a lot
```

No VM → `bootstrap.sh`. VM up, phase `bootstrap`, nothing built →
`pi-session.sh build`. Anything else → read `verify.sh` output before acting.

## Your actual job is supervising Pi

Pi is good at this — it has built the whole target state in half an hour and
passed 34 of 35 checks first try. It also over-claims: it has reported
success over guards that could never match, over channel code whose active
branch did nothing, and over an agent it never renamed. Its summary is a
claim. `verify.sh` is evidence.

So read the summary sceptically, then run the suite. Watch for log lines
announcing work the code below them does not do, and for negative claims
("X is blocked") made without a command behind them.

**And verify Pi before assuming it is wrong.** Several `verify.sh` checks
have been wrong while Pi was right, and on 2026-10-30 five supervisor
theories about one failure were wrong before Pi found the real cause in a
single short turn.

**Keep your prompts short.** Fifty-line supervision prompts have hung this
setup; two sentences have worked in the same session minutes later. State
the symptom, the measurement, and what you want — then let Pi investigate.

When Pi is wrong, push back with `pi-session.sh say "..."`. When the *spec*
is wrong, fix `spec/pi-target-state.md`. Read `docs/gotchas.md` before
debugging anything.

## The perfect is the enemy of the good enough

**Complexity has to be paid for in reliability.** A suite that checks two
hundred possible problems is itself larger than the system it checks, and
then you are debugging the scaffolding instead of the build. That is a
real failure mode here, not a hypothetical: more than one green run has
been produced by a check that was wrong, and more than one red one by a
check that was right about the wrong thing.

So before adding a check, ask what it buys:

- **Has this failed, or might it?** Every check in `verify.sh` should
  trace to something that actually went wrong. Hypothetical coverage is
  how a suite doubles in size without catching anything new.
- **Would a human notice it anyway?** The end-of-build Telegram check is
  deliberately manual. A person messaging a bot during setup finds the
  problem while they are paying attention; an automated check that passes
  teaches them to stop looking. Leave it with the human.
- **Does it assert behaviour or appearance?** Checks that match on what
  output looks like break when the vendor rewords a line. Several here
  have.
- **Can it be deleted later?** `docs/gotchas.md` has a deletion rule for
  exactly this reason. Checks should too: one that has not fired across
  several clean builds and could not fire today is cost, not safety.

The suite exists to catch what a careful person would miss, not to spare
anyone from looking. When a defect is cheap to see and expensive to
automate, write it down and let the human see it.

**When something will not work, find its documentation first.** Not after
three attempts, not after handing Pi another theory — first. This is the
cheapest step available and the one most easily skipped, because guessing
feels like progress and reading feels like delay.

A guess costs a Pi turn (5–15 minutes), a user's patience, and a change to
the VM you then have to reason about. Reading the manual costs minutes and
usually ends the question. On 2026-11-06 four consecutive guesses at one
config token failed; the answer was one sentence in the vendor docs, found
in two minutes once someone looked.

Do it properly:

- **One thin page is not "undocumented".** Look for the index, a search, a
  `reference/` section, or an `llms.txt` / `llms-full.txt` — vendors
  increasingly ship a single concatenated file for exactly this. Hermes
  does: `hermes-agent.nousresearch.com/docs/llms-full.txt`, ~6 MB, grep it.
- **The software documents itself too.** `--help`, `--list-*`, `config
  show`, and the comments inside a generated config file are first-class
  sources. The `platform_toolsets` answer was sitting in the config file's
  own comments for days.
- **Prefer the vendor's words to inference**, and quote them to Pi when you
  push back. Pi cannot reach the network from inside the VM, so fetching
  and reading docs is work only you can do — it is the clearest case of
  the division of labour this file describes.

A symptom with no error message is a particularly strong signal to go
reading: silence usually means a value was accepted and ignored, which is a
documented behaviour somewhere, not a bug to be guessed at.

## The rules that matter

**The deliverable is the repo, not the VM.** This exists so someone else can
clone it and have Pi build the agents from the committed spec. The VM here
is a test fixture. When something breaks, fix the script or the spec and
re-run.

**Never shell into the VM to fix something by hand.** Not `limactl shell`,
not a one-off `sed` through `pi-session.sh`. A VM repaired by hand looks
like success while the repo still produces failure for the next person. This
was violated twice and both times destroyed the evidence. None of the
scripts hand you a VM shell; that is deliberate.

**Never let a bot be reachable without an allowlist.** Not the same as
"never enable a channel" — a reachable agent is a success measure. But a
live agent has shell access and no permission prompts, and the agents can
reach the public web, so a stranger who gets to one can read `agents.env`
and send the credentials straight out. Who may *message* the bot is the
control; silence is not.

**Never write a token into a config file or echo one into a chat.** Use env
SecretRefs; `verify.sh` asserts `plaintext=0, unresolved=0`.

**Never commit anything from `config/`.** Checked at preflight; check again
before you finish.

**`agent-egress unlock` is for debugging only.** Re-lock immediately.

**A finished VM gives the agents no `sudo`, and that is the sandbox.**
The egress lockdown matches the agent user's uid and root is exempt, so
an agent that can become root is not confined. `finish-build.sh` closes
it; `install-config.sh --reopen` opens it again for a repair that needs
root, and every minute it is open the live bots sit in front of an
unconfined agent. Reopen deliberately, say so, and lock it again. The
host's own way to root afterwards is `config/admin-secret` — never push
that file into the VM, and never print it.

**Curl-to-bash installers** get downloaded, checksummed and then executed —
never piped. This applies to Pi too, and is in its spec.

**After any add-on, re-run the vendor's doctor for every gateway it
touched** — `hermes doctor`, and `openclaw doctor --lint --all --deep --json`
if OpenClaw was involved. Add-ons edit config, install into an agent's
interpreter and patch bundled files, so a doctor that was clean before
one says nothing about after. Judge both on parsed output, never exit
code: `hermes doctor` exits 1 whenever an optional integration is
absent, and `openclaw doctor` exits 0 even when `ok:false`. The four
configuration defects found on 2026-11-09 had all shipped past a
41-check suite and surfaced as odd agent behaviour, not as failures.

## Permissions

Every tool has its own approval mechanism, so this list is prose. Claude
Code users get `.claude/settings.json` committed, which encodes it.

Allow unattended: `./bootstrap.sh`, `./scripts/*.sh`, `./verify/verify.sh`,
`git`, `limactl list`, and
`limactl shell agents -- cat /etc/agent-sandbox/phase`.

Ask first: `./bootstrap.sh --rebuild`, which destroys the VM, both agents
and `config/agents.env`, and `./verify/verify.sh --reboot` (or `--all`),
which stops and restarts a VM someone may be talking to, and
`./scripts/upgrade-vm.sh`, which does the same to bring an older VM up to
the current sandbox without rebuilding it. The first two used to run
unattended under the patterns above while `limactl delete` and `limactl
stop` were denied — the same two actions, one command further in.

Deny: `limactl delete|stop` and `agent-egress unlock`.

Everything else under `limactl shell agents -- ...` is on neither list, so
it prompts. The asymmetry is the point — the two read-only probes above
are named deliberately, the general form is not. Treat that prompt as a
refusal: "fix the spec, not the VM" has been violated twice as prose.
(This file used to say the general form was *denied*. It never was; a
deny rule would also have blocked the two probes, since deny outranks
allow.)

**Do not ask the user to bypass permissions wholesale.** An allowlist gives
you a working session without removing the one guardrail that keeps you out
of the VM.

## Do not hand the user text to transcribe

They cannot copy out of their terminal. Anything you "hand them to paste"
they retype by hand. Write the file yourself; put long commands in a script
and give them one short line. If a denial stops you, say so and ask.

## How it fits together

| | |
|---|---|
| `bootstrap.sh` | preflight, detect model access, start the VM, push config, lock egress. Stops before Pi. |
| `lima/agents.yaml` | the VM and the sandbox: squid, uid-scoped iptables, `agent-egress`. |
| `spec/pi-target-state.md` | what Pi builds. Keep it short — it is a prompt, and length costs. |
| `scripts/pi-session.sh` | drive Pi headlessly. Retries transients, times out hangs. |
| `scripts/finish-build.sh` | idempotence (needs the bootstrap allowlist), narrow egress, verify. |
| `verify/verify.sh` | the oracle. Asserts the sandbox blocks, not just that the happy path works. |
| `docs/gotchas.md` | dated notes for you. Entries expire — see its header. |
| `config/` | local only; nothing but `*.example` is committed. |
| `local/`, `archive/` | the user's own files. Not managed here. |

Two things that bite: **editing `lima/agents.yaml` does not change an
existing VM** (Lima froze a copy at creation; use `--rebuild`), and
**`/health` and `/v1/models` are false greens** — only a completion proves
the model path.

## Agent personality

Both agents keep their character in their own `SOUL.md` inside the VM. **The
agent owns that file; the user changes it by talking to the agent**, not by
editing anything here. The repo ships a seed, never a managed file. Do not
add a sync script or a tracked `agents/` directory. See
`docs/personality.md`.

## Adding a provider

Only Argo is implemented, and only through a gateway on the **host's**
loopback: nothing in the VM translates anything. That gateway serves
`/v1/messages` (Anthropic shape → Pi), `/v1/chat/completions` (OpenAI
shape → Hermes and OpenClaw) and `/v1/embeddings` (OpenClaw's memory).
The two shapes are why a gateway is needed at all.

To add one: extend the `case "$BASE_HOST"` classifier in
`scripts/detect-model-access.sh`, add its install step to
`lima/agents.yaml`, template its config in `config/`, and give its secrets
the same SecretRef mechanism *and the same audit check* as Argo's.
