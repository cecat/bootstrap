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

5. **Never report success you have not verified.** "Installed" means a doctor
   or status command exited zero and you are quoting its output.

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
- Running as a systemd user service, enabled, surviving reboot.
- State in `~/.hermes`. Verified with `hermes doctor`.

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
  would do to enable one.
- **Anything that surprised you**, including blocked domains, documentation
  that disagreed with this spec, and steps you were unsure about.

That last point matters more than it sounds. You are the only one who saw this
run happen.
