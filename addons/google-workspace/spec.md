# Add-on: Google Workspace for Hermes

You are Pi, in the sandboxed VM you already built. This is an **optional
add-on** to that build. You are wiring up a third-party MCP server that has
already been copied in; you are not writing one.

Your **deliverable is `~/agent-bootstrap/setup-google.sh`** — a new,
idempotent script. Put every change in it and run the script.

## Rules

1. **Do not touch `~/agent-bootstrap/setup.sh`.** It is the base build's
   deliverable and its idempotence is measured separately. Your work goes in
   a second script that stands alone.
2. **Hermes only.** OpenClaw gets nothing from this. Do not edit its config.
3. **Never print a credential.** Do not `cat`, `echo` or `grep` the
   contents of `~/.config/agent-sandbox/google.env` or the
   `google-credentials-*.json` beside it, and never put a value from either
   in your summary. Your whole session is logged on the host and read back
   by a supervisor; displaying one puts a refresh token in a transcript
   nobody can un-write. Check properties instead: `test -s`, `stat -c %a`,
   or a line count.
4. **Do not weaken the sandbox.** No egress change is needed: squid already
   allows the public web on 443, so `googleapis.com` and `pypi.org` are
   reachable as-is. If you believe otherwise, show the failing request
   first. Never run `agent-egress unlock`.
5. **Install the pinned version, exactly.** `requirements.txt` says
   `workspace-mcp==2.3.0`. The pin is the add-on's safety story — its tool
   surface was reviewed at that version. Do not upgrade it, and do not
   substitute a different server.
6. **Guard every step before acting**, so a second run changes nothing.

## What you have been given

| Path | What it is |
|---|---|
| `~/google-mcp-src/requirements.txt` | the pinned server to install |
| `~/.config/agent-sandbox/google.env` | client id, secret, refresh token, account email (0600) |
| `~/.config/agent-sandbox/google-creds/` | the server's credential store, already populated (0700) |

The credential store is already correct. Consent happened on the host,
because this VM has no browser. **Do not run any interactive auth flow**,
do not call `workspace-mcp` expecting it to open a consent page, and do not
try to re-authenticate if something fails.

## What to build

### 1. A venv of its own

Make the venv **at** `~/.local/share/agent-sandbox/google-mcp` — so the
interpreter is `~/.local/share/agent-sandbox/google-mcp/bin/python`, not
`.../google-mcp/venv/bin/python`. The directory is **agent-sandbox**, the
same one holding `.config/agent-sandbox`; `agent-bootstrap` is a
different thing and is where your own setup scripts live. Writing the
wrong one into the config is not a typo you will notice: Hermes parks the
server on a missing executable and never retries, so the gateway stays up,
every check still passes, and only the agent knows it has no tools. Then
`pip install -r ~/google-mcp-src/requirements.txt` into it. Do not install
into Hermes' own venv: the add-on must be removable without disturbing the
base build.

### 2. Register the server with Hermes

Hermes reads MCP servers from an `mcp_servers:` block in its config.
**Find the real config file and confirm its schema before editing** — run
`hermes config show` and follow what is actually there. If what you find
disagrees with this document, trust the software and say so.

The command is the venv's `workspace-mcp` binary, named absolutely, with
these arguments:

    --single-user --tools gmail drive calendar forms

`--single-user` makes it use the one credential in the store instead of
mapping per-session logins. `--tools` keeps the other eight services
unregistered.

It needs these in its environment — set them in the `mcp_servers` entry's
`env:` **by name where possible**, but note the two OAuth values must come
from the gateway's environment (step 3), not be written into the config:

    WORKSPACE_MCP_CREDENTIALS_DIR = /home/<user>/.config/agent-sandbox/google-creds
    USER_GOOGLE_EMAIL            = the address in GOOGLE_ACCOUNT_EMAIL
    GOOGLE_OAUTH_CLIENT_ID       } from google.env, via systemd
    GOOGLE_OAUTH_CLIENT_SECRET   }

### 3. Give the gateway the credentials

The Hermes gateway runs as a systemd **user** service and does not read
`~/.profile`. Add a **new** drop-in, `20-google.conf`, containing

    EnvironmentFile=%h/.config/agent-sandbox/google.env

Add a new file. Do not edit the drop-in the base build created; both
existing is correct.

That file already carries every name the server needs, including
`GOOGLE_OAUTH_CLIENT_ID`, `GOOGLE_OAUTH_CLIENT_SECRET`,
`USER_GOOGLE_EMAIL`, `WORKSPACE_MCP_CREDENTIALS_DIR` and the proxy
variables. One `EnvironmentFile=` line is the whole job.

**The MCP server does not inherit the gateway's environment**, and this
is the thing that will waste your time if you let it. The MCP stdio
client passes a child only `HOME, LOGNAME, PATH, SHELL, TERM, USER` plus
whatever the server's own `env:` block names — everything else, proxy
variables included, is dropped on purpose. So exporting `https_proxy` to
the gateway, or putting it in the systemd drop-in, does nothing for the
server.

Put the proxy in the `mcp_servers` `env:` block itself:

    http_proxy: http://127.0.0.1:3128
    https_proxy: http://127.0.0.1:3128

Without them the server's Google calls hit the uid lockdown and fail with
**"No route to host"** — DNS resolves, the connection is refused, and
squid's access log shows the request never arrived. That is not a Google
problem, a credential problem, or a transient: do not retry it in a loop,
and do not conclude the HTTP library ignores proxy environment variables.
It reads lowercase `https_proxy` and honours it; the variable was simply
never passed in.

**Do not try to rename a variable with `Environment=`.** systemd does no
variable expansion there — `systemd.exec(5)`: *"Variable expansion is not
performed inside the strings and the `$` character has no special
meaning"* — so `Environment=GOOGLE_OAUTH_CLIENT_ID=${GOOGLE_CLIENT_ID}`
hands the server that literal text and Google answers `invalid_client`.
It looks right in `systemctl show` and fails only on a real call. Nothing
needs bridging; if you think it does, re-read the file first.

### 4. Restart and prove it works

Before restarting, run the `command:` path from the config and confirm it
is executable — `test -x` on the exact string you wrote, not on the path
you meant. A wrong path parks the server permanently.

Restart the Hermes gateway, then prove each of these from evidence:

- **`hermes tools list` shows the Google tools.** This is the one that
  matters: it is what the agent can actually call. A server that runs
  fine when you start it by hand proves nothing, because Hermes parks a
  server that failed to start once and does not retry it. Grep the
  journal for `parked` and `permanent error` before believing anything
  else;

- the server process started and registered its tools — quote the journal
  line;
- Hermes lists the Google tools. `search_gmail_messages`,
  `search_drive_files` and `get_events` must be among them;
- **the restrictions hold**: there is no Drive delete or trash tool, and no
  Gmail permanent-delete tool, in what Hermes actually lists. These are the
  point of the add-on, so measure them rather than assuming;
- a live call succeeds: list the account's Gmail labels. **A running
  service proves nothing** — the credentials are only exercised on a real
  call, and a dead refresh token looks exactly like a live one until then.

## When something will not work: stop and hand it back

**Three failures of the same thing is the limit.** Not thirty. If a
command fails the same way three times, you have the information you are
going to get by running it again, and everything after that is cost
without evidence. Two runs of this spec spent 56 and 45 attempts on one
failing call; neither attempt number 4 nor number 45 told anyone anything
that attempt 3 had not.

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
is: both failures above were defects in these instructions, not in your
work. Handing back a clear impasse is a result. Grinding on is not.

**Do not invent a root cause to explain a failure you could not fix.**
One run concluded the HTTP library ignores proxy environment variables.
It does not, and the wrong explanation cost more than the failure. If you
do not know, say you do not know and give the evidence.

Two specific cases, so you do not spend the three attempts finding out:

- `invalid_grant` — the refresh token is dead. Host-side, about the
  Google consent screen, unfixable from in here. Report it immediately.
- `No route to host` / `Errno 113` — something is not using the proxy.
  Report which process, and stop.

## Idempotence

Run `setup-google.sh` twice. The second run must change nothing. Verify
that before you finish.

## When you are done

Say what you did, what you proved and how, and what you skipped. Quote the
journal line and the live call's result. Name anything you did differently
from this document and why — that is useful, not a failure.

Do not claim a tool works because it is listed. Listed is not called.
