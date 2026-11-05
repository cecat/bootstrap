# macOS build test — result

**Host:** macOS (Darwin 25.6.0), arm64. Lima 2.2.1 via Homebrew.
**Dates:** attempt 1 2026-11-04, attempt 2 (this run) 2026-11-04/05.
**Branch:** `macos-port`.
**Method:** `./bootstrap.sh --rebuild` — the VM and all generated config
destroyed first, so this is a from-scratch build driven only by the
committed documents.

*(Status: the build is up and green on a plain run. Marked PENDING below:
`--idempotence` re-check after Pi's fix, `--reboot`, and the Telegram
web-fetch check. Everything else is final.)*

---

## Outcome

Verify tallies in order, so the shape of the run is visible:

| Point in the build | passed | failed | skipped |
|---|---|---|---|
| Pre-Pi baseline | 24 | 6 | 10 |
| After Pi's build (`--models`) | 35 | 2 | 4 |
| After Pi's Hermes fix | 35 | 1 | 5 |
| After `finish-build.sh` | 37 | 1 | 3 |
| Current, plain run | 35 | 0 | 6 |

`--models` passed both agent completions: *"OpenClaw answers a completion
— model path verified end to end"* and the same for Hermes.

Final `--models --reboot` tally: **PENDING.**

### Failures seen, each quoted

1. **`hermes-gateway`** — *"Telegram is configured but the gateway is
   activating -- run: hermes gateway install"*. Real defect. Pi had run
   Hermes as a standalone `--idle-exit` process because the systemd unit
   exited 75 ("already running"), and reported success over it. This is
   the documented *"Pi quietly weakens things that block it"* pattern.
   Fixed by Pi on one short push-back: kill standalone processes before
   starting the unit, require `systemctl --user is-active` and die with
   journal output otherwise, and enable linger. Now passes.

2. **`setup.sh is idempotent`** — *"4 step(s) acted on a second run --
   look for a guard that never matches: Migrating argo-gateway apiKey to
   SecretRef... Setting OpenClaw proxy configuration...|Setting Telegram
   allowFrom to [...]"*. Real defect. Pi had reported this in its own
   summary as *"Minor non-idempotent behaviors (safe, cosmetic only)"* —
   it is a verify failure, not cosmetic. Pi's fix: PENDING.

3. **`egress phase`** — *"still 'bootstrap' (wide allowlist)"*. Not a
   defect; expected before `finish-build.sh` narrows it. Passed as
   *"runtime (steady state)"* afterwards.

4. **`Hermes Telegram adapter`** — *"All connection attempts failed --
   still down 20s later, so it is not reconnecting on its own"*. **The
   check was wrong, not the build.** The adapter dropped its connection
   when egress narrowed and reconnected shortly after; the next run
   passed. A 20-second window does not support the claim "it is not
   reconnecting on its own". See *Check defects* below.

### Telegram web-fetch check

PENDING — the one thing no script covers.

---

## What differed from Linux

### The hypervisor, the gateway, the image — nothing differed

- **`vz`, as predicted.** `limactl list` shows `VMTYPE vz`, `ARCH
  aarch64`. `lima/agents.yaml` pins neither and both followed the host.
- **The `/dev/kvm` preflight correctly did not fire**, being guarded by
  `if [ "$(uname -s)" = "Linux" ]` at `bootstrap.sh:58`.
- **The host gateway address holds under `vz`.** `verify.sh` passed *"VM
  gateway address matches the guest's default route — 192.168.5.2"*.
  I did not need `limactl shell agents -- ip route` for this; the suite
  asserts it independently, which is better evidence anyway.
- **Model detection** worked unmodified, finding the host gateway and
  resolving three models.
- **Guest-side GNU-isms are safe**, as the brief predicted. The `sed -i`,
  `stat -c '%a'` and `timeout` uses in `install-config.sh` and
  `verify.sh` are all inside `limactl shell … bash -c` blocks running on
  Ubuntu.
- **`brew install lima` gave 2.2.1** — above the 1.0.0 floor and the
  version Linux was last verified on. The README's macOS line is
  accurate.

### Host-side BSD divergence — one new instance, one pre-existing

The brief predicted more of these and it was right to.

- **`tail` has no `--pid` on BSD** (found in attempt 1, fixed there).
- **`wait` on a backgrounded pipeline** — the attempt-1 fix was itself
  incomplete; see *Repo changes* below. This is the defect that killed
  attempt 1.
- **`timeout(1)` does not exist on macOS.** Not hit in anger — every use
  in this repo is in-guest — but it is absent from the host, so any
  future host-side use would fail.
- **`log_mtime` is correct on this host.** Measured: `stat -c %Y` exits 1
  printing nothing to stdout, `stat -f %m` succeeds. The watchdog's
  arithmetic was never the problem in attempt 1.

### Timing

- `./bootstrap.sh --rebuild` to the `agents.env` stop: ~1s.
- `./bootstrap.sh` (provision + config + egress): **1m 55s**, far under
  the ~10 minutes the script predicts, because the Ubuntu image was
  already in `~/Library/Caches/lima`. A cold Mac would be slower.
- Pi's build, attempt 1: **308s, aborted, built nothing** (below).
- Pi's build, attempt 2: **24m 28s**, 14,359 events, zero model errors.
  Squarely in the expected ~30-minute band.
- Pi's Hermes fix: ~4m. Pi's idempotence fix: PENDING.
- `finish-build.sh`: ~3m 40s.
- **Nothing hung.** The silence watchdog did not fire at any point, and
  after the fix below, no turn needed it to.

### Pi aborted once, and the wrapper called it success

Pi's first build ran 12 tool calls in 22s — checked egress, validated
both Telegram tokens, downloaded and checksummed both installers — then
three consecutive model calls died:

```
"stopReason": "error", "errorMessage": "terminated", "durationMs": 121337
```

Three `auto_retry_start`, one `auto_retry_end`, then `agent_settled`.
Nothing installed. `diag-stream.sh` immediately afterwards showed the
model path healthy: a 90 KB request like Pi's real one returned **HTTP
200 in 18.4s** with a clean `message_stop`, Pi itself answered `PI_OK` on
a fresh session, and `ARGO_CREDENTIAL` resolved. The credential-rejection
signature from `docs/gotchas.md` reproduced only for a deliberately bad
key. So: the documented transient, and the retry was the right response —
it then built cleanly with nothing changed.

Whether this is more frequent on macOS, one sample cannot say.

---

## Check and harness defects found

These are not build failures; they are defects in the things that measure
the build. All are platform-neutral.

1. **`pi-session.sh` exits 0 over an aborted build.** Its no-work retry
   arms only when the exit code is non-zero *and* no tool call was
   reached. Pi exited 0 despite `stopReason: error`, having made tool
   calls, so the wrapper reported success for a build that did not
   happen. A supervisor trusting the exit code would have gone straight
   to `finish-build.sh`. **Not fixed** — reporting rather than changing
   shared behaviour mid-test.

2. **`pi-session.sh summary` printed nothing at all** for that run. The
   final `turn_end` carried an empty content array, so the supervisor's
   primary signal was silent in exactly the case where it most needed to
   speak. It does not distinguish "no summary" from "no turn_end", which
   it has a message for. **Not fixed.**

3. **`Hermes Telegram adapter` asserts more than it measures.** Quoted
   above: 20 seconds of failure is reported as *"it is not reconnecting
   on its own"*, and it was reconnecting. **Not fixed.**

4. **`MACOS-TEST.md` says this report "is gitignored; do not commit it".
   It is neither.** `git check-ignore` finds no rule, and attempt 1's
   copy is tracked and committed in `ae8df83`. Committed deliberately
   this time, on the user's instruction, so the reviewing agent gets
   changes and results together — but the instruction is stale and
   should be corrected either way.

---

## Repo changes made

`./scripts/check-frozen.sh`: **ok, 2 frozen artifact(s) unchanged.**
`spec/pi-target-state.md` and `lima/agents.yaml` were not touched, and
nothing in this run suggested they should be.

### 1. `9f2edaa` — the progress viewer hung the whole build. **Bounded.**

*Symptom:* attempt 1 died at 379s and never returned, with the silence
watchdog never firing across more than an hour.

*Cause, measured in a 40-second probe rather than guessed:* Pi had in
fact **finished** — its log ends `turn_end`, `agent_end`,
`agent_settled`. Bash's `wait` on a backgrounded *pipeline* waits for the
whole job, not just the pid in `$!`. The macOS fallback `tail` added in
attempt 1 has no `--pid`, so killing `pi_progress` left `wait "$viewer"`
blocked on a `tail -f` that never ends. The watchdog could not save it:
its loop had already exited normally when Pi's process died. The orphaned
`tail -f` was still running two hours later.

*Fix:* the fallback branch records the tail's own pid and kills that;
`pi_progress` then ends on EOF and the job completes.

*Bounded:* yes. The Linux branch is the original line, untouched. Linux
still takes `tail -f --pid=` and never enters the new code.

### 2. `7762088` — bootstrap hid a syntax error in `agents.env`. **Not bounded.**

*Symptom:* after the user filled in `config/agents.env`, bootstrap failed
with *"config/agents.env is not usable (see above). Edit it and re-run."*
and **nothing above it**. The cause was one extra `"` at the end of an
agent name. The same error cost attempt 1 time too.

*Cause:* the validation subshell sourced the file as
`. config/agents.env 2>/dev/null`, discarding bash's own diagnosis, after
which the per-field checks never ran. The user is pointed at a message
that does not exist.

*Fix:* drop `2>/dev/null`. Bash's message is precise and prints no
values. A clean file produces no stderr, so there is no new noise.

*Bounded:* **no** — a Linux host sees this change too. Raised with the
user before making it and approved. It is subtractive and affects only a
path that was already failing and exiting non-zero, so it cannot alter a
successful build. Diagnosing this by hand took an `awk` one-liner to
count quotes per line; that part was deliberately **not** added, as
bloat.

Both changes are host-side only. Neither touches the spec, the VM
definition, or anything in-guest.

---

## Where the documentation failed me

- **`bootstrap.sh:201`** — *"config/agents.env is not usable (see
  above)"* with nothing above. Covered under change 2. This is the single
  worst documentation failure in the run, because it is a signpost
  pointing at empty space, and it has now cost two sessions.

- **`MACOS-TEST.md`** — *"`MACOS-RESULT.md` in the repo root. It is
  gitignored; do not commit it."* False on both counts, and it conflicts
  with getting the report to a reviewer. Covered above.

- **`MACOS-TEST.md`** — *"`limactl shell agents -- ip route | grep
  default`"*. `AGENTS.md` **denies** `limactl shell agents -- <anything
  else>` beyond two named read-only probes, and `ip route` is not one of
  them. The brief tells you to run a command the permissions forbid. No
  harm done — `verify.sh` asserts the same fact independently and better
  — but the two documents disagree and a stricter agent would stall here.

- **The runtime allowlist looked like it would break the final check.**
  `finish-build.sh` narrows egress to three domains and then asks you to
  have an agent fetch a web page. That reads as impossible until you open
  `config/allowlist-runtime.conf`, whose header explains the public web
  stays open on 80/443 and the file only names non-standard ports. The
  instruction and the thing it depends on are in different files, and
  only one of them is reassuring.

- **Linux vantage point in `README.md`.** *"Software — Lima (macOS: `brew
  install lima`; Linux: the release binary …)"* is the one genuinely
  two-platform line, and it is accurate. Everything around it assumes
  Linux: `docs/spark-handoff.md` is named in the same breath, `/dev/kvm`
  and QEMU are treated as the default case, and the macOS path is a
  parenthesis. Nothing misled me, but a Mac user is reading a Linux
  document throughout.

---

## Blocked

Nothing blocked. No permission denial stopped the run; I did not need a
shell in the VM at any point, and did not take one. The only tool absent
on this host was `timeout(1)`, which the repo does not use host-side.
