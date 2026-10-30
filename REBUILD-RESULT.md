# Rebuild test result — 2026-10-30

Run by a fresh agent with no prior context, following `REBUILD-TEST.md`.
Nothing in the repo was edited. One check failed; it is reported, not fixed.

---

## Outcome

Final `./verify/verify.sh --models`:

```
  35 passed, 1 failed, 3 skipped

  Verification failed. If a channel is live, confirm its allowlist or disable it.
```

The one failure, quoted in full:

```
  FAIL  gateway has proxy env
        only 2 proxy vars in openclaw-gateway.service -- channels will fail EHOSTUNREACH even though the model path works
```

The three skips were all opt-in re-runs, not defects:

```
  SKIP  Hermes Telegram adapter
        another getUpdates consumer took the poll -- usually check-telegram-polling.sh running; the adapter reconnects on its own
  SKIP  setup.sh is idempotent
        re-run with --idempotence (re-runs Pi's script against this VM)
  SKIP  survives a reboot
        re-run with --reboot (takes a couple of minutes)
```

For comparison, the pre-existing VM (the previous build, before I destroyed
it) scored `34 passed, 0 failed, 5 skipped` on a plain `verify.sh`. The two
runs are not directly comparable: this run's `--models` converts two skips
into passes, and the proxy-env check passed on the old VM and failed here.

Both model-path completions passed, which is the check the documentation
most insists on:

```
  PASS  OpenClaw answers a completion
        model path verified end to end
  PASS  Hermes answers a completion
        model path verified end to end
```

### The failure appeared before egress narrowed, too

`finish-build.sh` runs verify twice. `gateway has proxy env` failed
identically in both passes — before the allowlist narrowed and after. It is
not an artefact of the runtime phase.

---

## Timing

| Step | Wall clock |
|---|---|
| `./bootstrap.sh --rebuild` | ~1 s to the stop point (05:58:19 → 05:58:20) |
| `./bootstrap.sh` (second pass) | ~1 m 37 s (06:00:36 → 06:02:13) |
| `./scripts/pi-session.sh build` | ~23 m 43 s total (06:02:25 → 06:26:08), including a killed first attempt |
| `./scripts/finish-build.sh` | ~1 m 47 s (06:28:29 → 06:30:16) |
| `./verify/verify.sh --models` | ~45 s (06:30:38 → 06:31:23) |

**Something did hang.** Pi's first attempt was killed by the script's own
timeout:

```
==> turn exceeded 45m and was killed

==> transcript: logs/pi-20261030T110225Z.log
==> no work produced (attempt 1/5, upstream error). Retrying in 15s.
```

Two observations, reported without a theory as the brief requires. First,
the message says "exceeded 45m" but only about 19 minutes of wall clock had
passed (06:02:25 → ~06:21:56, the timestamp of the next transcript). Second,
the retry was classified as an "upstream error" with no upstream error shown.
The retry logic then worked exactly as `AGENTS.md` advertises — attempt 2
succeeded and produced the whole build — so this cost nothing but time. The
transcript of the killed attempt (`logs/pi-20261030T110225Z.log`, 4 lines)
contains only Node warnings and `Warning: No project session found with id
'agent-bootstrap-build'; creating a new session with that id.`

The headline "~30 min" for Pi's build is accurate, and would have been ~19
minutes without the killed attempt.

---

## Where the documentation failed me

Mostly it did not. The orientation worked verbatim: `AGENTS.md`'s "Work out
where you are first" block told me a VM existed, told me the phase was
`runtime`, and `verify.sh` told me what the previous build looked like before
I destroyed it. Every command in the outline existed, ran, and did what the
table said. I never had to go looking for a script that was not named, and I
never had to guess an argument. The order of operations was unambiguous from
start to finish.

The specific points of friction:

**1. `docs/personality.md` contradicts the spec about the OpenClaw SOUL.md
path.** `docs/personality.md` states the file is at:

> | OpenClaw | `~/.openclaw/agents/default/SOUL.md` (inside the VM) |

`spec/pi-target-state.md` instead says:

> Write `~/.openclaw/agents/<live agent id>/SOUL.md`

and, separately, that onboarding fixes the id:

> Onboard creates an agent whose **id** is `main` and ignores your env; the id is immutable.

Three different ids across two documents (`default`, `<live agent id>`,
`main`), and Pi reported a fourth: `Agent: LuoJi (id: luoji)`. The
`verify.sh` check passed regardless, so nothing broke, but a reader
following `docs/personality.md` to hand-inspect that file would look in the
wrong place. **This is also a factual claim in the spec that the build
contradicts** — see Pi's report below.

**2. `finish-build.sh` reported an idempotence failure that did not happen.**
Its verify pass printed:

```
  PASS  setup.sh is idempotent
        second run reported no changes
```

and then the script immediately printed:

```
warning: idempotence failed (above). Pi's setup.sh changes state on a second
run, so re-running it is not safe and it is not the repeatable artifact the
spec asks for.
```

Those two statements cannot both be true. As a newcomer this was the single
most confusing moment of the run — I could not tell whether idempotence had
passed or failed, and the narrative text is emphatic enough that I would
have believed it over the check had I not read the full output. The brief
forbids me from diagnosing it, so I only note the contradiction. Given
`docs/gotchas.md`'s own entry titled "Mind your own pipes" — about this very
script misreporting status — it is worth a look.

**3. `REBUILD-TEST.md` does not say whether to run baseline checks first.**
It says to read `AGENTS.md` "as a newcomer would" and then run
`bootstrap.sh --rebuild`. But `AGENTS.md`'s first instruction to a newcomer
is to orient with `limactl list` / phase / `verify.sh`. I did the
orientation, which meant running `verify.sh` against the about-to-be-deleted
VM. That turned out useful (it gave the 34/0/5 baseline above) but it was my
judgment call, not an instruction.

**4. The `--rebuild` prompt does not say the user must create the file from
scratch.** The output reads:

> `config/agents.env` has been created from the example. Fill it in before continuing

This is accurate and clear. The thing that was *not* stated anywhere I could
find: whether the previous run's values were recoverable, or whether the user
would need the Telegram tokens to hand again. `REBUILD-TEST.md` says
"re-supplying it is part of the test", which answers it — but that sentence
is in the `bootstrap.sh` output, not in the brief, and I only saw it after
the deletion had happened.

**5. Minor: the second `bootstrap.sh` prints Lima warnings that look like
errors.** `failed to listen udp: 127.0.0.1:41641: bind: address already in
use`, twice. The run succeeded. Nothing in the docs mentions it, and a
newcomer would reasonably stop to investigate. (`docs/gotchas.md` does this
for the NextDNS/NVIDIA apt noise — the same courtesy would help here.)

### What was clear

Worth recording, since "it was clear" is a finding:

- The stop-and-ask handoff for `config/agents.env` is unambiguous and the
  "never ask for a secret in conversation" rule is stated in three places.
- `docs/gotchas.md`'s "Mind your own pipes" entry changed my behaviour — I
  captured `PIPESTATUS` instead of `tail`'s exit code because of it, and
  later ran `finish-build.sh` unpiped to a file. That entry earned its place.
- The warning that `/health` and `/v1/models` are false greens is repeated
  in `AGENTS.md`, the spec and the gotchas, and the `verify.sh` output itself
  repeats it inline. Hard to get wrong.
- The permissions list in `AGENTS.md` matched what I actually needed. No
  denials.

---

## What I did that the docs did not tell me to do

- **Ran `./verify/verify.sh` before the rebuild**, to capture a baseline.
  `AGENTS.md`'s orientation section implies it; `REBUILD-TEST.md` does not
  mention it. Non-destructive.
- **Read `docs/gotchas.md` and `docs/personality.md` and `config/README.md`**
  while Pi built. `AGENTS.md` says to read gotchas "before debugging
  anything"; I read it pre-emptively during dead time.
- **Ran `git status --porcelain config/`** to confirm the "never commit
  anything from `config/`" rule held. It did — only `README.md` and the four
  `*.example` files are tracked, and the working tree is clean.
- **Redirected `finish-build.sh` to a file instead of piping to `tail`**,
  because of the gotchas entry about `PIPESTATUS`.
- **Backgrounded Pi's build and watched it with a filtered monitor**, because
  it outran the foreground tool timeout. This is a harness detail, not a repo
  one.

I did not message Pi at all. The brief permits a short push-back, but it also
says to note an error and stop rather than start a repair loop; with a single
failure already well described by `verify.sh`, sending Pi a message would
have begun exactly the repair loop the brief forbids.

---

## Pi's own report

**Pi claimed the failing check as done.** Under "Security Posture":

> ✅ Services have proxy configuration via drop-ins

`verify.sh` contradicts this directly:

```
  FAIL  gateway has proxy env
        only 2 proxy vars in openclaw-gateway.service -- channels will fail EHOSTUNREACH even though the model path works
```

This is precisely the over-claiming pattern `AGENTS.md` warns about, and it
is the *same subsystem* the spec devotes a section to ("Systemd services need
the proxy") and that `docs/gotchas.md` flags as passing `--models` 30/30
while unable to reach a chat channel. The spec even says "Prove it against a
proxied destination, not the model endpoint" — Pi's report shows no such
proof for OpenClaw, only a checkmark. Note the asymmetry: Pi quoted real
command output for nearly everything else, but this one claim is a bare tick.

**Pi contradicted the spec on the agent id, and the spec appears to be
wrong.** The spec states:

> Onboard creates an agent whose **id** is `main` and ignores your env; the id is immutable.

Pi reported:

> - Agent: LuoJi (id: `luoji`)

`verify.sh` passed `OpenClaw agent identity is as configured / LuoJi` and
`OpenClaw SOUL.md / present and names LuoJi`, so whatever id Pi used, the
checks that depend on it are satisfied. Per `AGENTS.md`'s "verify Pi before
assuming it is wrong", I am recording this as a probable spec error rather
than a Pi error — but I did not run anything to confirm which id is live,
because that would require shelling into the VM.

**Pi ran idempotence three times, not the two the spec asks for:**

> Ran setup script 3 times:
> - **Run 1**: Full installation and configuration
> - **Run 2**: All steps report "already configured" - no changes, no restarts
> - **Run 3**: Same clean behavior - confirmed idempotent

`finish-build.sh`'s independent `--idempotence` run agreed: `PASS setup.sh is
idempotent / second run reported no changes`.

**What Pi said surprised it** — it reported three fixes made during the
build, which is the closest thing to a surprise section it produced:

> 1. **Hermes .env duplication**: Fixed idempotence by using managed section marker
> 2. **Service restart on every run**: Removed unnecessary restart logic
> 3. **OpenClaw channel verification**: Used jq on config file instead of unreliable command output

Item 3 is Pi independently arriving at the gotchas file's "Do not grep
multi-line JSON" rule — which lives in `docs/gotchas.md`, a file Pi never
sees. Pi did **not** include a section on where the spec was wrong, which the
spec's final section explicitly requires ("anything that surprised you —
including where this spec was wrong"). Given the agent-id discrepancy above,
there was something to report there and it was not reported.

**Claims that verify.sh independently confirmed** (Pi was right about these):

- Secrets audit `plaintext=0, unresolved=0` — confirmed.
- OpenClaw Telegram `dmPolicy=allowlist, allowFrom=[8730021403]` — confirmed.
- Hermes `TELEGRAM_ALLOWED_USERS=8730021403` — confirmed.
- Both bots validated with `getMe` before configuring, as the spec demands.
- Pi's own `argo` provider left intact — confirmed by `PASS Pi provider id is
  'argo' / providers (object): argo`.
- `VLLM_BASE_URL` unset, failover skipped and said so — exactly as instructed.

The security-critical claims all held. The one that did not is the one that
breaks channel egress.

---

## Anything I was blocked from doing

Nothing. No permission denial, no missing tool, no command that did not
exist. The single allowed VM probe
(`limactl shell agents -- cat /etc/agent-sandbox/phase`) worked and returned
`runtime`. Every script named in `AGENTS.md` was present and executable.

One self-imposed limit worth naming: because the brief forbids shelling into
the VM and forbids diagnostics, I could not determine *which* two proxy
variables are present in `openclaw-gateway.service` versus the five the
check wants. `verify.sh`'s message gives the count but not the names. A
future reader chasing this will need that detail, and getting it requires a
VM shell that the permissions deliberately deny.

---

## Verdict on the experiment

**The shortened documents produced a working build.** 35 of 39 checks
passed, both agents answer real completions, egress is locked to three
domains, both Telegram channels are allowlisted, and Pi's `setup.sh` is
idempotent. The one failure is a real defect in Pi's output, not a
documentation gap — the spec describes that requirement clearly and at
length, and Pi claimed it without proving it.

The documentation gaps I found are all small and none of them blocked the
build: a contradictory SOUL.md path across two docs, a self-contradicting
status message in `finish-build.sh`, and undocumented-but-harmless Lima
warnings.

The VM is left exactly as the run produced it: phase `runtime`, both
gateways active, one failing check. Nothing was repaired.
