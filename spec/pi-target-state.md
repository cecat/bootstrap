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

1. **Never weaken the sandbox.** The agents may reach the public web; what
   the sandbox denies is the private network around them — this host, its
   other services, the LAN — because that is where an agent could damage
   the infrastructure it runs on. If something is blocked, report it. Do
   not run `agent-egress unlock`, edit iptables, or edit the allowlist.

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

3. **Never run a command that does not exit.** No `tail -f`, no `watch`, no
   `journalctl -f`, no interactive prompt. You have no terminal to interrupt
   one from: it blocks until your whole turn is killed, and the work in
   progress is lost. To see a log, read the file. To watch a long command,
   run it with `timeout` and read its output afterwards.

4. **Never pipe an installer into a shell.** Download to
   `~/agent-bootstrap/installers/`, record the SHA256, execute the saved file.

5. **Never write a secret into a config file, a log, or your output.**
   Secrets live in `~/.config/agent-sandbox/agents.env` (0600) and are
   referenced through systemd `EnvironmentFile=` or the agent's own
   SecretRef mechanism. Print variable names, never values.

6. **Report only what you verified — including failures.** "Installed"
   means a command exited zero and you are quoting its output. Before
   writing "blocked" or "unsupported", run the command that shows it. "I did
   not check" is an acceptable thing to write; a diagnosis you did not make
   is not.

7. **No placeholders described as done.** If you cannot work out how to
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

**Both agents run `argo:claude-5-opus`.** Not the installer's default, not
whatever an onboarding flag suggests, and not a model you saw in an
example. The whole point of this build is that the agents reach the same
models the supervising coding agent uses, so configure:

- OpenClaw: the provider's model id — `--custom-model-id "argo:claude-5-opus"`
- Hermes: `hermes config set model.default argo:claude-5-opus`

`model-access.env` carries `MODEL_OPUS`, `MODEL_SONNET` and `MODEL_HAIKU`
as the host's own aliases (`claudeopus5` and friends). The gateway accepts
either spelling; prefer the `argo:` form above, which is what
`/v1/models` lists.

This is written down because it went wrong: a build set both agents to
`argo:gpt-4o` — an installer default, never chosen — and nothing caught
it for weeks, because `verify.sh` only asked whether a completion
succeeded and gpt-4o completes fine. A user then spent an evening being
confidently lied to by an agent about files it had not written. If you
cannot set a model, say so loudly rather than accepting a default.

The endpoint is argo-proxy and serves both shapes: `/v1/messages`
(Anthropic) and `/v1/chat/completions` (OpenAI). Both were confirmed
working on 2026-11-09. Pi uses the Anthropic path; **Hermes and OpenClaw
both use the OpenAI one** — OpenClaw's provider is `api:
"openai-completions"`. An earlier version of this file claimed OpenClaw
was on the Anthropic path, which was simply untrue, and it matters
because some output-cap behaviour is adapter-specific.
Reach it **directly, `--noproxy '*'`** — it is allowed by uid as a single
fixed host:port. Everything else goes through `127.0.0.1:3128`, already in
your environment.

**Both agents' base URL must end in `/v1`.** `VM_BASE_URL` is the bare
host (`http://HOST:PORT`), and both clients append only the trailing
segment — an OpenAI client given the bare host POSTs to
`/chat/completions`, not `/v1/chat/completions`, and argo-proxy answers
`HTTP 405: Method Not Allowed`. Configure `$VM_BASE_URL/v1` for Hermes'
`providers.argo-gateway.base_url` and for OpenClaw's provider `baseUrl`.
Measured 2026-11-09: the bare host gives 405 on every completion while
`curl "$VM_BASE_URL/v1/chat/completions"` returns 200, so the
precondition above passing proves nothing about this.

The API key is an ANL username, read from `CREDENTIAL`. A wrong one does not
return 401: the stream opens, returns 200, and dies mid-flight. So an auth
failure here looks like a network fault.

**Verified means a completion.** `/health`, `doctor` and `/v1/models` all
answer 200 against a dead upstream.

## What to build

### Both agents: the clock

Set each agent's timezone to the IANA name in `AGENT_TIMEZONE` (from
`~/.config/agent-sandbox/agents.env`). For Hermes that is the `timezone`
key; find OpenClaw's equivalent in its own configuration and set that too.

This is not cosmetic. It decides what "2pm today" resolves to, when a 6am
cron job fires, and the time Hermes stamps into the agent's prompt. Left
unset, both agents inherit whatever zone the VM host happens to carry —
right by luck on the machine this was built on, silently wrong on a clone
elsewhere. Wrong by a whole zone is not an error anywhere; it is a meeting
booked on the wrong day.

**A caution that belongs with it:** Hermes builds the system prompt,
including its "Current time" line, **once per session** and reuses it for
the life of the conversation. A session left open for a day therefore
carries yesterday's clock, and an agent asked for "2pm today" will answer
against it with perfectly correct arithmetic. Setting the zone does not
fix that; only a new session does. Do not try to work around it here.

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

**Undo what the onboarding wizard guessed.** Three of its defaults are
wrong here and none of them fail loudly:

- **`maxTokens: 4096` on every model row.** The wizard writes this for a
  custom provider; OpenClaw's own default for an unpinned model is 32768.
  It means OpenClaw *explicitly asks* for a 4096-token ceiling the
  endpoint never imposed — measured 2026-11-09, the same endpoint
  returned 14,606 tokens in one response without truncating. Every long
  reply is cut short, with no error. Remove the per-row `maxTokens` so
  the catalogue default applies, or set one deliberately above 16000.
- **`contextWindow: 128000` on every model row**, also a blanket wizard
  value. Every compaction threshold is derived from it, so if it is
  wrong, so is all of them. Leave it unless you can confirm the real
  window; just know it was guessed.
- **A stale `agents.defaults.models` entry naming `argo:gpt-4o`.** Inert
  — it neither selects nor registers a model — but it is the exact id
  that silently ran both agents for weeks, and the next person to read
  this file will misread it. Delete the entry.

**Compaction must not run on the main model.** Set
`agents.defaults.compaction.model` to the same cheap model Hermes uses
for compression, and `compaction.thinkingLevel: "off"`. Unset, compaction
summarises on Opus with reasoning enabled, and the vendor warns the
allowance can be spent on thinking tokens before any summary is emitted.
A rejected summary leaves history uncompacted — and under the configured
`mode: "safeguard"` the user is warned **even when `notifyUser` is
false**. That is the same warning loop Hermes produced; it is worth
avoiding once rather than diagnosing twice.

**Memory indexing needs a provider that exists.** `memory.search.provider`
unset means OpenAI embeddings, and there is no OpenAI key here — so
indexing stops, while the `session-memory` hook keeps writing memory
files. The agent accumulates memories it can never search and appears, over
weeks, to forget things it was told. Nothing errors. Set
`memory.search.provider: "none"` for keyword-only search and reindex
once (`openclaw memory index --force --agent <id>`).

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

**Compression must fit in 4096 output tokens.** Set both:

    compression.threshold_tokens: 60000
    auxiliary.compression.model: argo:gemini-3.8-flash

The gateway caps generation at 4096 tokens when the client sends no
`max_tokens`, and Hermes deliberately sends none to a custom
OpenAI-compatible endpoint — its docs say such endpoints "receive no
automatic catalog-sized output cap. Their server defaults apply." Hermes
exposes no setting to change that. Measured 2026-11-09: a request with no
cap stops at exactly 4096 with `finish_reason=length`, while the same
request asking for 8000 completes.

Left alone, the agent compresses at half its context window — around
150,000 tokens — and the summary of that much conversation does not fit
in 4096. It truncates, compression aborts, a 60s → 300s → 900s cooldown
arms, the context keeps growing, and the user gets three warnings every
few hours forever. `threshold_tokens` is an absolute floor and Hermes
takes the lower of it and the ratio, so 60000 makes each summary small
enough to land.

The model override is the second half: compression is mechanical work
that otherwise runs on the main Opus model, slowly and expensively, for
no benefit. Any `*-flash` the gateway lists will do — confirm with a real
completion, not `/v1/models`.

**Point the other auxiliary work at the same cheap model.** Compression
was not the only mechanical task defaulting to Opus:

    auxiliary.background_review.model      the post-turn fork that
                                           extracts memories and skills;
                                           replays the conversation
    auxiliary.background_review.max_input_tokens: 48000
    auxiliary.title_generation.model       a 64-token session title
    auxiliary.approval.model               classifies every flagged
                                           shell command
    auxiliary.approval.timeout: 60         30s is tight through a proxy

None of these fail visibly. They are slow and expensive, and the approval
classifier timing out silently falls through on a path that exists to
gate shell commands.

**Prune ended sessions.** Set `sessions.auto_prune: true` with
`sessions.retention_days: 90`. The vendor is blunt about the default:
*"Without pruning, `state.db` grows without bound — multi-GB files within
weeks were reported on gateway + cron installs."* That is exactly this
build, on a VM with a finite disk. Only *ended* sessions are removed;
live Telegram threads are untouched. Left alone, the first thing the user
sees is the bot spontaneously asking about disk pruning over Telegram,
which reads as a malfunction rather than a disk warning.

**Pin an explicit stale timeout.** Set
`providers.argo-gateway.stale_timeout_seconds: 90`.

Hermes auto-detects localhost and **LAN** endpoints and relaxes its
streaming timeouts: socket read 120s → 1800s, stale-stream detection
180s → 900s, and non-streaming stale detection off entirely. `VM_BASE_URL`
is a `192.168.x.x` address, so all of that applies to us — silently,
with nothing in the config saying so. The relaxation is meant for a slow
local GPU; ours is a translation shim in front of a remote service. Left
alone, an upstream that accepts the connection and then goes quiet hangs
a Telegram turn for up to thirty minutes instead of failing in ninety
seconds. An explicit value is honoured even on a local endpoint.

**Stop cron replaying missed slots.** Set `cron.catch_up_missed: false`.
After any VM suspend, reboot or gateway restart, every schedule that came
due while it was down fires once on return, each delivering to Telegram:
a burst of stale briefs on a morning that should have had one. A job that
genuinely wants a late run can ask for it per-job.

**Do not offer strangers a pairing code.** Set
`unauthorized_dm_behavior: ignore`. The default (`pair`) sends an unknown
Telegram user a one-time pairing code. Who may message this bot is the
*only* access control on an agent that has shell access, a mailbox and
the user's Drive; a pairing affordance is the wrong thing to hand out.

**Leave the curator alone, but know what it does.** Hermes' curator runs
a deterministic pass that archives agent-written skills unused for 30
days. Bundled skills are exempt, so the Google one is safe — but a skill
the agent writes for itself will quietly disappear after a month. That is
reasonable default behaviour and this build keeps it; it is recorded here
so its disappearance is not mistaken for a fault.

**Compact an idle thread before answering it.** Set
`compression.idle_compact_after_seconds: 1800`. A conversation resumed
after a gap otherwise re-reads its whole stale context before replying.
There may be a second benefit — in-place compaction rebuilds the system
prompt, which is where the `Current time:` line lives, so this *might*
refresh the stale clock described above. That is an inference from the
vendor's wording, not a documented promise: do not report it as fixed
unless you measure it.

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

Give it one in the drop-in, alongside the `EnvironmentFile=` lines:
`http_proxy`, `https_proxy` and `NODE_USE_ENV_PROXY=1`.

Node 24's undici proxies everything and ignores `NO_PROXY`, so the model
gateway goes through squid too. That is fine: squid allows the gateway
address ahead of its private-range denial. Do not route the model path
around the proxy — a client-side exemption undici ignores is how this
broke before.

**OpenClaw needs a second, separate setting.** Its HTTP tools read a
managed proxy from config, not from the environment, so the drop-in alone
leaves `web_fetch` going direct into the uid lockdown:

    openclaw config set proxy.proxyUrl http://127.0.0.1:3128

Without it the gateway looks healthy, Telegram works and completions pass,
and only the agent's own web tools fail. Hermes needs no equivalent — it
honours the environment.

**Prove it against a proxied destination, not the model endpoint** — and
prove it the way the adapter actually connects. A journal line saying the
adapter *started* is not the same as a request completing. For OpenClaw
that means `web_fetch` specifically: every other check passes while it is
broken.

### Personality seeds

Write `~/.openclaw/agents/<live agent id>/SOUL.md` and `~/.hermes/SOUL.md`.
These are seeds: once written, the file belongs to the agent and its user,
and your script must never touch it again.

Guard on **content, not existence** — the Hermes installer writes its own
vendor persona, so skip only if the file already says `You are <NAME>`.

**The seed must tell the agent where it lives.** Hermes reads its identity
from `$HERMES_HOME`, which is `~/.hermes` — but `~/SOUL.md` is the obvious
guess, and both a GPT-4o and an Opus 5 Gandalf made it. The second one
created a 2 kB `~/SOUL.md` that looks right, is never loaded, and then
blocks its own rewrite: Hermes refuses to overwrite a file the task has
not read in full, so the agent gets stuck editing a decoy. The user
meanwhile sees an identity file that never changes, and an agent
insisting it saved the change. One line in the seed ends this, so the
first bullet of each is the path — the agent is the only one who can fix
it later, and it has to know where to look.

```markdown
# SOUL

You are NAME, a personal assistant running in a sandboxed VM.

- This file is `ABSOLUTE_PATH_TO_THIS_FILE`. It is the only file that
  changes who you are. `~/SOUL.md` is not it: writing there does nothing,
  however plausible the path looks. Read this one in full before editing
  it, or the write will be refused.
- Be direct. Short answers when short answers will do.
- Say what you did, including what failed. Never claim a success you did not verify.
- You have shell access and no permission prompts. Stop and ask before anything
  destructive or irreversible.
- You can read the public web with `web_fetch`, which is the supported way.
  No browser is installed, so a browser tool will fail if you reach for one.
  `http://` URLs fail here; retry as `https://` before reporting failure, and
  when you do report one, say which tool you used and what the error was.
- You cannot reach the host machine or its local network. If something is
  blocked, say so rather than working around it.
- This file is yours. If the user asks you to change how you behave, edit it.
```

Substitute both placeholders as you write each file: `NAME` from
`agents.env`, and `ABSOLUTE_PATH_TO_THIS_FILE` with the real path of the
file you are writing — `/home/<user>/.hermes/SOUL.md` or
`/home/<user>/.openclaw/agents/<id>/SOUL.md`, expanded, not `~`. A `~`
there is a path the agent cannot act on reliably, which is the whole
point of the line.

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

**The OpenClaw adapter reads `TELEGRAM_BOT_TOKEN`**, not the
`OPENCLAW_TELEGRAM_BOT_TOKEN` that `agents.env` carries. Give the service
the name it expects. With the wrong name the adapter never starts polling,
the agent is silent, and every automated check still passes — that is a
mute agent reading as 37 passed, 0 failed. Whatever you do here, do not
write the token into a *second* plaintext file; `agents.env` already holds
it at 0600 and one copy is enough.

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

Before writing it, check each claim against rule 6: point at the output that
proves it, or change the wording.
