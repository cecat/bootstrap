# Target state for this machine

You are Pi, running inside a sandboxed VM. Build the agent environment
described below.

Your **deliverable is `~/agent-bootstrap/setup.sh`** — an idempotent script
that brings this machine to the target state. The script is the product, not
the running system. Someone must be able to clone this onto a fresh VM, run
that one script, and arrive at the same place. Do not configure anything by
typing ad hoc commands; put every change in the script and run the script.

---

## Hard rules

Violating any of these means stopping and reporting, not working around it.

1. **Never weaken the sandbox to make something work.** If an install fails
   because a domain is blocked, report the blocked domain. Do **not** run
   `agent-egress unlock`, edit iptables, or add to the allowlist yourself.
   A blocked domain is information for the user, not an obstacle to route past.

2. **Never enable a chat channel.** Not Telegram, not anything else. Install
   and configure them as *disabled*. Enabling happens after a human reads your
   summary. See *Stop here* at the end.

3. **Never pipe an installer into a shell.** Download it to
   `~/agent-bootstrap/installers/`, record its SHA256, then execute the saved
   file. The saved copy and its checksum are what make this auditable.

4. **Never write a secret into a config file, a log, or your output.** Secrets
   live in `~/.config/agent-sandbox/agents.env` (mode 0600). Reference them
   through systemd `EnvironmentFile=` or the agent's own SecretRef mechanism.
   Print variable *names*, never values.

   Mode 0600 is not sufficient and "it works" is not evidence. A previous run
   wrote both the gateway token and the model credential as plaintext into
   `openclaw.json`, reported success, and was caught only by an external
   audit. See *Secrets: the required mechanism* below — it is mandatory, not
   advisory, and you must quote the audit output that proves it.

5. **Never report anything you have not verified — including failures.**
   "Installed" means a doctor or status command exited zero and you are
   quoting its output.

   This cuts both ways, and the second direction is easier to miss. A
   previous run reported "api.telegram.org is blocked by the egress
   allowlist" without ever sending a request. It was not blocked; the domain
   was in the active allowlist and reachable. An unverified *failure* is just
   as false as an unverified success, and worse in one way: it sends someone
   to fix a problem that does not exist, and it quietly abandons work you
   could have finished.

   So before you write "blocked", "unavailable", "not supported" or "could
   not", run the command that shows it and quote what came back. "I did not
   check" is an acceptable thing to write. A diagnosis you did not make is
   not.

6. **Never leave a placeholder and describe it as done.** If you cannot
   determine how to configure something, the only acceptable outcomes are to
   find the answer in current documentation or to **stop and report it as
   unresolved**. Writing a comment such as "exact syntax needs to be
   determined" into a script, letting that branch no-op, and then listing the
   feature as configured in your summary is a false report — a previous run
   did exactly this with Telegram, and the human believed channels were set up
   when nothing had been written at all. An honest "I could not do this, and
   here is what I tried" is always the better answer.

   **A log line that claims an action, over code that does not perform it, is
   the same offence.** A later run wrote this and shipped it:

   ```sh
   log "Creating OpenClaw agent '$OPENCLAW_AGENT_NAME'..."
   # The onboard process should have created a default agent already
   openclaw agents list
   log "OpenClaw agent created"
   ```

   Nothing was created. The agent kept its default name, the user's chosen
   name was never applied, and `setup.sh` printed two lines saying otherwise.
   If a function logs that it did something, the code between those lines
   must do it — or the log must say what actually happened
   ("agent already exists as 'main'; not renamed").

---

## Preconditions

Check these first and stop if any fails — they are someone else's job, not
yours to fix:

| Check | Expected |
|---|---|
| `sudo agent-egress status` | phase `bootstrap`, lockdown `active` |
| `curl -s --noproxy '*' "$VM_BASE_URL/v1/models"` | HTTP 200 |
| `ls ~/.config/agent-sandbox/agents.env` | exists, mode 0600 |

### Model access

**There is no model gateway in this VM.** The host already has a working path
to models; your job is to point the agents at it, not to install anything new.

Read `~/.config/agent-sandbox/model-access.env` (mode 0600). It gives you:

| Variable | Meaning |
|---|---|
| `VM_BASE_URL` | **the endpoint to configure agents with.** Always use this one. |
| `UPSTREAM_BASE_URL` | what the *host* uses. Often `127.0.0.1:<port>`, which from inside this VM is nothing at all. |
| `CREDENTIAL` | the API credential. For Argo this is an ANL username, not a key. |
| `MODEL_OPUS` / `MODEL_SONNET` / `MODEL_HAIKU` | model names |

**Use `VM_BASE_URL` everywhere.** When the host reaches its models through a
local tunnel, `UPSTREAM_BASE_URL` is a host-side loopback address and
connecting to it from here gives "connection refused" — which looks exactly
like the model gateway being down, and will send you to report a precondition
failure that does not exist. `VM_BASE_URL` is the same endpoint rewritten to
an address this VM can actually reach.

That address is reached **directly, not through the proxy** — it is the one
destination the egress rules allow by uid, because it is a single fixed
host:port rather than open egress. Use `--noproxy '*'` when you curl it.
Everything else must go through `127.0.0.1:3128`, which is already in your
environment; do not override it.

**The endpoint serves both API shapes.** It is an argo-proxy instance, which
translates between formats:

| Path | Shape | Used by |
|---|---|---|
| `/v1/messages` | Anthropic | Pi, OpenClaw |
| `/v1/chat/completions` | OpenAI | Hermes |

Both are verified working against this gateway, with model ids in either the
`argo:claude-4.5-sonnet` form or the bare `claude-sonnet-5` form. So Hermes
does **not** need a shim: point it at the same base URL and let it use the
OpenAI path.

The API key is the ANL username. The gateway runs with username-passthrough,
so a placeholder key fails with "the username is not registered in ARGO".
Read the value from `CREDENTIAL` in model-access.env and reference it through
the environment; never inline it into a config file.

**Verified means a completion.** A health check, a `doctor` command, or a
model-list endpoint can all return success while the upstream is dead -- that
has happened repeatedly here. Do not report an agent as working until you have
seen it produce a model response, and quote that response.

### Secrets: the required mechanism

This is rule 4 made concrete. `openclaw onboard` writes the gateway token and
the provider apiKey into `openclaw.json` **as plaintext**. Leaving them there
violates rule 4, so migrating them is part of the build, not an optional
hardening pass.

Three pieces, all required, in this order:

1. **Give the service the variables.** Do not edit
   `openclaw-gateway.service` directly -- `openclaw onboard --install-daemon`
   regenerates it and your edit is lost. Use a drop-in at
   `~/.config/systemd/user/openclaw-gateway.service.d/10-secrets.conf`:

   ```ini
   [Service]
   EnvironmentFile=-%h/.config/agent-sandbox/agents.env
   EnvironmentFile=-%h/.config/agent-sandbox/model-access.env
   ```

   Then `systemctl --user daemon-reload`. **The same drop-in must also carry
   the proxy environment** — see *The gateway needs the proxy* below. Write
   both halves at once; a drop-in with only the secrets half produces a
   gateway that answers model calls and silently fails every channel.

2. **Rewrite the config to reference, not contain.** Write a plan file and
   apply it. Both env vars must be exported in *your* shell when you run this
   or the command refuses:

   ```json
   { "version": 1, "protocolVersion": 1, "targets": [
     { "type": "gateway.auth.token", "path": "gateway.auth.token",
       "pathSegments": ["gateway","auth","token"],
       "ref": { "source": "env", "provider": "default",
                "id": "OPENCLAW_GATEWAY_TOKEN" } },
     { "type": "models.providers.apiKey",
       "path": "models.providers.argo-gateway.apiKey",
       "pathSegments": ["models","providers","argo-gateway","apiKey"],
       "providerId": "argo-gateway",
       "ref": { "source": "env", "provider": "default",
                "id": "CREDENTIAL" } } ] }
   ```

   `openclaw secrets apply --from <plan> --dry-run` first, then without it.

3. **Give an interactive shell the same variables.** The systemd drop-in does
   not help a human at a prompt, and without them every `openclaw` CLI call
   dies with "configured as a secret reference but is unavailable in this
   command path". `install-config.sh` already appends a block to `~/.profile`
   that sources both env files and exports `CREDENTIAL`,
   `OPENCLAW_GATEWAY_TOKEN` and the channel tokens.

   **If you add a SecretRef for anything not already exported there, export
   it too.** The rule is: every key referenced by a `{"source":"env"}` ref
   must be visible in a plain login shell. This is easy to get wrong for
   channel tokens, because the *gateway* resolves them from its
   EnvironmentFile and keeps working perfectly — only the CLI breaks, so the
   system looks healthy until someone runs an audit.

**Prove it.** `openclaw secrets audit --check` must exit 0 and report
`plaintext=0` **and `unresolved=0`**, run from a *clean* login shell — not one
where you have just sourced `agents.env`, which hides exactly this failure.
Quote that line in your summary. Then restart the gateway and run one real
completion, which proves the service still resolves its own token.

### The gateway needs the proxy — and the failure is deceptive

**A systemd user service does not read `~/.profile`.** The proxy variables
that make egress work are exported there, so a gateway started by systemd has
none of them. It then tries to reach the internet directly, the iptables
lockdown refuses it, and every outbound call dies `EHOSTUNREACH`.

What makes this hard to catch: **the model path keeps working.** The model
gateway is in `NO_PROXY` and allowed directly by uid, so completions succeed
while everything that must traverse squid fails. A build in this state passes
`verify/verify.sh --models` with 27/27 and still cannot reach Telegram or any
other allowlisted host. On the previous run this was diagnosed only after a
bot sat silent and the journal showed
`[telegram] transport attempt marked temporarily unhealthy (codes=EHOSTUNREACH)`.

Put these in the **same** drop-in as the EnvironmentFile lines:

```ini
Environment=http_proxy=http://127.0.0.1:3128
Environment=https_proxy=http://127.0.0.1:3128
Environment=HTTP_PROXY=http://127.0.0.1:3128
Environment=HTTPS_PROXY=http://127.0.0.1:3128
Environment=NO_PROXY=127.0.0.1,localhost,192.168.5.2,host.lima.internal,spark-ts
Environment=no_proxy=127.0.0.1,localhost,192.168.5.2,host.lima.internal,spark-ts
Environment=NODE_USE_ENV_PROXY=1
```

`NODE_USE_ENV_PROXY=1` is not optional: Node ignores the proxy variables
without it.

**Prove it** with a proxied destination, not the model endpoint — the model
endpoint cannot distinguish this failure. From inside the service's own
environment, something allowlisted and non-local must return a real HTTP
status.

Any agent you configure that runs under systemd needs this same treatment.

### 1. OpenClaw

- Installed from `https://openclaw.ai/install.sh`, downloaded and checksummed
  per rule 3. Pin a release if the installer offers one.
- Onboarded non-interactively with a token gateway and a daemon:
  `openclaw onboard --non-interactive --gateway-auth token --install-daemon`
- Gateway token comes from `OPENCLAW_GATEWAY_TOKEN` in `agents.env`, supplied
  as an env SecretRef. It must not appear in any OpenClaw config file.
- Running as a systemd **user** service, enabled. Lingering is already on, so
  it must survive logout and reboot.
- Model provider points at `VM_BASE_URL` (Anthropic shape), with
  `CREDENTIAL` supplied as the API key.
- **Exactly one agent, carrying the name in `OPENCLAW_AGENT_NAME`.**
  `openclaw onboard` creates an agent whose **id** is `main` and does not
  read your env. That id is immutable — `openclaw agents` offers
  `add`/`delete`/`set-identity`, no rename — so do not try to change it, and
  do not create a second agent to get the name you want.

  What you set is the **identity**:

  ```sh
  openclaw agents set-identity --agent <id> --name "$OPENCLAW_AGENT_NAME"
  ```

  Then **read it back** — `openclaw agents list` must print
  `Identity: <name>` before you call this done. A previous run logged
  "Creating OpenClaw agent 'LuoJi'", ran `openclaw agents list`, logged
  "agent created", and set nothing at all; see rule 6.

  Expect `- main (default) (LuoJi)` afterwards. The id stays `main`, and the
  state directory stays `~/.openclaw/agents/main/`. That is correct and not
  something to work around.
- Verified with `openclaw gateway status` and `openclaw doctor`.

### 2. Hermes

- Installed from `https://hermes-agent.nousresearch.com/install.sh`, same
  download-and-checksum treatment.
- Configured via `hermes setup`, which **does** have a non-interactive mode:
  `hermes setup --non-interactive`, and per-section forms like
  `hermes setup gateway`. In a VM with no TTY the non-interactive mode mostly
  prints the `hermes config set ...` commands to run instead — read what it
  says and use those. Never drive the interactive wizard with `expect` or
  simulated keystrokes; if a step genuinely has no scriptable path, say so
  and stop.
- Model provider: the same gateway, OpenAI-compatible path. Set its base URL
  to `VM_BASE_URL`, api key to the ANL username, and
  a model id the gateway lists. Verify with a real completion, not `doctor`:
  `hermes doctor` checks `api.anthropic.com`, which is irrelevant here and
  will report a 403 that means nothing.
- **Install the gateway service** when Telegram tokens are present:
  `hermes gateway install`. Installing the machinery is not the same as
  enabling a channel — rule 2 forbids turning a channel *on*, not building
  what serves it. (OpenClaw works the same way: its gateway runs while
  `channels.telegram.enabled` stays `false`.)

  An earlier version of this spec said "do not install it", reasoning that
  a disabled channel has nothing to serve. That was wrong and it was
  expensive: because the service never existed, the whole dependency chain
  below was never discovered, and Hermes shipped unable to reach Telegram
  at all while looking correctly configured.

  The service needs the same proxy drop-in as OpenClaw's — see *The gateway
  needs the proxy*.
- **The Telegram adapter needs three separate things, and missing any one
  produces the same silent symptom.** `hermes gateway status` will say the
  service is active while the journal says:

  ```
  WARNING gateway.run: No adapter available for telegram
  ```

  In order:

  1. **Enable the plugin.** `telegram-platform` ships *installed but
     disabled*; `hermes plugins list` shows `not enabled`. Run
     `hermes plugins enable telegram-platform`.
  2. **Let its Python dependency install.** On first start the adapter
     fetches `python-telegram-bot` from **pypi.org**, which is in the
     bootstrap allowlist and **not** the runtime one. So this must happen
     while you are running, during the bootstrap phase. If it is attempted
     later it fails with `tunnel error: unsuccessful` and
     `Failed to fetch: https://pypi.org/simple/...` — which reads like a
     network fault rather than a phase problem.
  3. **Credentials in `~/.hermes/.env`** (below).

- **Verify the adapter, not the service.** A running gateway proves nothing.
  Check the journal for the adapter actually connecting:

  ```sh
  journalctl --user -u hermes-gateway.service --no-pager | grep -i telegram
  # want: [Telegram] Connected to Telegram (polling mode)
  ```

  Quote that line. `Platform 'telegram' is registered but adapter creation
  failed` means step 1 or 2 did not happen.
- State in `~/.hermes`. Verified with a real completion, per the rule above.

### 3. Pi's own provider

Write `~/.pi/agent/models.json` with a custom provider whose `baseUrl` is
`VM_BASE_URL`, with `CREDENTIAL` as the apiKey. Credentials in
`~/.pi/agent/auth.json` are a secret;
mode 0600, never printed.

### 4. Model fallback — only if configured

If `VLLM_BASE_URL` is set in `agents.env`, configure each agent to fail over to
it. If it is unset, skip this entirely and say you skipped it.

**This path is unverified.** The failover config syntax for all three agents
was never confirmed, and the tailnet that reaches the endpoint was down when
this spec was written. So: check each agent's *current* documentation, write
what the docs actually say, and report in your summary which syntax you used
and where you found it. If the documentation is unclear, write nothing and say
it was unclear. A guessed failover config is worse than none — it fails silently
at the moment you need it.

When failing over to a smaller local model, agents must ask before destructive
actions. Put that in the provider config if it supports it, and in SOUL.md
regardless.

### 5. Agent personality seeds

These are seeds. Once written, the file belongs to the agent and its user,
and your setup script must never touch it again — re-running setup must not
revert a personality the user has since edited by talking to their agent.

- `~/.openclaw/agents/<agent-id>/SOUL.md` — the **live** agent id. Do not
  assume `default`: that directory can exist while the running agent uses
  another, and a seed written to the wrong one is simply never read.

  Derive it from `openclaw agents list`, but mind two traps in that output,
  both of which a previous run hit while looking correct:

  ```
    Agent dir: ~/.openclaw/agents/main/agent
  ```

  It has a trailing **`/agent`** — SOUL.md belongs one level *above* it, so
  `"$agent_dir/SOUL.md"` silently writes to the wrong place. And the `~` is
  literal text, which no shell expands when it arrives as data. Strip the
  suffix and expand the tilde, then confirm the file you wrote is the one
  the agent reads by listing the directory afterwards.
- `~/.hermes/SOUL.md`

**"Only if absent" is not a sufficient guard.** The Hermes installer writes
its own `SOUL.md` carrying the stock Nous Research persona, so a bare
`[ -f "$f" ] || write` skips and leaves the agent with a vendor default that
never mentions the name the user chose. A previous run did exactly that, and
reported the seed as written.

Guard on **content**, not existence: write the seed unless the file already
names the configured agent (`grep -q "You are <NAME>"`). That protects a
personality the user has edited — their file still names their agent — while
replacing a vendor default. State in your summary which of the two happened
for each agent.

Use this content, substituting the agent's name. Keep it this short.

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

### 6. Channels — configured, disabled

If Telegram tokens are present in `agents.env`, configure each agent's Telegram
channel but leave it **disabled**, restricted to `TELEGRAM_ALLOWED_USER_ID`.
If the tokens are absent, skip this and say so.

**This step is where the last run failed, so read rule 6 again before starting
it.** Pi wrote a function containing the comment "Telegram configuration
syntax needs to be determined from OpenClaw docs", made it a no-op, and then
reported "Telegram channels: configured but DISABLED". Nothing had been
configured: `openclaw.json` had no `channels` key and `~/.hermes` had no
`channel_directory.json`. The human reasonably believed the tokens were in
place and was puzzled that neither bot answered.

**The command is `openclaw channels` — plural.** The singular `openclaw
channel` does not exist, and that one character is what the last run got
stuck on. Verified working on OpenClaw 2026.10.5:

```sh
openclaw channels list --all                 # find channel ids and state
openclaw agents list                         # agent ids are LOWERCASE
openclaw channels add --channel telegram --token "$TOKEN" --agent "$AGENT_ID"
```

`--agent` wants the **agent id**, not the display name: an agent shown as
`luoji (default) (LuoJi)` is `--agent luoji`, and passing `LuoJi` fails with
`Unknown agent id`.

Three more things this path gets wrong if you do not check:

- **`channels add` writes the bot token as plaintext**, exactly like
  `onboard` does. Migrate it the same way, with a target of
  `channels.telegram.botToken` → env `OPENCLAW_TELEGRAM_BOT_TOKEN`, and
  re-run the audit afterwards.
- **`channels add` leaves the channel `enabled: true`.** The spec requires it
  disabled until a human says otherwise, so set
  `channels.telegram.enabled false` unless you have been told to enable it.
- **Restrict who may talk to it.** The defaults are `dmPolicy: "pairing"` and
  no `allowFrom`, which is not the same as "only the owner". Set
  `channels.telegram.dmPolicy allowlist` and
  `channels.telegram.allowFrom '["<TELEGRAM_ALLOWED_USER_ID>"]' --json`.
  Setting the policy before the list produces a warning that all DMs will be
  dropped; setting both in that order is correct and the warning resolves.

**For Hermes, credentials go in its dotenv file** at `~/.hermes/.env`, where
the Telegram keys ship commented out around the `# TELEGRAM INTEGRATION`
heading. (`hermes setup gateway --non-interactive` exists but, with no TTY,
prints guidance rather than configuring; the dotenv path is what works.)
Credentials alone are **not** sufficient — see the three-part adapter
requirement in section 2:

```
TELEGRAM_BOT_TOKEN=<from HERMES_TELEGRAM_BOT_TOKEN>
TELEGRAM_ALLOWED_USERS=<from TELEGRAM_ALLOWED_USER_ID>   # comma-separated
TELEGRAM_HOME_CHANNEL=<chat for cron delivery, optional>
```

Uncomment and fill those three, leave everything else in the file alone, and
keep the file mode 0600. **Do not configure it without
`TELEGRAM_ALLOWED_USERS`** — an unrestricted bot answers anyone who finds it.

Then install and start the gateway service per section 2 — plugin enabled,
dependency fetched during bootstrap, proxy drop-in applied — and confirm from
the journal that the adapter connected. The channel stays **disabled** for
the agent; what you are proving is that it *would* work the moment a human
enables it. Shipping an unverifiable channel is how the last build left a
bot that could never have answered.

**Validate every token, and quote the result. This is mandatory.**

`api.telegram.org` is allowed in **both** egress phases, bootstrap included,
specifically so you can test rather than configure blind. Do not assume it is
blocked — a previous run said so without sending a single request, and was
wrong. If a call does fail, quote the actual error (rule 5).

A bot token can be present and still be **invalid**. One call separates
"misconfigured" from "wrong credential", and a previous run shipped a token
that Telegram rejected with `Unauthorized`, which no amount of correct
configuration would have fixed:

```sh
curl -sS "https://api.telegram.org/bot$TOKEN/getMe"   # expect ok:true + username
```

Do this for **each** token you were given, and put the bot usernames (or the
rejection) in your summary — `@name_bot` is not a secret, the token is. If a
token is rejected, configure nothing for that agent and say so: only a human
can issue a new one from @BotFather.

Then:

- **Verify by reading back the state you claim to have created** -- the
  `channels` entry in `openclaw.json`, or `~/.hermes/channel_directory.json`
  -- and show that it exists and is disabled. The channel must not be live:
  `verify/verify.sh` asserts zero enabled channels and will fail the build.
- If you still cannot determine the syntax, write **nothing**, leave no
  placeholder function, and report it plainly as not done. That is a
  completely acceptable outcome. A false "configured" is not.

---

## What makes the script idempotent

Every step guards before it acts: check the desired state, do nothing if it
already holds, otherwise make the change and say what changed. Concretely —
`install -m` rather than `cp` then `chmod`; `systemctl enable --now` rather
than `start` plus a separate enable; append to a file only after `grep -q`;
create a config only after testing for it.

**Do not grep multi-line JSON with a single-line pattern.** This guard looks
right and never matches, because the file is pretty-printed:

```sh
# WRONG -- botToken and source are on different lines
grep -q '"botToken".*"source":"env"' openclaw.json
```

Query the structure instead:

```sh
jq -e '.channels.telegram.botToken.source == "env"' openclaw.json >/dev/null
```

A guard that never matches turns its step into an unconditional action, and
the whole script stops being idempotent while still *looking* guarded. On a
previous run three steps behaved this way — two with broken guards, one with
none — and the second run kept reporting changes, which sent Pi into nine
rounds of edit-and-retry before it gave up and shipped them.

**When the second run still changes something, find the guard — do not
re-run and hope.** If you cannot make a step idempotent, say which step and
why, per rule 6.

**You must prove it.** Run `setup.sh` twice:

1. First run: brings the machine to target state. Keep the output.
2. Second run: must exit 0 and report every step as already satisfied. It must
   restart no services, rewrite no configs, and reinstall nothing.

Then confirm the agents are still healthy after the second run. Include both
runs' output in your summary. If the second run changes anything, the script is
not finished — fix it and start this check again.

---

## Stop here

When the target state is reached, **stop**. Do not enable channels. Do not
start a conversation with either agent to try them out.

Write a summary covering:

- **What was installed**, with versions.
- **Verification output** — the actual text from `openclaw gateway status`,
  `openclaw doctor` and `hermes doctor`, not your paraphrase of it.
- **Idempotence** — the second run's output.
- **Installer checksums** and where the saved copies are.
- **What you skipped and why** — unset fallback, absent tokens, anything you
  could not verify.
- **What is configured but disabled** — the channels, and exactly what a human
  would do to enable one. If you configured nothing, say that instead; do not
  list a feature here that you did not actually write.
- **Secrets** — the `openclaw secrets audit --check` line showing
  `plaintext=0` and `unresolved=0`, quoted, from a clean login shell.
- **Channels** — the `getMe` result for every token you were given: the bot
  username, or the rejection. If you claim a domain was blocked, the command
  and its output.
- **Anything that surprised you**, including blocked domains, documentation
  that disagreed with this spec, and steps you were unsure about.

That last point matters more than it sounds. You are the only one who saw this
run happen.

**Before you write the summary, re-read it against rule 5 and rule 6.** For
every capability you are about to call done, point at the command output or
the file contents that prove it. If you cannot, change the wording to say what
actually happened. Two of the last run's claims — "Telegram configured" and
"no plaintext secrets" — were both false, and both would have been caught by
this one re-read.
