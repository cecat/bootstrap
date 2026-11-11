# Add-on: Google Workspace for Hermes

You are Pi, in the sandboxed VM you already built. This is an **optional
add-on** to that build. Hermes ships a bundled `google-workspace` skill;
your job is to give it its credentials and the two settings it needs to
work inside this sandbox. **You are not installing a Google client, an MCP
server, or a venv.**

Your **deliverable is `~/agent-bootstrap/setup-google.sh`** — a new,
idempotent script. Put every change in it and run the script.

## Rules

1. **Do not touch `~/agent-bootstrap/setup.sh`.** It is the base build's
   deliverable and its idempotence is measured separately. Your work goes in
   a second script that stands alone.
2. **Hermes only.** OpenClaw gets nothing from this. Do not edit its config.
3. **Never print a credential.** Do not `cat`, `echo` or `grep` the
   contents of `~/.hermes/google_token.json`,
   `~/.hermes/google_client_secret.json` or
   `~/.config/agent-sandbox/google.env`, and never put a value from any of
   them in your summary. Your whole session is logged on the host and read
   back by a supervisor; displaying one puts a refresh token in a transcript
   nobody can un-write. Check properties instead: `test -s`, `stat -c %a`,
   or a line count.
4. **Do not weaken the sandbox.** No egress change is needed: squid already
   allows the public web on 443, so `googleapis.com` and `pypi.org` are
   reachable as-is. If you believe otherwise, show the failing request
   first. Never run `agent-egress unlock`.
5. **Do not run any interactive auth flow.** Consent already happened on the
   host, because this VM has no browser. Do not run the skill's
   `setup.py --auth-url` or `--auth-code`, and do not try to re-authenticate
   if something fails. The only `setup.py` commands you may run are
   `--check` and `--check-live`, which are read-only.
6. **Do not edit the bundled skill, except for the one patch in step 6.**
   Changing any file under
   `~/.hermes/skills/productivity/google-workspace/` marks it
   `user_modified` and stops it tracking upstream. Everything else you
   need is configuration outside it. If you find yourself wanting a
   second edit, stop and say so instead — one tracked exception is a
   known cost, two is a fork.
7. **Guard every step before acting**, so a second run changes nothing.

## What you have been given

| Path | What it is |
|---|---|
| `~/google-skill-push/google_token.json` | the OAuth token, already consented (0600) |
| `~/google-skill-push/google_client_secret.json` | the OAuth client, as Google issued it (0600) |

Both are staged in that directory by the host installer. Your job is to put
them where the skill looks and then prove the skill can use them.

## What to build

### 1. Put the two credential files in `$HERMES_HOME`

The skill resolves its home as `$HERMES_HOME` if set, else `~/.hermes`.
The base build uses the default profile, so this is `~/.hermes` — but
**confirm it rather than assuming**, and confirm it for the *gateway*, not
just your shell. A systemd user service does not read `~/.profile`, and a
gateway resolving a different home than your shell is a documented way for
"it works when I check it" to coexist with a broken agent.

Install both files there at **0600**, owned by the agent user:

    ~/.hermes/google_token.json
    ~/.hermes/google_client_secret.json

Use exactly those names. They are what the skill's SKILL.md declares under
`required_credential_files`, and Hermes checks for them **by name**.

`google_client_secret.json` looks redundant and is not. Nothing reads it at
runtime — the skill's `google_api.py` assigns its path and never opens it,
because refreshing uses the client id and secret inside the token file. But
Hermes' **cron preflight refuses to start any job whose attached skill has a
declared credential file missing**, reports `blocked_config`, and alerts
once. A missing file here is exactly what broke the first scheduled digest.
Place it.

### 2. Install PySocks into the Hermes environment

This is a deliberate exception to the usual "do not install into Hermes'
own venv" rule: the skill runs *inside* Hermes, so there is no separate
environment to use. Find the interpreter the Hermes gateway actually runs
and install `PySocks` into it.

Without it every Google API call silently bypasses squid. The skill uses
`google-api-python-client`, which builds a bare `httplib2.Http`. httplib2
does `try: import socks / except ImportError: socks = None`, and its
`isgood()` returns false when `socks` is None — at which point the HTTPS
path **opens a direct socket with no warning**. Under this VM's uid-scoped
iptables that connection is refused or hangs. There is no proxy error
message, because httplib2 never believed it had a proxy.

PySocks is not a declared Hermes dependency, so nothing else will install
it. Verify with an `import socks` from the gateway's interpreter, not from
`python3` on `$PATH`.

### 3. Let the skill's subprocesses see the proxy

Hermes strips most environment variables from the children of its
`terminal` and `execute_code` tools, and `http_proxy` / `https_proxy` are
among those stripped — they match none of the safe prefixes. The skill's
scripts run as exactly such a child, so without this they get no proxy at
all.

Add the proxy variables to `terminal.env_passthrough` in Hermes' config:

    terminal:
      env_passthrough:
        - http_proxy
        - https_proxy
        - HTTP_PROXY
        - HTTPS_PROXY
        - no_proxy
        - NO_PROXY

Read the real config with `hermes config show` and follow the schema that
is actually there; if what you find disagrees with this document, trust the
software and say so. Merge with any existing list rather than replacing it.

**Restart the gateway afterwards.** This value is cached per home, so an
edit without a restart looks applied and changes nothing.

**Restart it once, at the end — not after each step.** Telegram keeps a
`getUpdates` session open for a while after a poller disconnects, so two
restarts close together leave the new adapter logging `Conflict:
terminated by other getUpdates request` and retrying. It recovers by
itself and no message was lost when this happened on 2026-11-09, but the
bot is unreachable while it lasts and the conflict makes the adapter
check in `verify.sh` skip, which is noise in the one place a real
Telegram fault would show. Make your config edits, then restart once
before step 6.

### 4. Confirm the skill is present and enabled

Run `hermes skills list` and confirm `google-workspace` is there. It is
bundled, so it should be seeded already — if it is missing, say so and stop
rather than installing something.

Check it is not disabled: `skills.disabled` and `skills.platform_disabled`
in the config must not name it.

**Then add it to `skills.auto_load`**, which is a separate thing from
being enabled and is the one that decides whether the agent actually has
it:

    skills:
      auto_load:
        - google-workspace

Merge with any existing list rather than replacing it. Without this the
skill is merely *available* — the agent has to go looking for it, and an
agent asked for a calendar will reach for the first calendar-shaped tool
it finds. On 2026-11-08 that was a `connectors__wispr_flow_mcp`
calendar tool from an unrelated catalogue; the session spent a minute
failing against it and never made a single request to Google. The vendor
docs are explicit: auto-load means Hermes "loads each named skill into the
session prompt before the first turn".

The list is resolved when a session's system prompt is first built, so
**the change only affects new sessions** — an open Telegram conversation
keeps the old prompt until the user starts a fresh one.

**Do not set `platform_toolsets`.** The defaults for both the `telegram`
and `cron` platforms already include the `skills` and `terminal` toolsets
this needs. Setting that block by hand is how the previous build silently
lost its tools on every platform it forgot to name, and a malformed block
fails cron runs outright. If you believe a toolset really is missing, show
`hermes chat --list-toolsets` output first.

### 5. Patch the contacts projection — the one allowed edit

`scripts/google_api.py` asks Google for `phoneNumbers` and
`emailAddresses`, which come back carrying a `type` (`mobile`, `work`,
`home`) and a `formattedType`. It then keeps only `value` and discards
the rest, in both the `gws` branch and the Python one:

    "emails": [e.get("value", "") for e in emails],
    "phones": [p.get("value", "") for p in phones],

So the agent sees a bare list of numbers and cannot say which is the
mobile. Measured on 2026-11-09: Google returned a non-empty `type` on
29 of 29 phones and 13 of 15 emails for a real account. The data is
fetched and thrown away — an upstream oversight, not a Google limit and
not a design decision.

Change both occurrences to keep the label:

    "emails": [{"value": e.get("value", ""), "type": e.get("type", "")} for e in emails],
    "phones": [{"value": p.get("value", ""), "type": p.get("type", "")} for p in phones],

Requirements:

- **both branches**, not just the one that runs here. `gws` is not
  installed, so only the Python path executes — but a half-patched file
  is a trap for whoever installs `gws` later;
- **`.get("type", "")`**, so a contact with no label yields an empty
  string rather than raising. Two of the fifteen emails had none;
- **idempotent**: a second run must not patch an already-patched file.
  Check before editing;
- **nothing else in that file changes.** This is the single tracked
  exception to rule 6.

Then prove it: run the skill's `contacts list` and confirm the output
has `type` alongside `value`. **Do not print a real contact** — report
the shape, a count, or one entry with the values blanked.

### 6. Restart and prove it works

- **`setup.py --check-live` succeeds.** This is the one that matters.

  Plain `python3` will not do: the script imports `pm`, which resolves
  only inside Hermes' own environment, and anything else answers *"Run
  this script in the Hermes environment"*. Use the gateway's interpreter
  with Hermes' import paths — the installed venv's `site-packages` plus
  the `hermes-agent` tree on `PYTHONPATH`. Several environments sit side
  by side, so pick the one that actually contains `googleapiclient`
  rather than the first you find. Work out the exact invocation and
  report it.

  `--check-live` makes a real Calendar API call. **`--check` is not
  sufficient**: it only refreshes the token, and refreshing goes through
  `requests`, which honours proxy variables natively. So `--check` can pass
  while every actual API call fails on the httplib2 path from step 2. If
  you see `--check` pass and `--check-live` fail, the cause is step 2 or
  step 3 — not the credentials;
- the output says `AUTHENTICATED`, and **not** `AUTHENTICATED (partial)`.
  Partial means the token is missing scopes the skill wants, which is a
  host-side consent problem — report it, do not try to fix it here;
- both credential files exist at 0600 in the home the **gateway** resolves;
- `hermes cron doctor` reports no findings about a blocked job.

## When something will not work: stop and hand it back

**Three failures of the same thing is the limit.** Not thirty. If a
command fails the same way three times, you have the information you are
going to get by running it again, and everything after that is cost
without evidence. Two runs of the previous version of this spec spent 56
and 45 attempts on one failing call; neither attempt number 4 nor number 45
told anyone anything that attempt 3 had not.

When you hit that limit, **stop and write up what you know**, in your
summary rather than in more commands:

- what you ran and the exact error;
- the narrowest thing you proved works, and the narrowest that does not
  (e.g. *"curl through the proxy reaches the host; the library call from
  the same shell does not"*);
- what you ruled out, and the evidence that ruled it out;
- what you would try next if you had another layer to look at.

A supervising coding agent reads that and can check things you cannot
reach from in here — the host, the repo, the upstream source, this spec
itself. It can also change the spec, which is usually where the real bug
is. Handing back a clear impasse is a result. Grinding on is not.

**Do not invent a root cause to explain a failure you could not fix.**
One earlier run concluded the HTTP library ignores proxy environment
variables. It does not, and the wrong explanation cost more than the
failure. If you do not know, say you do not know and give the evidence.

Three specific cases, so you do not spend the three attempts finding out:

- `invalid_grant` — the refresh token is dead. Host-side, about the
  Google consent screen, unfixable from in here. Report it immediately.
- `AUTHENTICATED (partial)` — the token lacks scopes the skill wants. Also
  host-side consent. Report which scopes and stop.
- `No route to host` / `Errno 113` / a call that hangs — something is not
  using the proxy. Check step 2 and step 3 in that order, then report which
  process and stop.

## Idempotence

Run `setup-google.sh` twice. The second run must change nothing. Verify
that before you finish.

## When you are done

Say what you did, what you proved and how, and what you skipped. Quote the
`--check-live` result. Name anything you did differently from this document
and why — that is useful, not a failure.

Do not claim the skill works because it is listed. Listed is not called.
