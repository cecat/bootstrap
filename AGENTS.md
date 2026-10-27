# Build instructions for a coding agent

*(`CLAUDE.md` is a symlink to this file. `AGENTS.md` is the cross-tool
convention — Codex, Cursor, Warp, Gemini CLI, Aider and others look for it;
Claude Code looks for `CLAUDE.md`. Same content either way.)*

## If you were asked to build this

**Two agents, sandboxed.** This repo builds a Lima VM that cannot see the
host filesystem and cannot reach the internet except through a domain
allowlist. Inside it live an OpenClaw agent and a Hermes agent, reaching the
same models the user already has — and they are installed not by you but by
**Pi**, a coding agent running *inside* the VM, working from a written spec.

You are the supervisor. Pi does the building; you check that it actually did
what it says.

```sh
./bootstrap.sh                      # deterministic steps; stops before Pi
./scripts/pi-session.sh build       # Pi builds, headless
./scripts/pi-session.sh transcript  # read what it ACTUALLY did
./scripts/pi-session.sh say "..."   # push back, same session
./scripts/finish-build.sh           # idempotence, narrow egress, verify
```

**If `NEXT-STEP.md` exists in this directory, read it first.** `bootstrap.sh`
writes it when it stops, and it says exactly which phase the build reached.

Otherwise, work out where you are before running anything — the user may
have run `bootstrap.sh` already and started you to take over from it:

```sh
limactl list                                    # does the VM exist?
limactl shell agents -- cat /etc/agent-sandbox/phase   # bootstrap | runtime
limactl shell agents -- test -x ~/agent-bootstrap/setup.sh && echo "Pi has built"
./verify/verify.sh                              # costs nothing, says a lot
```

No VM → start at `bootstrap.sh`. VM up, phase `bootstrap`, no `setup.sh` →
Pi has not run; start at `pi-session.sh build`. `setup.sh` exists → Pi has
run at least once; read the transcript before doing anything else.

`bootstrap.sh` always stops before Pi and tells whoever ran it to hand Pi to
you. With a terminal it asks the user its questions first; without one it
takes names from `OPENCLAW_AGENT_NAME` / `HERMES_AGENT_NAME` and defaults.

Two things need the user, and you must not do either for them:

- **Supplying the values in `config/agents.env`** — agent names and Telegram
  tokens. The script prompts for them; a user may also write the file
  beforehand and the script will keep it. Either way: never ask for a secret
  in conversation, and never read one back. See *Safety rules*.
- **Confirming the detected model access.** Show them the summary from
  `./scripts/detect-model-access.sh --dry-run` and get an answer.

### Your actual job is supervising Pi

**Pi over-claims.** That is this repo's documented failure mode, not a
hypothetical: it has reported success over a `setup.sh` whose guards could
never match, over channel functions whose active branch logged
`"syntax needs to be determined"` and did nothing, and over an agent it
never renamed. Four builds shipped that way because nobody read the
transcript.

So read it. What to look for:

- **A flurry of retries followed by a confident summary.** The documented
  tell. One run produced nine logs named `run2-idempotent`, `run-final`,
  `run-final-idempotent`, `run-final2` — and then reported success.
- **Log lines that announce work the code below them does not do.** Rule 6
  of the spec forbids this; check it rather than trusting it.
- **Guards that cannot match.** `grep -q '"botToken".*"source":"env"'`
  against pretty-printed JSON never fires, so its step runs every time while
  looking guarded.
- **Negative claims with no evidence.** "api.telegram.org is blocked" was
  reported for a domain that was allowlisted and returning 302.

When Pi is wrong, push back in the same session with
`pi-session.sh say "..."`. When the *spec* is wrong, fix
`spec/pi-target-state.md` and re-run — that is the deliverable.

**And when Pi reports something surprising, verify it before assuming Pi is
wrong.** Three times in one session a `verify.sh` check was wrong and Pi was
right.

### What you must not do

**Never shell into the VM to fix something by hand.** Not `limactl shell`,
not a one-off `sed` through `pi-session.sh`. A VM repaired by hand looks
like success while the repo still produces failure for the next person who
clones it. This was violated twice on 2026-10-26 and both times destroyed
the evidence.

None of the scripts hand you a VM shell. That is deliberate, and reaching
around it defeats the point of the project.

Everything below is background. Read it before you change anything; you do
not need it to run a build.

---

## What you are building

A Lima VM on the host, containing a translation proxy for model access, Pi,
and then — built *by Pi* — an OpenClaw gateway with one agent and a Hermes
gateway with one agent, both optionally reachable over Telegram.

**The central idea:** the agents in the VM reach the *same models you are
using right now*. `bootstrap.sh` detects your own model access and propagates
it inward. Nobody retypes an endpoint that can be discovered.

`README.md` is the user-facing guide. `docs/original-brief.md` holds the
design reasoning. **`docs/handoff-2026-10-26.md` is where the work stands** —
read it before you touch this repo.

## The rule that matters

**The deliverable is the repo, not the VM.**

This project exists so that *another* coding agent can clone it, stand up Pi
inside a VM, and have **Pi** build the two agents from the committed spec. The
VM on this machine is a test fixture — its only purpose is to tell us whether
the writing works.

> **When something breaks, fix the script or the spec, then re-run. Never
> reach into the VM to fix it by hand.**

A VM made to work by hand is worse than a broken one: it looks like success
while the repo still produces failure for the next person. This was violated
twice on 2026-10-26 and both times destroyed the evidence.

The corollary: the only measure of progress is **does Pi, reading only the
committed spec, produce a working result unaided?** Nothing typed into the VM
counts.

## Why the deterministic steps are a script

Steps 0–9 of this file used to be prose, and a coding agent walked through
them. Every one of those steps is deterministic — detect model access, start
the VM, generate config, push it, hand the spec to Pi, narrow egress, verify.
Prose let an agent improvise; a script cannot.

The point was never to keep agents out. **You should drive these scripts.**
The point is that the steps are *fixed*, so what gets built does not depend
on which model ran the build. The contamination came from agents reaching
*past* the steps into the VM — which is why no script here hands you a VM
shell.

Pi is where judgment is genuinely needed, and where supervision is genuinely
needed: installing third-party tools whose docs drift, and writing an
idempotent `setup.sh`. That is your job, not the user's.

---

## What `bootstrap.sh` does

| | |
|---|---|
| **0. Preflight** | `jq`, `curl`, `openssl`, `limactl`, and on Linux a usable `/dev/kvm`. Also asserts nothing under `config/` is visible to git. |
| **1. Detect model access** | `scripts/detect-model-access.sh --dry-run`, shown to the user for confirmation. Then written to `config/model-access.env` (0600, gitignored). |
| **2. Start the VM** | `limactl start` in the background. Provisioning is ~10 minutes, and step 3 is four prompts, so the two overlap. |
| **3. Ask** | Agent names, then Telegram tokens via `read -rs` (not echoed, not in history), into `config/agents.env` (0600) with a generated gateway token. A file that already exists is **kept as written** — only a blank gateway token is filled in — so a user can prepare it in an editor beforehand. |
| **4. Validate** | Prints a set/blank summary (never a value), checks the names against `[A-Za-z0-9._-]`, the gateway token is non-empty, and the Telegram id is numeric. |
| **5. Wait** | For provisioning to finish. |
| **6. Push config** | `scripts/install-config.sh` — copies config over SSH, applies the **bootstrap** allowlist, and gates on a real completion plus a proxied request. |
| **7. Stop** | Writes `NEXT-STEP.md` — your brief — and exits. Pi is yours, via `scripts/pi-session.sh`. Only `--interactive-pi` runs the TUI instead. |

Then `scripts/finish-build.sh`, which you call once Pi is genuinely done
(and which `bootstrap.sh --interactive-pi` execs for itself):

| | |
|---|---|
| **8. Idempotence** | `verify/verify.sh --idempotence`, here and not later: Pi's `setup.sh` fetches from pypi.org, which is allowlisted in **bootstrap only**, so the check silently skips under `runtime` — and a skip reads like a pass in a long run. |
| **9. Narrow egress** | `agent-egress runtime`. |
| **10. Verify** | `verify/verify.sh --models`. Then summarizes. **No chat channel is enabled**, even when tokens were supplied. Exits non-zero if anything failed. |

Useful flags and variables:

```sh
./bootstrap.sh                   # resumes; safe to re-run after a failure
./bootstrap.sh --rebuild         # destroy the VM and generated config first
./bootstrap.sh --dry-run         # preflight and detection only, writes nothing
./bootstrap.sh --interactive-pi  # rare: a human watches Pi in its TUI

OPENCLAW_AGENT_NAME=…       # headless: agent names, else the defaults
HERMES_AGENT_NAME=…
BOOTSTRAP_ASSUME_YES=1      # headless: answer yes to confirmations.
                            # Required for --rebuild without a terminal,
                            # because that destroys a VM.
```

`--rebuild` deletes `config/agents.env` too, deliberately. Re-entering the
tokens is part of the test: pre-populating that file gives Pi an artificially
easier task and risks a false pass.

## Things that will bite you

**Editing `lima/agents.yaml` does not change a VM that already exists.** Lima
copies the config into the instance at creation time and re-reads *that* copy
on every start. Provision scripts do re-run on boot — but from the frozen
copy, so your edit is silently ignored and you debug the old code. Use
`--rebuild`. Cheap before Pi has built anything; destroys the agents
afterwards, so snapshot first once they exist.

**On a Linux host, read `docs/spark-handoff.md`.** It records a completed
Linux run and two traps that cost time: a `setfacl` grant on `/dev/kvm` does
**not** survive the udev event that installing qemu triggers (use the `kvm`
group, and `sg kvm -c '...'` for an already-running shell), and NextDNS may
fail the NVIDIA apt repos in a way that looks alarming and is irrelevant.

**The host must be on the network its model endpoint needs.** For Argo that
means the Argonne network or its VPN. The VM inherits host NAT: if the host
cannot reach the endpoint, neither can the VM.

**`VM_BASE_URL`, never `UPSTREAM_BASE_URL`.** The latter is the *host's*
address, often `127.0.0.1:<port>`, which from inside the VM is nothing.

**`/health` and `/v1/models` are false greens.** They answer 200 from local
state with a dead upstream. Only a completion proves the model path, which is
why `bootstrap.sh` always runs `verify.sh --models` and why `install-config.sh`
gates on a completion rather than a health check.

**A systemd user service does not read `~/.profile`.** Without a proxy drop-in
the gateway reaches the model fine (direct, uid-allowed) and fails every
allowlisted destination with `EHOSTUNREACH`. That combination passes
`--models` 30/30 and cannot reach a single chat channel.

**Guards that grep multi-line JSON never match.** `grep -q '"botToken".*"source":"env"'`
against pretty-printed JSON silently makes its step unconditional. Use `jq -e`.

---

## Verification

```sh
./verify/verify.sh                 # structure, policy and egress — costs nothing
./verify/verify.sh --models        # + one real completion per agent
./verify/verify.sh --idempotence   # + re-run Pi's setup.sh, assert no change
./verify/verify.sh --all           # + reboot persistence
```

The egress section is the point of the suite: it asserts a non-allowed
destination is **blocked** at both layers — `403` from squid through the
proxy, no connection at all around it — and that the iptables rule is scoped
to the agent uid, by checking the same request *succeeds* as root. Without
that last control, a VM with no network at all would pass.

`--idempotence` requires the bootstrap allowlist, since Pi's `setup.sh`
fetches from pypi.org. Under `runtime` the check **skips**, and a skip in a
thirty-line run reads like a pass. `bootstrap.sh` therefore runs it as step
6b, before narrowing egress.

**When you find a defect, the fix is a check that fails on it** — not just
prose in the spec. Several checks exist only because something passed while
being wrong.

**And check the tool's actual model before writing an assertion.** Three times
in one session a `verify.sh` check was wrong and Pi was right: asserting a
gateway method OpenClaw had removed, requiring a service that correctly did
not exist, and demanding an agent directory name the tool cannot produce. Each
came from writing a check against what output *looks like* rather than what
the system *does*. When Pi reports something surprising, verify it before
assuming Pi is wrong.

---

## Agent personality

Both agents keep their character in their own `SOUL.md` inside the VM
(`~/.openclaw/agents/<live agent id>/SOUL.md`, `~/.hermes/SOUL.md`). **The
agent owns that file. The user changes it by talking to the agent** — "show me
your SOUL.md", "add this paragraph" — not by editing anything in this repo.

This is forced by two earlier decisions: the VM has no mounts, so there is no
host path to edit; and Hermes rewrites its own `MEMORY.md`, `USER.md` and
skills as it learns, so a repo-tracked copy would conflict with the product by
design.

So: **the repo ships a seed, never a managed file.** Pi writes a ten-line
starter `SOUL.md` once at bootstrap and its setup script never touches it
again — re-running setup must not revert a personality the user has since
edited. Do not add a sync script, a tracked `agents/` directory, or any
mechanism for pulling these files back out.

Two traps in that seeding, both already in the spec:

- **`openclaw onboard` names the agent `main`** and ignores
  `OPENCLAW_AGENT_NAME`. The id is immutable; `set-identity` sets the display
  identity. The seed path must be the *live* agent id, read back from
  `openclaw agents list` — not `default`.
- **The seed guard must check content, not existence.** The Hermes installer
  writes its own vendor persona, so `[ -f ] && skip` leaves an agent that has
  never heard of the configured name. Guard on `grep -q "You are <NAME>"`.

The escape hatch, for when an agent is too broken to talk to, is documentation
rather than code:

```sh
limactl shell agents -- nano ~/.openclaw/agents/<name>/SOUL.md
limactl shell agents -- nano ~/.hermes/SOUL.md
```

Recovery from a genuinely broken agent is the VM snapshot, not a backup
mechanism of our own.

`local/` is gitignored and holds hand-written `SOUL.md` content migrated from
another deployment. Installing those is a **one-time manual exception** the
user has approved, and is explicitly *not* something the repo should automate.
Do not build a sync mechanism for them.

---

## Safety rules

These are not negotiable, and they override convenience.

- **Curl-to-bash installers** (OpenClaw, Hermes, Tailscale): fetch the script
  and show it to the user, or pin a release, before executing it. This applies
  to Pi inside the VM too — it is written into `spec/pi-target-state.md`.
- **Never enable a chat channel before verification passes.** Stop and
  summarize. Enabling one is a separate decision the user makes afterwards.
- **Never write a token into a config file or echo one into a chat.** Use env
  SecretRefs. The detection script never prints credentials; keep that
  property. A rule stated without a mechanism and a check gets reported as
  satisfied without being satisfied — `verify.sh` asserts
  `plaintext=0, unresolved=0` from a plain login shell.
- **Never ask the user for a secret in conversation.** Bot tokens and the
  Telegram user id are supplied by the user editing `config/agents.env`
  directly. Whether a secret ends up in a transcript must not depend on which
  model happened to run this build. If the user pastes one anyway, use it —
  refusing after the fact helps nobody — but tell them plainly that it is now
  in the transcript and that rotating it via @BotFather is cheap.
- **Never commit anything from `config/`.** `bootstrap.sh` checks this at
  preflight; check again before you finish.
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
provisioning, template its config in `config/`, and give its secrets the same
SecretRef mechanism *and the same audit check* as Argo's.

---

## Repo map

```
bootstrap.sh            the deterministic host-side build, steps 0-6
AGENTS.md               this file. CLAUDE.md is a symlink to it.
README.md               user-facing guide -- what a human does after cloning
lima/agents.yaml        the VM
scripts/
  detect-model-access.sh   find the endpoint the caller already uses
  install-config.sh        push config over SSH, lock egress down
  pi-session.sh            drive and supervise Pi headlessly  <-- your job
  run-bootstrap.sh         Pi's TUI; only used by --interactive-pi
  finish-build.sh          steps 6b-9: idempotence, narrow egress, verify
  check-telegram-tokens.sh validate bot tokens with getMe
spec/pi-target-state.md target-state spec Pi builds from
config/                 local config; only *.example is committed
verify/verify.sh        automated checks
local/                  gitignored; the user's own files. Not managed here.
docs/
  handoff-2026-10-26.md READ FIRST if you are working on this repo
  spark-handoff.md      read FIRST on a Linux host (DGX Spark)
  original-brief.md     the pre-build design brief and its reasoning
  personality.md        how SOUL.md works
  failover.md           the vLLM fallback (unverified)
todo.md                 what is unfinished
```

## Current status

| Path | State |
|---|---|
| `bootstrap.sh` | Steps 0-5 ran clean on Linux 2026-10-26. Step 6 onward unproven. |
| `scripts/pi-session.sh` | **Written 2026-10-26, never run.** |
| `scripts/finish-build.sh` | **Written 2026-10-26, never run.** |
| `lima/agents.yaml` | Linux/qemu verified from scratch 2026-10-21 (DGX Spark). macOS/vz passed earlier, **not re-run since**; see `todo.md` item 00. |
| `scripts/*` | Implemented, run against a real VM. |
| `spec/pi-target-state.md` | Implemented. Hermes Telegram corrections (`63a2897`) are **unproven by Pi.** |
| `verify/verify.sh` | 30 pass, 0 fail with `--models`; `--idempotence` passed. |
| `docs/snapshots.md` | **Not written**, though `docs/personality.md` references it. |

If you reach an unwritten step, stop and tell the user rather than improvising
a replacement.
