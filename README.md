# Sandboxed persistent agents

Two persistent AI agents — an **OpenClaw** gateway and a **Hermes** gateway,
one agent each — running in a VM that cannot see your filesystem and cannot
reach the internet except through a domain allowlist you control.

You do not install them yourself. You point a coding agent at this repo and it
builds the VM, then **Pi** — a small coding agent living *inside* the VM —
installs the two agents from a written specification.

The agents get the same model access you already have. Nothing to look up: the
build reads your live `ANTHROPIC_BASE_URL` and your `~/.claude/settings*.json`
and propagates that inward.

---

## What you need first

| | |
|---|---|
| **Lima** | macOS: `brew install lima`. Linux: the release binary from [lima-vm/lima](https://github.com/lima-vm/lima/releases) — distro packages are often older than the required 1.0.0 — plus QEMU and a usable `/dev/kvm`. |
| **jq, openssl** | macOS: `brew install jq`. Linux: `sudo apt-get install jq openssl` |
| **A working model endpoint** | Whatever your coding agent is using right now. For Argo that means being on the Argonne network or its VPN — the VM inherits your network, so if you can't reach it, neither can the VM. |
| **A coding agent** | Claude Code, Codex, or similar, opened in this directory. |

**On Linux, read `docs/spark-handoff.md` before you start.** It covers the
QEMU and KVM requirements, the exact package list, and which parts of this
build are unverified — the whole thing has only ever been run on macOS.

Provisioning the VM takes about ten minutes, plus however long the agent
installation runs. The VM uses 8 GiB of RAM and up to 60 GiB of disk.

## How to build it

Open your coding agent in this directory and give it this instruction:

> Read AGENTS.md and build the system it describes.

Say it explicitly like that. Don't assume the tool picked the file up on its
own: `AGENTS.md` is the cross-tool convention and most agents read it, but
Claude Code looks for `CLAUDE.md` instead. Both names exist here and are the
same file, so naming either one works — what matters is that you name one.

The agent then works through the procedure in that file. **You are not
expected to run the scripts yourself** — but you can, and the section below
says what changes if you do.

### What it will ask you

Three things, no secrets among them:

1. **A name for the OpenClaw agent.** Default `claw-one`.
2. **A name for the Hermes agent.** Default `hermes-one`.
3. **Whether you have a local vLLM endpoint** for model fallback. Usually no.

It will also show you the model access it detected and ask you to confirm it.
**Look at that one properly** — everything downstream depends on it, and a
wrong endpoint surfaces later as confusing failures deep inside Pi.

### The one thing you do by hand

If you want the agents reachable over **Telegram**, the build will stop and
hand you a file. Open `config/agents.env` in an editor and fill in three
values:

```
OPENCLAW_TELEGRAM_BOT_TOKEN=
HERMES_TELEGRAM_BOT_TOKEN=
TELEGRAM_ALLOWED_USER_ID=
```

Get a **separate bot** per agent from Telegram's @BotFather — never a personal
account — and your own numeric user id, which is the only account the bots
will answer.

Then tell the agent to continue. Leave them blank to build without Telegram;
you can add it later.

The coding agent will not ask you for these in conversation, by design. Typing
a token into a chat puts it in the transcript and in the session log. If you
paste one anyway it will still work, but rotate it via @BotFather afterwards —
that costs nothing.

### If you run the scripts yourself

You can skip the coding agent and run `scripts/` by hand — `AGENTS.md` lists
them in order. One thing to know before you do: **the scripts never prompt for
anything.** They are deliberately non-interactive, so nothing will ask you for
the agent names the way the coding agent does. Every value is read from
`config/agents.env`, and the template arrives with `claw-one` and `hermes-one`
already in it — leave them and those are the names you get.

So set that file up first:

```sh
cp config/agents.env.example config/agents.env
chmod 600 config/agents.env
```

Edit it and set the two agent names, then generate the gateway token rather
than making one up:

```sh
openssl rand -hex 32        # paste into OPENCLAW_GATEWAY_TOKEN
```

Leave the Telegram and vLLM values blank unless you want them. If something
required is missing, `install-config.sh` stops and tells you which value it
is — it will not guess.

## What happens, in order

1. Detects your model access and asks you to confirm it.
2. Creates the VM and provisions it — Node, squid, iptables tooling, and Pi.
   About ten minutes. It asks you the questions above while this runs.
3. Copies your config in over SSH and locks egress down to a wide
   installation-time allowlist.
4. Hands `spec/pi-target-state.md` to Pi. Pi installs OpenClaw and Hermes,
   writes their service units, seeds each agent's personality file, and
   produces a setup script it must run twice to prove it is repeatable.
5. Narrows egress to the steady-state allowlist — two domains.
6. Runs verification.
7. **Stops and summarizes.** No chat channel is enabled at this point, even if
   you supplied Telegram tokens. Turning one on is a separate decision you make
   afterwards.

## Checking it worked

```sh
./verify/verify.sh            # structure, policy and egress — costs nothing
./verify/verify.sh --models   # + one real completion per agent
./verify/verify.sh --all      # + reboot persistence
```

A plain run checks 25 things, including that a **non-allowed destination is
actually blocked** — a check that only confirms the allowed path proves
nothing.

It does **not** prove the model path, and it says so in its own summary. A
gateway can be up and running with a dead endpoint behind it; only a real
completion settles it. Run `--models` before you believe the build works.
That sends real requests and spends whatever quota your endpoint is on.

## Using the agents

```sh
limactl shell agents                    # get a shell in the VM

openclaw chat                           # talk to the OpenClaw agent
hermes -z "what can you do?"            # one-shot to the Hermes agent
hermes chat                             # interactive
```

### Changing an agent's personality

**Talk to the agent.** Each one keeps its character in its own `SOUL.md`
inside the VM and can edit it on request:

> show me your SOUL.md
>
> add a paragraph saying you prefer short answers

There is nothing in this repo to edit. That is deliberate: the VM has no
filesystem mounts, so there is no host path to point at, and Hermes rewrites
its own memory and skills as it goes — a repo-tracked copy would fight the
product. The repo seeds a starter `SOUL.md` once and never touches it again,
so rebuilding will not revert a personality you have since changed.

If an agent is too broken to talk to, edit the file directly:

```sh
limactl shell agents -- nano ~/.openclaw/agents/<name>/SOUL.md
limactl shell agents -- nano ~/.hermes/SOUL.md
```

See `docs/personality.md`.

### Starting and stopping

```sh
limactl stop agents
limactl start agents          # gateways and egress policy come back by themselves
```

On a laptop the VM sleeps when the machine sleeps, so the agents are not
truly always-on. That is the main reason to move this to a machine that stays
up.

## What "sandboxed" means here

- **No filesystem access.** The VM has no mounts. Your home directory is not
  visible to anything inside it. Config gets in via `limactl copy`, one file
  at a time.
- **Nothing is reachable from outside.** User-mode NAT, no port forwards. The
  gateways listen on the VM's loopback only — not on your LAN.
- **Egress is allowlisted by domain.** A squid proxy inside the VM permits a
  short list of destinations and refuses the rest.
- **Enforced, not merely configured.** An iptables rule matched on the agent
  user's uid means an agent that ignores the proxy settings reaches nothing
  at all. The verification suite tests this by trying.
- **One deliberate hole:** the model endpoint, a single fixed host and port.

The threat model is a misbehaving or manipulated agent, not a hostile kernel.

A real caution: whatever credential reaches your model endpoint also reaches
the VM. The allowlist limits where that key can be *sent*; it does nothing
about what the key can *spend*. Use a key with a spend cap if your provider
offers one.

## Where things are

```
README.md               this file
AGENTS.md               the build procedure, written for a coding agent
CLAUDE.md               symlink to AGENTS.md, for Claude Code
lima/agents.yaml        the VM definition
scripts/                detection, config push, bootstrap
spec/pi-target-state.md what Pi is told to build
config/                 your local config; only *.example is committed
verify/verify.sh        the checks
docs/
  spark-handoff.md      read FIRST if you are on Linux or a DGX Spark
  personality.md        how SOUL.md works
  failover.md           the vLLM fallback (unverified)
  original-brief.md     the design reasoning, written before the build
todo.md                 what is unfinished
```

## Status

Built and verified end to end on **macOS arm64** (Lima with Apple's
Virtualization.framework): a clean run from nothing to both agents answering
real completions, with the egress block confirmed at both layers.

Known gaps, with detail in `todo.md`:

- **Linux is unverified.** The config no longer pins a macOS-only hypervisor
  and should select QEMU on Linux, but it has never been booted there. Read
  `docs/spark-handoff.md` before trying.
- **Only Argo** is implemented as a model provider. Adding one means extending
  a classifier in `scripts/detect-model-access.sh`; `AGENTS.md` describes how.
- **The vLLM fallback is unverified** and currently untestable.
- **Telegram has not been exercised** — it was blocked on the build network.
- **No snapshot or restore documentation** yet, which is the intended recovery
  path for an agent that has broken itself.

## Credit

[Pi](https://pi.dev) (Earendil), [OpenClaw](https://openclaw.ai),
[Hermes Agent](https://nousresearch.com) (Nous Research), and
[Lima](https://lima-vm.io) (CNCF).
