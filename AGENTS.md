# Build instructions for a coding agent

*(`CLAUDE.md` is a symlink to this file. `AGENTS.md` is the cross-tool
convention — Codex, Cursor, Warp, Gemini CLI, Aider and others look for it;
Claude Code looks for `CLAUDE.md`. Same content either way.)*

You are being asked to build a sandboxed environment of persistent agents.
Read this file fully before running anything. `README.md` is the user-facing
guide and says what the person who cloned this expects to happen;
`docs/original-brief.md` holds the design reasoning. **This file is the
procedure.**

**What you are building:** a Lima VM on the host, containing a translation
proxy for model access, Pi, and then — built *by Pi* — an OpenClaw gateway
with one agent and a Hermes gateway with one agent, both optionally reachable
over Telegram.

**The central idea:** the agents in the VM reach the *same models you are
using right now*. You detect your own model access and propagate it inward.
Do not ask the user to retype an endpoint you can discover.

---

## Current status

**Working on this repo? Read `docs/handoff-2026-10-26.md` first.** It records
where the work stands, the next three steps, and the one rule that matters:
**the deliverable is the repo, not the VM** — when something breaks, fix the
script or the spec and rerun, never reach into the VM by hand.

This repo is mid-build. Implemented and checked:

| Path | State |
|---|---|
| `lima/agents.yaml` | Linux/qemu verified from scratch 2026-10-21 (DGX Spark). macOS/vz passed earlier, but **not re-run since**; see `todo.md` item 00. |
| `scripts/detect-model-access.sh` | Implemented, tested against a live Argo env. |
| `scripts/install-config.sh` | Implemented and run against a real VM. |
| `config/*.example` | Implemented. |
| `spec/pi-target-state.md` | Implemented. |
| `scripts/run-bootstrap.sh` | Implemented. Pi built both agents from it unaided on a clean rebuild (2026-10-21). |
| `verify/verify.sh` | Implemented. **29 pass, 0 fail** with `--models` on a clean Linux rebuild. |
| `docs/personality.md`, `docs/failover.md` | Implemented. |
| `docs/spark-handoff.md` | Implemented (Linux/DGX Spark porting notes). |
| `docs/snapshots.md` | **Not written.** |

If you reach an unwritten step, stop and tell the user rather than improvising
a replacement.

---

## Step 0 — Preflight

```sh
command -v limactl || brew install lima    # macOS host
command -v jq                              # required by detection
```

**On a Linux host, stop and read `docs/spark-handoff.md` first.** Linux needs
QEMU with working KVM, a different package set, and a check that Lima's host
gateway is still `192.168.5.2`. That file is the delta, and it now records a
completed Linux run — including two traps that cost time: a `setfacl` grant on
`/dev/kvm` does **not** survive the udev event that installing qemu triggers
(use the `kvm` group, and `sg kvm -c '...'` for an already-running shell), and
NextDNS may fail the NVIDIA apt repos in a way that looks alarming and is
irrelevant here.

Confirm the host is on the network its model endpoint needs. For Argo that
means the Argonne internal network or its VPN; the VM inherits host NAT, so if
the host cannot reach the endpoint, neither can the VM.

## Step 1 — Detect model access

```sh
./scripts/detect-model-access.sh --dry-run
```

Reads your live `ANTHROPIC_BASE_URL` and model names, finds the matching
`~/.claude/settings*.json` for its `apiKeyHelper`, resolves the credential
without printing it, and classifies the provider.

**Show the user the summary and get confirmation before continuing.** This is
the one thing worth confirming, because everything downstream depends on it.
Then re-run without `--dry-run` to write `config/model-access.env` (0600,
gitignored).

Two failure modes it handles, which you should not work around by hand:
- **A loopback endpoint** (`127.0.0.1:…`) is the *host's* tunnel and is
  unreachable from the VM. The script recovers the real upstream.
- **An unimplemented provider** fails deliberately. See *Adding a provider*.

## Step 2 — Start the VM now

```sh
limactl start --name=agents lima/agents.yaml
```

Do this **before** asking the user anything. Provisioning takes roughly ten
minutes, and Steps 3 and 4 are questions you can ask while it runs. Do not
leave the user watching a progress bar when you could be collecting what you
need from them.

No mounts, user-mode NAT, no host port forwards. First boot installs Node 22+,
squid, Pi and argo-proxy, and attempts Tailscale (best-effort; some networks
block `tailscale.com`, which is not fatal).

**Editing `lima/agents.yaml` does not change a VM that already exists.** Lima
copies the config into the instance at creation time, and `limactl start`
re-reads *that* copy from `~/.lima/<name>/lima.yaml`. Provision scripts do
re-run on every boot — but from the frozen copy, so your edit is silently
ignored and you debug the old code. To pick up a change, recreate:

```sh
limactl delete -f agents && limactl start --name=agents lima/agents.yaml
```

Recreating is cheap before Pi has built anything, and destroys the agents
afterwards. Once agents exist, snapshot first.

## Step 3 — Ask the user for the non-secret values

While the VM provisions, ask for these in conversation:

1. **A name for the OpenClaw agent.** Default `claw-one`.
2. **A name for the Hermes agent.** Default `hermes-one`.
3. **Whether they have a local vLLM endpoint** for model fallback. Usually no.
   Only if yes, ask for its URL, key and model name.

That is the whole list. Confirm the detected model access from Step 1 at the
same time, if you have not already.

## Step 4 — Have the user supply the secrets themselves

**Never ask for a secret in conversation.** Not the bot tokens, not the
Telegram user id. Asking puts them in the transcript, in your tool calls, and
in any log of this session. This is a rule of the repo, not a judgment call
for you to make per-run — see *Safety rules*.

Instead, generate the file and hand it back for editing:

```sh
cp config/agents.env.example config/agents.env
chmod 600 config/agents.env
```

Then, in `config/agents.env`, set:

- `OPENCLAW_AGENT_NAME` and `HERMES_AGENT_NAME` to the names from Step 3.
- `OPENCLAW_GATEWAY_TOKEN` to the output of `openssl rand -hex 32`. **Generate
  it; never invent one and never ask the user for one.**

Leave every other value blank. Then tell the user, naming the file explicitly:

> `config/agents.env` is ready. Fill in these three if you want Telegram, then
> tell me to continue:
> `OPENCLAW_TELEGRAM_BOT_TOKEN`, `HERMES_TELEGRAM_BOT_TOKEN`,
> `TELEGRAM_ALLOWED_USER_ID`
> Leave them blank to build without channels — you can add them later.

Wait for them. Do not read the file back to confirm its contents, do not echo
the values, and do not proceed on the assumption they are filled in:
`install-config.sh` will tell you what is missing.

If the user pastes a token into the chat anyway, use it — refusing after the
fact helps nobody — but tell them plainly that it is now in the transcript and
that rotating it via @BotFather is cheap.


## Step 5 — Push config and lock egress down

```sh
./scripts/install-config.sh
```

Before running it, confirm nothing local is about to be committed — everything
in `config/` except the `*.example` templates and `README.md` is gitignored:

```sh
git status --porcelain -uall        # only *.example and README.md from config/
```

Copies config in over SSH (the VM has no mounts), starts the translation proxy
as a user service, applies the **bootstrap** egress allowlist, and health-checks
the model path. Do not continue if the health check fails — a broken model path
will only resurface as confusing Pi failures later.

## Step 6 — Hand the spec to Pi

```sh
./scripts/run-bootstrap.sh
```

Pi reads `spec/pi-target-state.md` and installs OpenClaw and Hermes. The spec requires
Pi to emit an **idempotent setup script** rather than ad hoc commands, and to
re-run it to prove idempotence.

## Step 7 — Narrow egress

```sh
limactl shell agents -- sudo agent-egress runtime
```

Drops from the wide bootstrap allowlist to the steady-state one.

## Step 8 — Verify

```sh
./verify/verify.sh            # structure, policy and egress — costs nothing
./verify/verify.sh --models   # + one real completion per agent
./verify/verify.sh --all      # + reboot persistence
```

Substrate, config permissions, egress policy, gateway state, and an assertion
that **no chat channel is enabled yet**.

The egress section is the point of the suite: it asserts a non-allowed
destination is **blocked** at both layers — `403` from squid through the
proxy, no connection at all around it — and that the iptables rule is scoped
to the agent uid, by checking the same request *succeeds* as root. Without
that last control, a VM with no network at all would pass.

**A plain run does not prove the model path.** `/health` and `/v1/models`
answer 200 from local state with a dead upstream; only a completion proves it.
Run `--models` before you tell the user the build works — and say so if you
did not, because it sends real requests and spends their quota.

## Step 9 — Stop

**Hard checkpoint.** Summarize for the user: what was installed, what the
verification showed, what egress is permitted, and what is still unverified.
**Do not enable any chat channel before this point**, and do not enable one
without the user saying so afterward.

---

## Agent personality

Both agents keep their character in their own `SOUL.md` inside the VM
(`~/.openclaw/agents/default/SOUL.md`, `~/.hermes/SOUL.md`). **The agent owns
that file. The user changes it by talking to the agent** — "show me your
SOUL.md", "add this paragraph" — not by editing anything in this repo.

This is not just simpler, it is forced by two earlier decisions: the VM has no
mounts, so there is no host path to edit; and Hermes rewrites its own
`MEMORY.md`, `USER.md` and skills as it learns, so a repo-tracked copy would
conflict with the product by design.

So: **the repo ships a seed, never a managed file.** Pi writes a ten-line
starter `SOUL.md` once at bootstrap and its setup script never touches it
again — re-running setup must not revert a personality the user has since
edited. Do not add a sync script, a tracked `agents/` directory, or any
mechanism for pulling these files back out.

The escape hatch, for when an agent is too broken to talk to, is documentation
rather than code:

```sh
limactl shell agents -- nano ~/.openclaw/agents/default/SOUL.md
limactl shell agents -- nano ~/.hermes/SOUL.md
```

Recovery from a genuinely broken agent is the VM snapshot (see `docs/`), not a
backup mechanism of our own.

---

## Safety rules

These are not negotiable, and they override convenience.

- **Curl-to-bash installers** (OpenClaw, Hermes, Tailscale): fetch the script
  and show it to the user, or pin a release, before executing it. This applies
  to Pi inside the VM too — it is written into `spec/pi-target-state.md`.
- **Never enable a chat channel before Step 8 passes.** Stop and summarize.
- **Never write a token into a config file or echo one into a chat.** Use env
  SecretRefs. The detection script never prints credentials; keep that property.
- **Never ask the user for a secret in conversation.** Bot tokens and the
  Telegram user id are supplied by the user editing `config/agents.env`
  directly (Step 4). Whether a secret ends up in a transcript must not depend
  on which model happened to run this build.
- **Never commit anything from `config/`.** Check before you finish.
- **`agent-egress unlock` is for debugging only.** Re-lock immediately; never
  leave the VM unlocked at the end of a session.
- **A spend-capable key crossing into the sandbox is a real risk.** The
  detection script warns when it sees one. Relay that warning; do not bury it.
  The egress allowlist limits where a key can be sent, not what it can spend.

---

## Adding a provider

Only the Argo path is implemented. The structure generalizes: the VM runs one
translation proxy on `127.0.0.1:44497` serving

- `/v1/messages` (Anthropic shape) → Pi and OpenClaw
- `/v1/chat/completions` (OpenAI shape) → Hermes

For Argo that proxy is `argo-proxy`. Hermes is the reason a translator is
needed at all: `api.anthropic.com` offers no OpenAI-compatible surface, so
inheriting a plain Anthropic endpoint would serve two of the three agents.
The general-purpose equivalent is `LLM-Rosetta`, by argo-proxy's author.

To add one: extend the `case "$BASE_HOST"` classifier in
`scripts/detect-model-access.sh`, add its install step to `lima/agents.yaml`
provisioning, and template its config in `config/`.

---

## Repo map

```
AGENTS.md               this file. CLAUDE.md is a symlink to it.
README.md               user-facing guide -- what a human does after cloning
lima/agents.yaml        the VM
scripts/                host-side: detection, config push, bootstrap
spec/pi-target-state.md          target-state spec Pi builds from
config/                 local config; only *.example is committed
verify/verify.sh        automated checks (see Step 8)
docs/                   porting, personality, failover
  spark-handoff.md      read this FIRST on a Linux host (DGX Spark)
  original-brief.md     the pre-build design brief and its reasoning
```
