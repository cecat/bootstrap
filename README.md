# Sandboxed persistent agents

Two persistent AI agents — an **OpenClaw** gateway and a **Hermes** gateway,
one agent each — running in a VM that cannot see your filesystem and cannot
reach the internet except through a domain allowlist you control. Reach them
from Telegram.

They are installed not by a script but by **Pi**, a coding agent living
*inside* the VM, working from a written specification, with your own coding
agent supervising it. The agents end up using the same models your coding
agent already uses; nothing to look up.

```sh
git clone <this repo> && cd bootstrap
cp config/agents.env.example config/agents.env
$EDITOR config/agents.env          # two names, two bot tokens, your user id
./bootstrap.sh                     # ~10 minutes, no prompts
```

Then open a coding agent in this directory and tell it:

> Read AGENTS.md and build this.

It drives Pi, checks the result, and finishes the build — about twenty
minutes. Developed and tested with Claude Code.

---

## Before you start

### A coding agent

Claude Code, Codex, Cursor or similar, able to open this directory. This is
**required**: `bootstrap.sh` does the deterministic half and stops, because
what remains — supervising Pi, reading what it did against what it claims —
is a coding agent's job.

**It needs permission to run this repo's scripts**, or it will work out what
to do and then ask you to type each command, which is the opposite of the
point. Claude Code reads the `.claude/settings.json` shipped here; you may
have to trust project settings once. For other tools the list is in
`AGENTS.md`.

Don't reach for a blanket bypass flag. That list also *denies* a few things
— shelling into the VM to fix it by hand, deleting the instance, unlocking
the sandbox — and those denials are load-bearing.

### Sharing your model access

The agents will use the same model endpoint and credential your coding agent
uses right now. `bootstrap.sh` reads your live `ANTHROPIC_BASE_URL` and
`~/.claude/settings*.json`, resolves the credential, and copies it in.

**They will spend against it.** The sandbox limits where a key can be sent;
it does nothing about what it can spend. If your provider offers a
spend-capped key, put it in `config/model-access.env` as `CREDENTIAL=…`
after detection runs.

Your host must be on whatever network the endpoint needs — the VM inherits
your host's networking, so if you cannot reach it, neither can the VM.

### Telegram bots

Optional; skip it and you talk to the agents from a shell in the VM. Two
minutes in the Telegram app:

1. Message **@BotFather**, send `/newbot`, give it a name and a username
   ending in `bot`. It replies with a token.
2. **Do it twice** — each agent needs its own bot. Telegram allows one
   connection per bot, so a shared token means the two gateways fight over
   it and neither stays up.
3. Message **@userinfobot** for your numeric user id. That is the only
   account the bots will answer.

### Software

| | |
|---|---|
| **Lima** | macOS: `brew install lima`. Linux: the release binary from [lima-vm/lima](https://github.com/lima-vm/lima/releases) — distro packages are often older than the required 1.0.0 — plus QEMU and a usable `/dev/kvm`. |
| **jq, openssl, curl** | macOS: `brew install jq`. Linux: `sudo apt-get install jq openssl curl` |

On Linux read `docs/spark-handoff.md` first. The VM uses 8 GiB of RAM and up
to 60 GiB of disk.

## What happens

`bootstrap.sh` detects your model access, provisions the VM (Node, squid,
iptables tooling, Pi), copies your config in over SSH, locks egress to a wide
installation-time allowlist, and stops. It never prompts; if
`config/agents.env` is missing it creates one from the example, tells you to
fill it in, and exits.

Your coding agent then does the rest with `scripts/pi-session.sh`: hands Pi
the spec, watches it install both agents and write a setup script that must
run twice unchanged, reads what it actually did, and argues where it
over-claimed. Then `scripts/finish-build.sh` proves idempotence, narrows
egress to the steady-state allowlist, and verifies with real completions.

Telegram channels are enabled only as a final step, and only once the
allowlist restricting them has been read back from the config.

If something fails, fix what it reported and re-run `./bootstrap.sh` — it
resumes. **Don't go into the VM and fix things by hand**: a VM repaired by
hand looks like success while the repo still produces failure for the next
person who clones it.

```sh
./bootstrap.sh --rebuild   # destroy the VM and generated config, start over
./bootstrap.sh --dry-run   # preflight and detection only, writes nothing
```

## Checking it worked

```sh
./verify/verify.sh                 # structure, policy and egress — costs nothing
./verify/verify.sh --models        # + one real completion per agent
./verify/verify.sh --idempotence   # + re-runs Pi's setup.sh, asserts no change
./verify/verify.sh --all           # + reboot persistence
```

A plain run checks about thirty things, including that a **non-allowed
destination is actually blocked** — a check that only confirms the allowed
path proves nothing.

It does not prove the model path, and says so. A gateway can be up with a
dead endpoint behind it; only a real completion settles it, which is what
`--models` costs quota to do.

## Using the agents

Message your bots on Telegram, or from a shell in the VM:

```sh
limactl shell agents
openclaw chat
hermes -z "what can you do?"
```

### Changing an agent's personality

**Talk to the agent.** Each keeps its character in its own `SOUL.md` inside
the VM and can edit it on request:

> show me your SOUL.md
>
> add a paragraph saying you prefer short answers

There is nothing in this repo to edit. The VM has no mounts, so there is no
host path to point at, and Hermes rewrites its own memory and skills as it
goes — a repo-tracked copy would fight the product. The repo seeds a starter
`SOUL.md` once and never touches it again, so rebuilding will not revert a
personality you have changed. See `docs/personality.md`.

### Starting and stopping

```sh
limactl stop agents
limactl start agents    # gateways and egress policy come back by themselves
```

On a laptop the VM sleeps when the machine sleeps, so the agents are not
truly always-on. That is the main reason to run this on a machine that stays
up.

## What "sandboxed" means here

- **No filesystem access.** The VM has no mounts. Your home directory is not
  visible to anything inside it.
- **Nothing reachable from outside.** User-mode NAT, no port forwards. The
  gateways listen on the VM's loopback only, not on your LAN.
- **Egress is allowlisted by domain**, through a squid proxy inside the VM.
- **Enforced, not merely configured.** An iptables rule matched on the agent
  user's uid means an agent that ignores the proxy settings reaches nothing.
  The verification suite tests this by trying.
- **One deliberate hole:** the model endpoint, a single fixed host and port.

The threat model is a misbehaving or manipulated agent, not a hostile kernel.
A live agent has shell access and no permission prompts, which is why the
Telegram allowlist — who may message it — matters as much as the egress one.

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
  personality.md        how SOUL.md works
  snapshots.md          backup and recovery
  failover.md           the vLLM fallback (unverified)
  original-brief.md     the design reasoning, written before the build
todo.md                 what is unfinished
```

## Status

Verified end to end on **Linux arm64** (DGX Spark, Lima with QEMU+KVM): the
VM and every generated config deleted, then rebuilt from nothing. Pi
installed both agents from the committed spec with no supervisor
intervention, and `verify.sh --models --reboot` passed 38 checks — egress
blocked at both layers, both agents completing, and policy intact across a
reboot. Both bots were then messaged by hand and fetched a web page.

First built on **macOS arm64** (Lima with Apple's Virtualization.framework),
where it passed an earlier, smaller suite.

Known gaps, with detail in `todo.md`: the macOS run is stale; only Argo is
implemented as a model provider; and the vLLM fallback is unverified.

## Credit

[Pi](https://pi.dev) (Earendil), [OpenClaw](https://openclaw.ai),
[Hermes Agent](https://nousresearch.com) (Nous Research), and
[Lima](https://lima-vm.io) (CNCF).
