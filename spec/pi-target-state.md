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

5. **Never report success you have not verified.** "Installed" means a doctor
   or status command exited zero and you are quoting its output.

6. **Never leave a placeholder and describe it as done.** If you cannot
   determine how to configure something, the only acceptable outcomes are to
   find the answer in current documentation or to **stop and report it as
   unresolved**. Writing a comment such as "exact syntax needs to be
   determined" into a script, letting that branch no-op, and then listing the
   feature as configured in your summary is a false report — a previous run
   did exactly this with Telegram, and the human believed channels were set up
   when nothing had been written at all. An honest "I could not do this, and
   here is what I tried" is always the better answer.

---

## Preconditions

Check these first and stop if any fails — they are someone else's job, not
yours to fix:

| Check | Expected |
|---|---|
| `sudo agent-egress status` | phase `bootstrap`, lockdown `active` |
| `curl -s --proxy http://127.0.0.1:3128 "$UPSTREAM_BASE_URL/v1/models"` | HTTP 200 |
| `ls ~/.config/agent-sandbox/agents.env` | exists, mode 0600 |

### Model access

**There is no model gateway in this VM.** The host already has a working path
to models; your job is to point the agents at it, not to install anything new.

Read `~/.config/agent-sandbox/model-access.env` (mode 0600). It gives you:

| Variable | Meaning |
|---|---|
| `UPSTREAM_BASE_URL` | the endpoint, e.g. `https://apps.inside.anl.gov/argoapi` |
| `CREDENTIAL` | the API credential. For Argo this is an ANL username, not a key. |
| `MODEL_OPUS` / `MODEL_SONNET` / `MODEL_HAIKU` | model names |

The endpoint speaks the **Anthropic** shape (`/v1/messages`). It is reached
through the egress proxy at `127.0.0.1:3128`, which is already in your
environment — do not override it.

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
- Model provider points at `UPSTREAM_BASE_URL` (Anthropic shape), with
  `CREDENTIAL` supplied as the API key.
- Exactly one agent. Its name comes from `OPENCLAW_AGENT_NAME`.
- Verified with `openclaw gateway status` and `openclaw doctor`.

### 2. Hermes

- Installed from `https://hermes-agent.nousresearch.com/install.sh`, same
  download-and-checksum treatment.
- Configured via `hermes setup`. If that is interactive and you cannot find a
  non-interactive path, **say so and stop** — do not drive it with `expect` or
  simulated keystrokes.
- Model provider: the same gateway, OpenAI-compatible path. Set its base URL
  to `UPSTREAM_BASE_URL` (or `VM_BASE_URL`), api key to the ANL username, and
  a model id the gateway lists. Verify with a real completion, not `doctor`:
  `hermes doctor` checks `api.anthropic.com`, which is irrelevant here and
  will report a 403 that means nothing.
- **No systemd service, and this is correct.** Unlike OpenClaw, Hermes answers
  one-shot calls (`hermes -z '...'`) without any daemon. It *does* have a
  gateway (`hermes gateway install`), but that gateway exists only to serve
  **messaging channels** -- and channels stay disabled per rule 2, so there is
  nothing for it to serve. Do not install it, and do not describe Hermes as
  "CLI-only, it has no daemon": it has one, it is simply not wanted yet.
  Install it only when a channel is actually turned on, which is a later,
  human-made decision.
- State in `~/.hermes`. Verified with a real completion, per the rule above.

### 3. Pi's own provider

Write `~/.pi/agent/models.json` with a custom provider whose `baseUrl` is
`UPSTREAM_BASE_URL`, with `CREDENTIAL` as the apiKey. Credentials in
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

Write each file **only if it does not already exist**. These are seeds. After
the first write the file belongs to the agent and its user, and your setup
script must never touch it again — re-running setup must not revert a
personality the user has since edited by talking to their agent.

- `~/.openclaw/agents/default/SOUL.md`
- `~/.hermes/SOUL.md`

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

**For Hermes, there is no non-interactive `gateway setup`** — the command
takes no flags at all, so rule 2's "do not drive it with simulated
keystrokes" leaves it unusable. The supported alternative is its dotenv file
at `~/.hermes/.env`, where the Telegram keys ship commented out around the
`# TELEGRAM INTEGRATION` heading:

```
TELEGRAM_BOT_TOKEN=<from HERMES_TELEGRAM_BOT_TOKEN>
TELEGRAM_ALLOWED_USERS=<from TELEGRAM_ALLOWED_USER_ID>   # comma-separated
TELEGRAM_HOME_CHANNEL=<chat for cron delivery, optional>
```

Uncomment and fill those three, leave everything else in the file alone, and
keep the file mode 0600. **Do not configure it without
`TELEGRAM_ALLOWED_USERS`** — an unrestricted bot answers anyone who finds it.

Hermes' gateway service is what *serves* channels, so configuring one is the
point at which `hermes gateway install` becomes appropriate — see section 2.
That service needs the same proxy environment as OpenClaw's; see *The gateway
needs the proxy*.

**Two things that will stop you, and are not yours to fix:**

- `api.telegram.org` is **not** in the runtime allowlist by default; it ships
  commented out. Any Telegram call from inside the VM will fail with
  `403 CONNECT tunnel failed` until a human uncomments it. That is rule 1
  territory: report the blocked domain, do not edit the allowlist yourself.
- A bot token can be present and still be **invalid**. Check each one before
  using it and report the result -- this costs one call and immediately
  distinguishes "misconfigured" from "wrong credential":

  ```sh
  curl -sS "https://api.telegram.org/bot$TOKEN/getMe"   # ok:true + username
  ```

  On the last run one of the two supplied tokens returned
  `Unauthorized`, so that agent could never have answered no matter how
  correctly it was configured.

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
  `plaintext=0`, quoted.
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
