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
./scripts/pi-session.sh transcript  # what it actually did
./scripts/pi-session.sh say "..."   # push back, same session
./scripts/finish-build.sh           # idempotence, narrow egress, verify
./verify/verify.sh --models         # the evidence
```

`bootstrap.sh` never prompts. It stops once, early, if `config/agents.env`
needs filling in — two agent names, optionally a Telegram bot token per
agent and a numeric user id. **That file is the user's to edit.** Never ask
for a secret in conversation; a token pasted into a chat is a token in a
transcript.

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

**Curl-to-bash installers** get downloaded, checksummed and then executed —
never piped. This applies to Pi too, and is in its spec.

## Permissions

Every tool has its own approval mechanism, so this list is prose. Claude
Code users get `.claude/settings.json` committed, which encodes it.

Allow unattended: `./bootstrap.sh`, `./scripts/*.sh`, `./verify/verify.sh`,
`git`, `limactl list`, and
`limactl shell agents -- cat /etc/agent-sandbox/phase`.

Deny: `limactl shell agents -- <anything else>`, `limactl delete|stop`, and
`agent-egress unlock`. The asymmetry is the point — the two read-only probes
above are named deliberately, the general form is not. "Fix the spec, not
the VM" is enforceable as a permission; as prose it has already been
violated twice.

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

Only Argo is implemented. The VM runs one translation proxy serving
`/v1/messages` (Anthropic shape → Pi, OpenClaw) and `/v1/chat/completions`
(OpenAI shape → Hermes). Hermes is why a translator is needed at all.

To add one: extend the `case "$BASE_HOST"` classifier in
`scripts/detect-model-access.sh`, add its install step to
`lima/agents.yaml`, template its config in `config/`, and give its secrets
the same SecretRef mechanism *and the same audit check* as Argo's.
