# Gotchas

**Audience: the coding agent supervising a build.** Not Pi. Pi reads
`spec/pi-target-state.md`, which describes the target state and nothing
else — every line added there makes Pi's context bigger and its job harder.
Things that went wrong once live here instead.

**Deletion rule.** Every entry is dated. **If a gotcha survives two clean
builds without mattering, delete it.** This file is allowed to shrink and is
expected to. The old repo had no deletion criterion, so nothing was ever
removed and the spec grew to 749 lines of accumulated apology. Do not
restart that ratchet.

Before adding an entry, ask: *is this a transient a supervisor should just
absorb?* Retry it, push back on Pi, work around it live. Only a repeatable
misunderstanding of the target earns a line here, and only a misunderstanding
of **what to build** belongs in the spec.

---

## Supervising Pi

**Pi over-claims. Read `verify.sh`, not the summary.** (2026-10-29) It
reported "✅ Setup Complete and Verified" with checkmarks and zero quoted
command output, over a build that was genuinely good but had one broken
agent. The summary is a claim; `verify.sh` is evidence.

Read `pi-session.sh steps` alongside the summary — it lists every tool
call Pi made, which is the difference between what it claims and what it
did. (Before 2026-10-31 this was impossible: plain `pi -p` printed only
the final answer. `--mode json` fixed that.)

**`check-telegram-polling.sh` reports idle for bots that are live.**
(2026-10-31) It takes the poll from whoever holds it, so it manufactures
the state it then reports — its own header says so. Two consecutive runs
called both bots dead while both were answering on Telegram, and that
nearly reverted a correct fix. Treat a 409 as proof of life; treat an
`idle` as no information at all. Ask the user to message the bot instead.

**Pi quietly weakens things that block it.** (2026-10-31) Asked to add one
environment variable, it also relaxed a precondition guard in `setup.sh`
so the script would run in the phase it happened to be in — mentioned in
its summary as a bullet, never flagged as a question. Harmless there, but
"route around the obstacle" is the pattern worth watching for, and it will
not always be harmless. Check whether a fix touched anything beyond what
was asked.

**Repeating something in the spec does not make Pi do it.** (2026-10-31)
The spec says `NODE_USE_ENV_PROXY=1` "is not optional: Node ignores the
proxy variables without it", and a clean rebuild shipped without it
anyway. Prose had already failed; the thing that fixed it was `verify.sh`
naming the missing variable so the next supervisor could act in one short
prompt. When a defect recurs, add the check, not another paragraph.

**But verify Pi before assuming it is wrong.** (2026-10-26) Three times in
one session a `verify.sh` check was wrong and Pi was right. Twice more on
2026-10-29: Pi's "OpenClaw uses a `models` array, not `defaultModel`" was
correct, and the spec's `$ARGO_CREDENTIAL` turned out to resolve fine.

**A failed Pi turn that produced one API error is not a failed build.**
(2026-10-29) `pi -p` sometimes dies before the first token. Nothing in the
VM changed. Re-run it. Three such failures in a row cost an hour of
theorising about slirp, squid and credential resolution; the fourth attempt
worked unchanged.

## The model path

**A rejected credential kills a stream mid-flight rather than returning
401.** (2026-10-29) Reproduced: an invalid ANL username gives `HTTP 200`
followed by `transfer closed with outstanding read data remaining`. An
*empty* key behaves differently — argo-proxy falls back to its own user and
returns a clean 200. So "stream ended before completion", `ArgoAuthWarning`
and `[Errno 104] Connection reset by peer` are all plausibly **auth**
symptoms, not network ones.

**Test the agents' actual path, not a convenient approximation.**
(2026-10-29) Every green check we had sent either no credential or a
hand-supplied one, and every one passed `--noproxy '*'`. The agents do
neither. An hour went into theories that a two-minute matched test killed.
`scripts/diag-stream.sh` exists for this: it varies stream length, the proxy
setting, the model id, request size and credential validity.

**Ruled out on this host, do not re-litigate** (2026-10-29): QEMU slirp on
long streams (3000 tokens, 6.5s, clean), squid (not in the model path at
all — the gateway is a direct uid-scoped ACCEPT), the egress phase (that
iptables rule is byte-identical in both phases), request size (90 KB fine),
and the model id form.

**`/health` and `/v1/models` are false greens.** They answer 200 from local
state with a dead upstream. Only a completion proves the path.

**`VM_BASE_URL`, never `UPSTREAM_BASE_URL`.** The latter is the host's
address, often `127.0.0.1:<port>`, which from inside the VM is nothing.

**A systemd user service does not read `~/.profile`.** Without a proxy
drop-in the gateway reaches the model fine (direct, uid-allowed) and fails
every allowlisted destination with `EHOSTUNREACH` — passing `--models`
30/30 while unable to reach a single chat channel.

**Each agent reads its own credential variable.** (2026-10-29) `CREDENTIAL`
and `ARGO_CREDENTIAL` both resolve; Hermes with a custom provider wanted
`OPENROUTER_API_KEY`, which was empty — the one real defect in an otherwise
clean build. If one agent fails while others pass, check its variable before
anything else.

## Host and VM

**Editing `lima/agents.yaml` does not change an existing VM.** Lima copies
the config in at creation and re-reads *that* copy on boot. Use `--rebuild`;
cheap before Pi has built, destructive after.

**On the DGX Spark:** use the `kvm` group, not `setfacl` — a `setfacl` grant
on `/dev/kvm` does not survive the udev event that installing qemu triggers
(`sg kvm -c '...'` for an already-running shell). NextDNS blocks the NVIDIA
apt repos, which looks alarming during `apt-get update` and is irrelevant.

**The host must be on the network its model endpoint needs.** The VM
inherits host NAT.

## Guessing instead of reading

**Fetch the vendor's documentation before the first guess.** (2026-11-06)
Four consecutive attempts to name an MCP server in Hermes'
`platform_toolsets` failed — `google-workspace`, an expanded toolset list,
then `mcp`. The answer was one sentence in the vendor docs: *"Each
configured MCP server generates a `mcp-<server>` toolset at runtime."* It
took two minutes to find once anyone looked, and cost four Pi turns not to.

What made it worse: I checked one documentation page, got "not documented
here", and treated that as "undocumented". The index listed a dedicated
Tools & Toolsets page, and the site ships `llms-full.txt` — the whole
corpus in one ~6 MB file, built to be grepped. Check for one before
concluding the docs are thin.

The software documents itself too, and that is nearer to hand than the
web: `--help`, `--list-toolsets`, `config get`, and the comments inside
`~/.hermes/config.yaml` all carried pieces of this answer while it was
being guessed at.

**A failure with no error message means go and read.** Hermes accepted
every wrong toolset name silently, because an unmatched name is ignored
rather than rejected. Silence like that is almost always a documented
behaviour, not a bug — and no amount of trying adjacent spellings will
surface it.

(The `mcp-<server>` detail above is now historical — the Google add-on
moved off MCP on 2026-11-08 and sets no `platform_toolsets` at all. The
lesson about reading first is why the entry stays.)

## Settings nobody chose

**Run the vendor's own doctor before declaring anything built.**
(2026-11-09) `hermes doctor` ships with the product. It checks config
version, deprecated keys, credentials, SQLite health and per-tool
readiness, and prints a findings list. It was never run once across three
days of building this, while four configuration gaps shipped past a
41-check suite. One command.

**The gaps all had the same shape**, and it is worth naming because the
suite will not catch the next one either: *we verified that things worked,
never that they were configured deliberately*. Compression, timezone and
skill auto-load were all sitting at a default nobody had read, and every
one of them surfaced as bad agent behaviour — a wrong-day calendar entry,
chat spam every few hours, the agent reaching for an unrelated tool —
while every automated check stayed green. A completion succeeding proves
the plumbing works. It says nothing about whether the settings around it
were chosen.

The standard to hold: **every setting is either deliberately set, or its
default has been read and deemed reasonable.** A default someone examined
and accepted is fine. A default nobody looked at is the bug.

**A stale clock is not the model being careless.** Hermes builds the
system prompt — including its `Current time:` line — once per session and
reuses it for the whole conversation. A session open since yesterday
reports yesterday's time, so "2pm today" resolves to yesterday and the
agent's "that's 2.5h away" is correct arithmetic on a wrong `now`. On
2026-11-09 this produced a calendar event on the wrong day and read, from
the outside, exactly like an agent ignoring its instructions. Setting
`timezone` does not fix it; only a new session does.

## Building beside the vendor instead of on it

**Check whether the tool already ships the thing you are about to build.**
(2026-11-08) The Google add-on installed a pinned third-party MCP server
for five months. Hermes ships a bundled `google-workspace` skill that does
substantially the same job, and the original decision never compared the
two — it weighed the MCP server against writing our own Google API
plumbing, and the skill appears nowhere in that commit.

What surfaced it: **the agent reached for the vendor's path by name.** A
cron job attached the bundled skill, found no credentials where that skill
looks, and was refused. An agent picking the standard mechanism unprompted
is the clearest signal available that the bespoke one is the detour.

The cost was not just maintenance. Every platform's toolsets had to be
named by hand, every credential lived in a second format, and the whole
apparatus was invisible to the agent that was supposed to use it.

**We put OpenClaw's `SOUL.md` somewhere OpenClaw does not look, then
blamed the agent for going to the right place.** (2026-11-11) The spec
said to write `~/.openclaw/agents/<id>/SOUL.md`. That directory is state —
`agent/openclaw-agent.sqlite`, `sessions/`, `recovery/` — and nothing in
it is ever loaded as identity. OpenClaw keeps the whole bootstrap set
(`SOUL.md`, `AGENTS.md`, `IDENTITY.md`, `USER.md`, `MEMORY.md`) in the
agent's **workspace**, a git repo it initialises itself:
*"Save this file at the workspace root as `SOUL.md`"*, *"These live in the
agent workspace, not `~/.openclaw`."*

Asked to edit its soul, the agent went to the workspace, found the
vendor's template there, and edited it. **That was correct.** The
supervising agent then called the real file a decoy, told the user the
update had failed, and had the agent delete it — destroying the one file
that was in the right place. Four other context files were never affected,
because we only ever had an opinion about this one.

Three lessons, in order of how much they cost:

- **An invented path is worse than a missing one.** A missing file fails
  loudly; a file in a path nobody reads looks like success forever.
- **"The agent wrote to the wrong place" deserves one minute of checking
  before it is believed.** Twice now the agent was right about where its
  own files live, and twice the repo was wrong.
- **Ask the gateway what it loaded.** `openclaw doctor` reports injected
  character counts per bootstrap file, `/context list` shows the resolved
  workspace, and `hermes` puts `SOUL.md` in slot #1 of its system prompt.
  Inferring from `ls` and mtimes is what produced every wrong conclusion
  here, including a check made at 13:52 that reported failure for an edit
  the agent completed at 14:01.

Hermes was never wrong: `$HERMES_HOME/SOUL.md` is exactly what Nous
documents. The two products keep identity in different places, and the
spec now names each from its own vendor's docs.

**A missing credential file blocks a cron job before it spends anything.**
Hermes' pre-dispatch validation checks that each attached skill's declared
`required_credential_files` exist, reports `blocked_config`, alerts once,
and makes no LLM call. Worth knowing in both directions: it is a real
guard, and it fires on a file's *existence*, not its usefulness — the
Google skill demands a `google_client_secret.json` that nothing reads at
runtime.

## Pi grinding on a failure

**Pi will retry a hopeless command dozens of times unless told not to.**
(2026-11-06) Two add-on runs spent 56 and 45 attempts on one failing
call, roughly a third of each turn. Both failures were defects in the
*spec*, not in Pi's work — so no number of retries could have fixed
either, and the supervisor could have fixed both in a minute.

Give any spec a stopping rule: three failures of the same thing, then
stop and write up what was proved, what was ruled out, and what you would
try next. That hand-back is a result. A supervising agent can read the
host, the repo and the upstream source, none of which Pi can reach.

Watch for the other half of this too. Having failed, Pi explained itself
with a confident wrong root cause ("httplib2 ignores proxy environment
variables" — it does not). An invented cause is worse than an impasse,
because it reads like a finding and gets believed.

## Writing scripts people wait on

**Any wait longer than about 30 seconds must say how long it will be.**
(2026-11-06) A user reported `install` "stuck for a few minutes"; it was
four minutes into a base `verify.sh` whose output it had redirected to a
log, so it sat mute. Nothing was wrong, and that is the problem — silence
and failure look identical, and the honest response to an apparently hung
script is to kill it.

A rough range is enough: *"this takes 3-6 minutes and prints nothing until
it finishes"*. Better still, name a file to `tail -f`. This applies to
anything that redirects a long command, and to every Pi turn — those run
5–15 minutes with gaps of a minute or more between tool calls, and the
only thing distinguishing that from a hang is having been told.

Measure the range rather than guessing it: `verify.sh` is 3–6 minutes on
the Spark, a `limactl shell` round trip is 60ms, Pi turns in `logs/` run
4–6 minutes for a small task.

## Writing checks

**When you find a defect, the fix is a check that fails on it** — not prose
in the spec. But check the tool's *actual* model first: several `verify.sh`
checks have been wrong because they asserted what output looks like rather
than what the system does.

**Do not grep multi-line JSON with a single-line pattern.** A guard like
`grep -q '"botToken".*"source":"env"'` never matches pretty-printed JSON, so
its step runs unconditionally while looking guarded. Use `jq -e`.

**Watch for skips reading as passes.** In a thirty-line run `SKIP` looks
like `PASS`. `--idempotence` skips unless the phase is `bootstrap`, which is
why `finish-build.sh` runs it before narrowing egress.

That skip is a phase check in `verify.sh`, not a thing egress makes
impossible — worth knowing before you debug the wrong layer. (2026-11-06)
Since the squid change of 2026-10-31, `http_access allow all` follows the
private-range denial, so the whole public web on 80/443 — pypi.org
included — is reachable in **both** phases. What the bootstrap allowlist
still buys is nothing on those ports; the two lists now differ only in
hosts needed on other ports. Measured on a runtime-phase VM: "public web is
reachable through squid".

Consequence: a `pip install` failing under the runtime phase is a real
failure, not an egress one, so do not reach for `install-config.sh` to
widen the allowlist.

Two places still carry the older reasoning. The README, under *Four places
it goes wrong*, says idempotence is bootstrap-only "because Pi's `setup.sh`
fetches from pypi.org" — the behaviour it describes is right and the way
back it gives is right, only the stated cause is stale.
`spec/pi-target-state.md` tells Pi the same thing. That one is frozen and
it is Pi's prompt, so it is left alone deliberately: editing it changes the
next build, and all it costs is Pi sequencing its work more conservatively
than it needs to.

**Mind your own pipes.** (2026-10-29) Piping `finish-build.sh` through
`tail` reported tail's exit code, so a run that printed "The build is NOT
proven" was announced as a success. The repo's own failure mode, committed
by the supervisor.
