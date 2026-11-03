# Sandboxed persistent agents

Two persistent AI agents — an **OpenClaw** gateway and a **Hermes** gateway,
one agent each — running in a VM that cannot see your filesystem and cannot
reach the internet except through a domain allowlist you control. Reach them
from Telegram.

They are installed not by a script but by **Pi**, a coding agent living
*inside* the VM, working from a written specification, with your own coding
agent supervising it. The agents end up using the same models your coding
agent already uses; nothing to look up.

## Quickstart

```sh
git clone <this repo> && cd bootstrap
./bootstrap.sh
```

It stops almost immediately and asks you to fill in `config/agents.env` —
two agent names, a Telegram bot token for each, and your numeric Telegram
user id. Put them in with an editor, not into a chat with an agent.

Then open a coding agent in this directory and tell it:

> Read README.md and build this.

It runs the rest: about thirty-five minutes, mostly unattended. It will
come back to you once, to ask you to message each bot. Developed and
tested with Claude Code.

## Before you start

**A coding agent** — Claude Code, Codex, Cursor or similar, able to open
this directory. This is required: `bootstrap.sh` does the deterministic
half and stops, because what remains — supervising Pi, reading what it did
against what it claims — is a coding agent's job.

It needs permission to run this repo's scripts, or it will work out what to
do and then ask you to type each command. Claude Code reads the
`.claude/settings.json` shipped here; you may have to trust project
settings once. Don't reach for a blanket bypass flag — that list also
*denies* a few things, and the denials are load-bearing.

**Two Telegram bots.** Part of the base build, not an extra: blank tokens
give you mute agents. Message **@BotFather**, send `/newbot`, and do it
twice — one bot per agent, because Telegram allows one connection per bot
and a shared token means the gateways fight over it. Then message
**@userinfobot** for your numeric user id, the only account they will
answer.

**Shared model access.** The agents use the same endpoint and credential
your coding agent uses right now; `bootstrap.sh` reads your live
`ANTHROPIC_BASE_URL` and `~/.claude/settings*.json` and copies it in.
**They will spend against it** — the sandbox limits where a key can be
sent, not what it can spend. Your host must be on whatever network the
endpoint needs; the VM inherits your host's networking.

**Software** — Lima (macOS: `brew install lima`; Linux: the release binary
from [lima-vm/lima](https://github.com/lima-vm/lima/releases), since distro
packages are often older than the required 1.0.0, plus QEMU and a usable
`/dev/kvm`), and `jq`, `openssl`, `curl`. On Linux read
`docs/spark-handoff.md` first. The VM uses 8 GiB of RAM and up to 60 GiB of
disk.

---

# Building it — for the coding agent

**Read `AGENTS.md` first.** It is the brief — the sequence of commands,
how to orient yourself if a VM already exists, how to supervise Pi, and
the permissions and rules. It is not repeated here. This section is the
procedure around it, and everything below is something `AGENTS.md` does
not say.

Work inside `tmux` from the start (`docs/tmux.md`). A dropped SSH session
killed a build twice on 2026-10-31.

## Three places it goes wrong

**`./bootstrap.sh --rebuild` destroys the VM**, both agents and everything
they have learned, and deletes `config/agents.env`. There is no undo —
`limactl snapshot` has twice lost snapshots it had confirmed, so do not
offer one as a safety net. Only use it if the user asks for a rebuild.

**`finish-build.sh` exiting 1 is a result, not a blocker.** It runs
`verify.sh` internally and prints *"Fix the script or the spec... and
re-run"*. Report the failures and continue to the next command. Do not
re-run it: it bundles idempotence, the egress narrowing and a full verify,
so repeating it redoes work that already succeeded.

**The silence watchdog.** `pi-session.sh` kills a turn after `PI_SILENCE`
seconds (default 600) with no log output at all. If you see `no output for
Ns -- killing a turn that has stopped working`, record it and say what Pi
was doing — it has not yet fired across a healthy build, so the first time
it does is worth knowing about.

## The check nothing automated covers

**Ask the user to message each agent on Telegram and have it fetch a web
page.** This is not optional and no script substitutes for it. On
2026-10-31 every automated check passed while one agent could not reach the
web at all; `verify.sh` can see that a bot is being polled, which is not
the same as an agent that answers.

Record each agent's exact words. If one mentions a workaround, a fallback,
a reader proxy, or rate-limiting, quote it — an agent reporting success by
routing around a block is a finding, not a pass.

## When it fails

`AGENTS.md` has the rules; these are the three that get broken under
pressure, when something is red and a fix looks close.

- **One retry, then stop.** `pi-session.sh` retries transient model errors
  itself; let it. If a step fails for another reason, run it once more. If
  it fails again, stop and report.
- **Don't theorise.** Report the symptom and the exact command output. A
  previous session lost hours to five successive wrong theories before Pi
  found the real cause in one short turn. Read `docs/gotchas.md` before
  debugging anything.
- **Don't improvise past a blocker.** Stopping with a clear account is a
  good outcome. Grinding to a green result by working around the
  documentation is not, and neither is reaching into the VM — a VM
  repaired by hand looks like success while the repo still produces
  failure for the next person who clones it.

## What to tell the user at the end

The final tally from `verify.sh`, every failing check quoted with its
message, and — separately — whether each agent fetched a web page over
Telegram, in its own words. Then anything you had to decide for yourself,
anywhere the documentation left you guessing, and anything Pi claimed that
the evidence contradicts. Never put a token, credential or user id in
whatever you write.

If you were running this as a rebuild test, write that up as
`REBUILD-RESULT.md`. It is gitignored on purpose: don't commit it, and
don't go looking for an earlier one — past runs are in `archive/`, and
reading one would tell you what to expect.

---

# Reference

## Re-running and starting over

`./bootstrap.sh` resumes and is safe to re-run; if something fails, fix
what it reported and run it again. Two flags:

```sh
./bootstrap.sh --dry-run   # preflight and model detection only, writes nothing
./bootstrap.sh --rebuild   # destroy the VM and generated config, start over
```

## Checking it worked

```sh
./verify/verify.sh                 # structure, policy and egress — costs nothing
./verify/verify.sh --models        # + one real completion per agent
./verify/verify.sh --idempotence   # + re-runs Pi's setup.sh, asserts no change
./verify/verify.sh --reboot        # + reboot persistence
./verify/verify.sh --all           # everything
```

A plain run checks about forty things, including that a **non-allowed
destination is actually blocked** — a check that only confirms the allowed
path proves nothing. It does not prove the model path, and says so: a
gateway can be up with a dead endpoint behind it, which is what `--models`
costs quota to settle.

## Using the agents

Message your bots on Telegram, or from a shell in the VM:

```sh
limactl shell agents
openclaw chat
hermes -z "what can you do?"
```

**To change an agent's personality, talk to the agent.** Each keeps its
character in its own `SOUL.md` inside the VM and can edit it on request
("show me your SOUL.md"; "add a paragraph saying you prefer short
answers"). There is nothing in this repo to edit — the VM has no mounts, so
there is no host path to point at, and Hermes rewrites its own memory and
skills as it goes. The repo seeds a starter `SOUL.md` once and never
touches it again, so rebuilding will not revert a personality you have
changed. See `docs/personality.md`.

```sh
limactl stop agents
limactl start agents    # gateways and egress policy come back by themselves
```

On a laptop the VM sleeps when the machine sleeps, so the agents are not
truly always-on. That is the main reason to run this on a machine that
stays up.

## What "sandboxed" means here

- **No filesystem access.** The VM has no mounts. Your home directory is
  not visible to anything inside it.
- **Nothing reachable from outside.** User-mode NAT, no port forwards. The
  gateways listen on the VM's loopback only, not on your LAN.
- **Egress is allowlisted by domain**, through a squid proxy inside the VM.
- **Enforced, not merely configured.** An iptables rule matched on the
  agent user's uid means an agent that ignores the proxy settings reaches
  nothing. The verification suite tests this by trying.
- **One deliberate hole:** the model endpoint, a single fixed host and port.

The threat model is a misbehaving or manipulated agent, not a hostile
kernel. A live agent has shell access and no permission prompts, which is
why the Telegram allowlist — who may message it — matters as much as the
egress one.

## Where things are

```
bootstrap.sh            run this
AGENTS.md               the brief for a coding agent (CLAUDE.md symlinks to it)
lima/agents.yaml        the VM and its sandbox
spec/pi-target-state.md what Pi is told to build
scripts/                detection, config push, driving Pi, finishing up
verify/verify.sh        the checks
config/                 your local config; only *.example is committed
docs/
  gotchas.md            read before debugging anything
  spark-handoff.md      read FIRST if you are on Linux
  tmux.md               surviving a dropped SSH session
  personality.md        how SOUL.md works
  snapshots.md          backup and recovery
  failover.md           the vLLM fallback (unverified)
  original-brief.md     the design reasoning, written before the build
todo.md                 what is unfinished
```

## Status

Verified end to end on **Linux arm64** (DGX Spark, Lima with QEMU+KVM): the
VM and every generated config deleted, then rebuilt from nothing by a
coding agent with no prior context. Pi installed both agents from the
committed spec with no supervisor intervention — zero messages to Pi, zero
retries — and `verify.sh --models --reboot` passed 39 checks with none
failing: egress blocked at both layers, both agents completing, and policy
intact across a reboot. Both bots were then messaged by hand and fetched a
web page, neither reporting a workaround.

First built on **macOS arm64** (Lima with Apple's Virtualization.framework),
where it passed an earlier, smaller suite. Everything that raised the Linux
number landed after that run and has never been executed on a Mac, so treat
macOS as unproven. If you are bringing it back up, `MACOS-TEST.md` is the
harness — it protects the Linux build while you do.

Known gaps, with detail in `todo.md`: the macOS run is stale; only Argo is
implemented as a model provider; the vLLM fallback is unverified; and the
Hermes Telegram adapter check has reported FAIL and SKIP minutes apart on
an adapter that was working.

## Credit

[Pi](https://pi.dev) (Earendil), [OpenClaw](https://openclaw.ai),
[Hermes Agent](https://nousresearch.com) (Nous Research), and
[Lima](https://lima-vm.io) (CNCF).
