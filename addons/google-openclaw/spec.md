# Add-on: Google access for the OpenClaw agent

You are Pi, in the sandboxed VM you already built. This is an **optional
add-on** to that build. OpenClaw ships no Google capability of its own, so
its vendor path is `gog` — a CLI from the OpenClaw project. Your job is to
install it, wire it to OpenClaw as an MCP server, and prove the agent can
reach Google.

**You are not writing Google API code.** `gog` is the client. If you find
yourself importing an OAuth library, stop — you have taken a wrong turn.

Your **deliverable is `~/agent-bootstrap/setup-openclaw-google.sh`** — a
new, idempotent script. Put every change in it and run the script.

## Rules

1. **Do not touch `~/agent-bootstrap/setup.sh`** or
   `~/agent-bootstrap/setup-google.sh`. The first is the base build's
   deliverable; the second belongs to the **Hermes** Google add-on and is
   a different agent's working setup. Yours is a third script.
2. **Do not touch anything under `~/.hermes/`.** The Hermes agent is in
   production with its own Google account. Its credentials, its skill
   config and its cron jobs are not yours to read, move or "tidy".
3. **Never run an interactive auth flow.** Consent already happened — the
   human completed it before you were started, and the tokens are in
   `gog`'s keyring. Do not run `gog auth add`, `auth login`, or anything
   that opens a browser. If the account looks unauthenticated, **say so
   and stop**.
4. **Never print a credential, a token, or the keyring password.** Your
   whole session is logged on the host. Never `cat`
   `~/.config/agent-sandbox/openclaw-google.env`, the keyring directory,
   or any file under it. Report properties instead: `test -s`,
   `stat -c %a`, a line count, an exit status.
5. **Do not weaken the sandbox.** Google is reachable because squid
   already allows the public web on 443. No allowlist change is needed. If
   you believe otherwise, show the failing request first. Never run
   `agent-egress unlock`.
6. **Guard every step before acting**, so a second run changes nothing.

## What you have been given

`~/.config/agent-sandbox/openclaw-google.env` (0600), holding
`GOOGLE_ACCOUNT`, `GOOGLE_SERVICES`, `GOOGLE_ALLOW_SEND`,
`GOOGLE_FORM_IDS` and `GOOGLE_KEYRING_PASSWORD`. Read values from it;
never echo them.

`gog` is already installed at `/usr/local/bin/gog` and already
authenticated — the host installer did both, because consent needs a
human with a browser.

## What to build

### 1. Confirm what you were handed, before building on it

Three checks, in this order. Each one failing means a different thing, so
report which:

```sh
gog --version
GOG_KEYRING_BACKEND=file gog --no-input --json auth doctor --check
```

For the second, **judge the JSON, never the exit code.** The vendor is
explicit: `auth doctor` *"exits successfully when it emits a diagnostic
report, even if that report has failed checks."* The documented gate is:

```sh
printf "%s\n" "$doctor_json" | jq -se 'length == 1 and .[0].status == "ok"'
```

`gog` needs `GOG_KEYRING_BACKEND=file`, `GOG_KEYRING_PASSWORD` and
`DBUS_SESSION_BUS_ADDRESS=disabled:` in its environment on a headless box.
Without them it looks for a desktop keyring, finds none, and reports no
auth — which reads like a credential problem and is not.

### 2. Put the keyring password where the services will see it

Write an `EnvironmentFile` at **0600** holding the three variables above,
and reference it from the units in step 3. Do not inline the password into
a unit file: that puts it in `systemctl show` output.

This is the add-on's weakest point and you should not try to improve it —
`gog` offers no password-file or password-command option, so an environment
variable is the only mechanism it accepts. Place it correctly and move on.

**The variables must reach the process that actually runs `gog`.** The
vendor's warning is worth quoting because it describes a real trap: *"A
command working in your login shell only proves that shell has the
password; it does not prove a systemd service, gateway, or agent
subprocess inherited it."*

### 3. Register `gog mcp` with OpenClaw

Use the **MCP server**, not shell exec. It exposes typed tools, is
read-only by default, and avoids OpenClaw's approval system refusing
pipelines and command substitutions outright.

Register it in OpenClaw's `mcp.servers` config, running
`gog --account <GOOGLE_ACCOUNT> mcp` with:

- an explicit `--allow-tool` list covering the services in
  `GOOGLE_SERVICES`;
- `--allow-write` **only** for docs and sheets, which the agent must write;
- `--allow-gmail-send` **only if** `GOOGLE_ALLOW_SEND` is `yes`. If it is
  `no`, the agent must be able to create drafts but not send. Default to
  not granting it;
- never `--allow-gmail-delete`.

`gog mcp --list-tools` enumerates and exits — use it to confirm your
`--allow-tool` names are real before wiring anything.

**Then prove it is reachable, not merely configured:**

```sh
openclaw mcp doctor <name> --probe
```

The vendor's words: *"Saving a definition proves nothing about
reachability — the check does."*

### 4. Make sure the agent can actually use it

Enabling is not the same as reaching. Check all three gates:

- the MCP server is enabled (`mcp.servers.<name>.enabled`);
- any tool filter you set does not exclude what you just allowed;
- the agent's own tool/skill visibility includes it. **Careful here:**
  OpenClaw's docs warn that an explicit per-agent list *"replaces inherited
  defaults — they do not merge"*, so setting one can silently drop every
  other capability the agent had. If you touch that list, read it first and
  add to it.

This gate has bitten this repo before on the Hermes side: a skill was
enabled but not auto-loaded, so the agent never found it and reached for an
unrelated tool instead. Nothing failed; it just quietly did the wrong thing.

### 5. Confirm the scheduler is alive

OpenClaw's scheduler ("automations") is how this agent will do recurring
work later. You are not creating jobs — just confirm the scheduler runs:

```sh
openclaw automations status
```

Set **`cron.skipMissedJobs: true`**. The default is `false`, which means
that after any VM suspend or gateway restart, overdue recurring slots are
caught up on startup. That is the same failure the Hermes side hit, where
every missed schedule fired at once and delivered a burst of stale messages.

### 6. Restart once, at the end

Not after each step. Make your config edits, then restart the OpenClaw
gateway once.

### 7. Prove it

Report the actual output of each:

- `gog --version`;
- the `auth doctor` JSON predicate, passing;
- `openclaw mcp doctor <name> --probe`;
- the EnvironmentFile exists at 0600 (mode only, never contents);
- `openclaw automations status`;
- `openclaw doctor --lint --all --json` — **and `hermes doctor` too.**
  You touched OpenClaw, but both gateways share a machine and this repo
  requires the vendor's doctor for every gateway after an add-on. Judge
  both on parsed output, never exit code: `hermes doctor` exits 1 whenever
  an optional integration is absent, and `openclaw doctor` exits 0 even
  when `ok:false`.

Do **not** send email, create calendar events, or modify any Google
document to test. A read is enough. The human will exercise it.

## When something will not work: stop and hand it back

**Three failures of the same thing is the limit.** Not thirty. If a command
fails the same way three times, you have the information you are going to
get by running it again. Two earlier runs of another add-on's spec spent 56
and 45 attempts on one failing call; both root causes were defects in the
*spec*, which no amount of retrying could reach.

When you hit that limit, **stop and write up what you know**:

- what you ran and the exact error;
- the narrowest thing you proved works, and the narrowest that does not;
- what you ruled out, and the evidence;
- what you would try next if you had another layer to look at.

A supervising coding agent can read the host, the repo and the vendor's
documentation — none of which you can reach. Handing back a clear impasse
is a result. Grinding on is not.

**Do not invent a root cause for a failure you could not fix.** A wrong
explanation reads like a finding and gets believed.

Four cases, so you do not spend three attempts discovering them:

- **`gog` reports no auth** — almost always the keyring environment, not
  the credentials. Check `GOG_KEYRING_BACKEND=file` and that
  `GOG_KEYRING_PASSWORD` reached *that* process.
- **`invalid_grant`** — the refresh token is dead, usually an OAuth consent
  screen left in "Testing", which expires tokens after 7 days. Host-side
  and unfixable from in here. Report it.
- **A tool name rejected by `--allow-tool`** — run `gog mcp --list-tools`
  and use the names it prints. Do not guess adjacent spellings.
- **`openclaw mcp doctor --probe` fails while the config looks right** —
  the server is defined but not reachable. Usually the keyring environment
  again, because the MCP server re-opens the keyring in a subprocess per
  call rather than unlocking once at startup.

## Idempotence

Run `setup-openclaw-google.sh` twice. The second run must change nothing,
restart no service and reinstall nothing. Verify that before you finish.

## When you are done

Say what you did, what you proved and how, and what you skipped. Quote the
command output behind each claim. Name anything you did differently from
this document and why — that is useful, not a failure. If this spec was
wrong, say so plainly; it has been before.

Do not claim Google works because the MCP server is registered. Registered
is not reachable, and reachable is not authorised.
