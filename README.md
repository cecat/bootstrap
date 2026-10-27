# Sandboxed persistent agents

Two persistent AI agents — an **OpenClaw** gateway and a **Hermes** gateway,
one agent each — running in a VM that cannot see your filesystem and cannot
reach the internet except through a domain allowlist you control.

You run one script to build the VM. Then **Pi** — a small coding agent living
*inside* the VM — installs the two agents from a written specification.

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

You do **not** need a coding agent on the host. The build reads the model
access your agent already has from its settings and environment, but it runs
as a plain shell script.

**On Linux, read `docs/spark-handoff.md` before you start.** It covers the
QEMU and KVM requirements, the exact package list, and the two traps that
cost the first Linux run real time.

Provisioning the VM takes about ten minutes, plus however long the agent
installation runs. The VM uses 8 GiB of RAM and up to 60 GiB of disk.

## How to build it

```sh
./bootstrap.sh
```

Run it in a terminal you can type into. It hands you one file to fill in,
asks one question, builds the VM, and then **stops and hands the rest to
your coding agent.**

That stop is the design. The part that remains — Pi, installing two agents
from a written spec — needs **supervising**, not watching: reading its
transcript against the spec and pushing back where it claims more than it
did. Pi reports success it has not earned, and four earlier builds shipped
broken because nobody checked.

That review is a coding agent's job, not yours. The script writes the
handoff to `NEXT-STEP.md` when it stops, so all you do is start a coding
agent in this directory and tell it:

> Read NEXT-STEP.md and do what it says.

If you would rather do the supervising yourself in Pi's own TUI, run
`./bootstrap.sh --interactive-pi`. You can decide later too — re-running
reuses the existing VM and takes about a minute to get back to this point.

### What you supply: one file

The build creates `config/agents.env` and hands it to you to edit, then
starts the VM — so you have the ten-minute provision to fill it in. Every
field is documented in the file, and **your coding agent can help you with
it.** Defaults are fine for a first build.

| | |
|---|---|
| **Agent names** | Two. Defaults `claw-one` and `hermes-one`. Just names — an agent's character lives in its own `SOUL.md` inside the VM, changed by talking to the agent. |
| **Telegram** | Optional. One dedicated bot per agent from @BotFather — never a personal account — plus your own numeric user id, the only account they will answer. Blank is fine; add it later. |
| **Gateway token** | Nothing to do. The build generated 64 random hex characters into your copy. It is blank in the committed template because that template is public — your token is unique to your install. |

Nothing asks you to type a secret at a prompt or into a chat, by design: that
puts it in the shell history, the transcript and the session log. A 0600 file
does not.

### The one question

**Is the detected model access correct?** Look at this one properly —
everything downstream depends on it, and a wrong endpoint doesn't fail here.
It surfaces much later as confusing failures deep inside Pi.

### If something fails

Fix what it reported and run `./bootstrap.sh` again — it resumes. **Don't go
into the VM and fix things by hand.** A VM repaired by hand looks like success
while the repo still produces failure for the next person who clones it.

To start completely over:

```sh
./bootstrap.sh --rebuild         # destroys the VM and the generated config
./bootstrap.sh --dry-run         # preflight and detection only, writes nothing
./bootstrap.sh --interactive-pi  # rare: supervise Pi yourself, in its own TUI
```

## What happens, in order

1. Detects your model access and asks you to confirm it.
2. Creates `config/agents.env` and hands it to you to edit.
3. Provisions the VM — Node, squid, iptables tooling, and Pi. About ten
   minutes, which is your window to edit that file.
4. Copies your config in over SSH and locks egress down to a wide
   installation-time allowlist.
5. **Stops**, and writes `NEXT-STEP.md` for your coding agent.

Your agent then does the rest, with `scripts/pi-session.sh`:

6. Gives Pi the spec. Pi installs OpenClaw and Hermes, writes their service
   units, seeds each agent's personality file, and produces a setup script
   that must run twice unchanged to prove it is repeatable.
7. Reads the transcript and argues with Pi where it over-claimed. This is
   the step that four previous builds skipped, and all four shipped broken.
8. Runs `scripts/finish-build.sh`: idempotence, narrows egress to the
   steady-state allowlist, and verifies with real completions.
9. **No chat channel is enabled**, even if you supplied Telegram tokens.
   Turning one on is a separate decision you make afterwards.

## Checking it worked

`bootstrap.sh` runs `--models` for you at the end. To re-check later:

```sh
./verify/verify.sh                 # structure, policy and egress — costs nothing
./verify/verify.sh --models        # + one real completion per agent
./verify/verify.sh --idempotence   # + re-runs Pi's setup.sh, asserts no change
./verify/verify.sh --all           # + reboot persistence
```

A plain run checks about thirty things, including that a **non-allowed
destination is actually blocked** — a check that only confirms the allowed
path proves nothing.

It does **not** prove the model path, and it says so in its own summary. A
gateway can be up and running with a dead endpoint behind it; only a real
completion settles it. `--models` sends real requests and spends whatever
quota your endpoint is on.

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
bootstrap.sh            run this
README.md               this file
AGENTS.md               background for a coding agent working on the repo
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

Verified end to end on **Linux arm64** (DGX Spark, Lima with QEMU+KVM) on
2026-10-21: deleted the VM and every generated config file, re-entered the
agent names and bot tokens, and rebuilt from nothing. Pi installed both
agents from the written spec unaided; `verify/verify.sh --models` reported
**29 passed, 0 failed**, including the egress block confirmed at both layers.

It was first built on **macOS arm64** (Lima with Apple's
Virtualization.framework), where it passed 25 checks.

Known gaps, with detail in `todo.md`:

- **`bootstrap.sh` itself is new.** The steps it runs are all proven, but the
  script that chains them was written on 2026-10-26 and has not yet driven a
  build from nothing.
- **The macOS run is stale.** Everything that took verification from 25
  checks to 29 — including a fix to a `verify.sh` call that no longer exists
  in current OpenClaw — landed after it. The repo should still work there,
  and nothing in those changes is Linux-specific, but nobody has run current
  `main` on a Mac. Treat "works on both" as unproven until someone does.
- **Only Argo** is implemented as a model provider. Adding one means extending
  a classifier in `scripts/detect-model-access.sh`; `AGENTS.md` describes how.
- **The vLLM fallback is unverified** and currently untestable.
- **Telegram is configured but has never carried a message.** Channels are
  deliberately left disabled at the end of a build; enabling one is a
  separate decision, and that path is untested.
- **No snapshot or restore documentation** yet, which is the intended recovery
  path for an agent that has broken itself.

## Credit

[Pi](https://pi.dev) (Earendil), [OpenClaw](https://openclaw.ai),
[Hermes Agent](https://nousresearch.com) (Nous Research), and
[Lima](https://lima-vm.io) (CNCF).
