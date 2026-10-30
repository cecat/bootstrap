# Target state for this machine

You are Pi, running inside a sandboxed VM. Build the agent environment
described below.

Your **deliverable is `~/agent-bootstrap/setup.sh`** — an idempotent script
that brings a fresh VM to this state. The script is the product, not the
running system. Put every change in the script and run the script; do not
configure anything by typing ad hoc commands.

Figure out the details yourself. Where this file does not say how, read the
tool's own documentation and decide. If something here contradicts what the
installed version actually does, trust the software and say so in your
summary.

---

## Rules

1. **Never weaken the sandbox.** If an install fails because a domain is
   blocked, report the blocked domain. Do not run `agent-egress unlock`,
   edit iptables, or add to the allowlist.

2. **Never let a bot be reachable without an allowlist.** A live agent has
   shell access and no permission prompts, and Telegram delivers a
   stranger's DM straight to it. `api.telegram.org` is itself allowlisted,
   so a reached agent can read your config and send credentials back out.

   Order matters: restrict first, enable last. `openclaw channels add`
   leaves the channel enabled with no `allowFrom`, so disable it
   immediately, set the policy and the allowlist, and only re-enable once
   everything else verifies. Hermes has no enable flag — its adapter polls
   from the moment the gateway starts, so its `TELEGRAM_ALLOWED_USERS` must
   be set *before* first start.

3. **Never pipe an installer into a shell.** Download to
   `~/agent-bootstrap/installers/`, record the SHA256, execute the saved file.

4. **Never write a secret into a config file, a log, or your output.**
   Secrets live in `~/.config/agent-sandbox/agents.env` (0600) and are
   referenced through systemd `EnvironmentFile=` or the agent's own
   SecretRef mechanism. Print variable names, never values.

5. **Report only what you verified — including failures.** "Installed"
   means a command exited zero and you are quoting its output. Before
   writing "blocked" or "unsupported", run the command that shows it. "I did
   not check" is an acceptable thing to write; a diagnosis you did not make
   is not.

6. **No placeholders described as done.** If you cannot work out how to
   configure something, say so and stop. A log line claiming an action, over
   code that does not perform it, is the same offence.

---

## Preconditions

Stop if any of these fails; they are not yours to fix.

| Check | Expected |
|---|---|
| `sudo agent-egress status` | phase `bootstrap`, lockdown active |
| `curl -s --noproxy '*' "$VM_BASE_URL/v1/models"` | 200 |
| `~/.config/agent-sandbox/agents.env` | exists, 0600 |

## Model access

There is no model gateway in this VM. The host has one; point the agents at
it. `~/.config/agent-sandbox/model-access.env` gives you `VM_BASE_URL` (use
this one — `UPSTREAM_BASE_URL` is a host-side address that is nothing from
here), `CREDENTIAL`, and model names.

The endpoint is argo-proxy and serves both shapes: `/v1/messages`
(Anthropic) for Pi and OpenClaw, `/v1/chat/completions` (OpenAI) for Hermes.
Reach it **directly, `--noproxy '*'`** — it is allowed by uid as a single
fixed host:port. Everything else goes through `127.0.0.1:3128`, already in
your environment.

The API key is an ANL username, read from `CREDENTIAL`. A wrong one does not
return 401: the stream opens, returns 200, and dies mid-flight. So an auth
failure here looks like a network fault.

**Verified means a completion.** `/health`, `doctor` and `/v1/models` all
answer 200 against a dead upstream.

## What to build

### OpenClaw

Install from `https://openclaw.ai/install.sh`. Onboard non-interactively
with a token gateway and a daemon, running as a systemd **user** service.

- Provider id must be exactly **`argo-gateway`**, pointed at `VM_BASE_URL`,
  with `CREDENTIAL` as the API key. `verify.sh` asserts this id.
- Exactly one agent, displaying the name in `OPENCLAW_AGENT_NAME`. Onboard
  picks the **id** itself and ignores your env, and there is no rename —
  `openclaw agents` offers add/delete/set-identity only. So do not try to
  change the id or add a second agent to get the name you want: set the
  *identity*, then read it back from `openclaw agents list`. Derive any
  path you need (the SOUL.md directory) from that output rather than
  assuming what the id will be.
- `onboard` writes the gateway token and apiKey into `openclaw.json` as
  plaintext. Migrate both to env SecretRefs (`openclaw secrets apply`).
  `openclaw secrets audit --check` must report `plaintext=0` **and
  `unresolved=0`** from a clean login shell. Quote that line.

### Hermes

Install from `https://hermes-agent.nousresearch.com/install.sh`. Configure
the same gateway on its OpenAI-compatible path.

Hermes resolves credentials from `~/.hermes/.env` **in preference to the
environment**, so exporting a variable is not enough — the value has to be
in that file. Work out which name the installed version reads, and prove it
with a completion run with no `--api-key` flag.

Install the gateway service (`hermes gateway install`) when Telegram tokens
are present. Its Telegram adapter needs three things: the
`telegram-platform` plugin enabled, its `python-telegram-bot` dependency
fetched from pypi.org (**bootstrap allowlist only — it must happen while you
run**), and credentials in `~/.hermes/.env`. Confirm from the journal that
the adapter connected; a running service proves nothing.

### Pi's own provider

`~/.pi/agent/models.json` is already correct. **Leave it alone.** It is the
supervision channel: `pi -p --provider argo` must keep working, so the key
`argo` must keep existing under the `providers` object. A previous run
renamed it to match OpenClaw's id and destroyed the only means of asking Pi
to repair it. Two tools, two files, two ids, both correct.

### Systemd services need the proxy

A user service does not read `~/.profile`, so a gateway started by systemd
has no proxy variables, reaches the model fine (direct, uid-allowed), and
fails every allowlisted destination with `EHOSTUNREACH`. That state passes
a model check and cannot reach Telegram.

Put the proxy variables and the `EnvironmentFile=` lines in the same
drop-in, including `NODE_USE_ENV_PROXY=1` (Node ignores the proxy without
it). Prove it against a proxied destination, not the model endpoint.

### Personality seeds

Write `~/.openclaw/agents/<live agent id>/SOUL.md` and `~/.hermes/SOUL.md`.
These are seeds: once written, the file belongs to the agent and its user,
and your script must never touch it again.

Guard on **content, not existence** — the Hermes installer writes its own
vendor persona, so skip only if the file already says `You are <NAME>`.

```markdown
# SOUL

You are NAME, a personal assistant running in a sandboxed VM.

- Be direct. Short answers when short answers will do.
- Say what you did, including what failed. Never claim a success you did not verify.
- You have shell access and no permission prompts. Stop and ask before anything
  destructive or irreversible.
- You cannot reach the host machine, and your network egress is allowlisted. If
  something is blocked, say so rather than working around it.
- This file is yours. If the user asks you to change how you behave, edit it.
```

### Telegram channels

If tokens are present in `agents.env`, configure each agent's channel
restricted to `TELEGRAM_ALLOWED_USER_ID`; if absent, skip and say so.

Validate every token first and quote the result — `api.telegram.org` is
allowlisted in both phases specifically so you can test rather than
configure blind:

```sh
curl -sS "https://api.telegram.org/bot$TOKEN/getMe"
```

A rejected token means configure nothing for that agent and say so. Bot
usernames are not secrets; tokens are.

Hermes' credentials go in `~/.hermes/.env` (0600). Do not invent another
location: `verify.sh` decides whether to check the allowlist at all by
looking there, so credentials elsewhere mean a live bot and a skipped
safety check.

For OpenClaw, migrate the bot token to a SecretRef like the others, then
**enable the channel as the final step**, once the allowlist is read back
from the file and everything else verifies. Do not message either bot to
test it — the user does that.

### Fallback

If `VLLM_BASE_URL` is set in `agents.env`, configure failover to it from
current documentation and say which syntax you used. If it is unset, skip
and say so. A guessed failover config is worse than none.

---

## Idempotence

Every step guards before it acts. Run `setup.sh` twice: the second run must
exit 0, change nothing, restart no services and reinstall nothing. If it
changes something, find the guard rather than re-running and hoping.

Guards that grep multi-line JSON never match — `jq -e` instead.

## When you are done

Stop. Do not chat with the agents to try them out.

Summarise: what you installed with versions; the actual text from your
verification commands; both idempotence runs; installer checksums; what you
skipped and why; per-agent channel state with the `dmPolicy`/`allowFrom` you
read back; the secrets audit line; the `getMe` result per token; and
anything that surprised you — including where this spec was wrong.

Before writing it, check each claim against rule 5: point at the output that
proves it, or change the wording.
