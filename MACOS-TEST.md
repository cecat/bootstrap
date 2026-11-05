# macOS build test — instructions for a coding agent

You are testing a port, not following a recipe. Read this whole file first.

**The question:** this repo is verified end to end on Linux/arm64. macOS
was the original host and has not been run since; everything that raised
the Linux check count landed after the Mac run. Does it still build two
working agents on macOS, driven only by its committed documents?

Everything that goes wrong is the result. You are the first person to
exercise this path in weeks, so a gap you hit is a gap the repo has.

---

## How this differs from an ordinary build

Build it exactly as `README.md` says — its agent section is the
procedure, and `AGENTS.md` is the brief. This file adds three things:
what to watch on macOS specifically, that you should **record rather
than silently work around**, and what to write at the end.

**You may fix what you find — within bounds.** Unlike the Linux rebuild
harness this was derived from, the goal here is a working macOS build,
not an untouched measurement. Record every fix in the write-up: each one
is a portability defect that was invisible before today.

The bounds exist because Linux took dozens of sessions over several
weeks to converge, and that work is not visible in the files. The
requirement is that after all the macOS work, **Linux still builds**.

1. **`spec/pi-target-state.md` and `lima/agents.yaml` are off limits.**
   `./scripts/check-frozen.sh` enforces this and `bootstrap.sh` warns if
   either drifts. If you believe macOS needs a change there, that is a
   finding to report, not a change to make. Nothing macOS-specific
   belongs in the spec anyway: the VM has no mounts, so Pi cannot see
   the host, and it runs the same Ubuntu 24.04 either way.

2. **Every other fix must be bounded.** The test, which you can apply by
   reading your own diff: *after this change, does a Linux host execute
   the same instructions it did before?* If yes, the fix is bounded. If
   no, you are changing shared behaviour and it does not go in.

   In practice that means adding a branch rather than editing one.
   `bootstrap.sh:58` has the pattern — `if [ "$(uname -s)" = "Linux" ]`
   around the `/dev/kvm` preflight, which a Mac simply never enters.
   (`uname -s` prints `Darwin` on macOS, not `macOS`.) A fallback chain
   works too, where the existing command stays first and yours runs only
   when it fails: see `log_mtime()` in `scripts/pi-session.sh`, added
   for exactly this reason. What is *not* allowed is rewriting a shared
   function so both platforms take your new version, however much
   cleaner it looks — that is how fixing one platform breaks the other.

3. **Never fix the VM by hand.** A VM repaired by hand looks like
   success while the repo still produces failure for the next person.

4. **Work on a branch, and Linux is the merge gate.** Nothing reaches
   `main` until `./verify/verify.sh --models` passes on a Linux host. A
   macOS fix that cannot survive that has not been bounded properly.

**Do not theorise about a failure before measuring it.** Report the
symptom and the exact command output first. A previous session lost
hours to five successive wrong theories before Pi found the real cause
in one short turn.

**One retry, then stop.** `pi-session.sh` retries transient model errors
itself; let it. If a step fails for another reason, run it once more. If
it fails again, stop and report rather than improvising past it.

---

## What is known to be different on macOS

Five things, each with a specific check. Finding one of these is
expected; finding something else is the interesting case.

**BSD coreutils, not GNU — the likeliest source of silent failures.**
Host-side scripts run on your Mac, where `stat`, `sed`, `date` and
friends take different flags. The dangerous ones fail *quietly*: the Pi
silence watchdog used `stat -c %Y`, which on macOS fell through to a
fallback that made the measured quiet time permanently zero, so the
watchdog could never fire and nothing said so. That one is fixed
(`log_mtime` in `pi-session.sh`); assume there are others. Anything
in-guest is safe — that is Ubuntu on both platforms — so only host-side
code is at risk. When you find one, fix it the way `log_mtime` does:
try the GNU form first, because BSD's `stat -f` on GNU exits non-zero
*but still prints to stdout*, so the obvious ordering captures garbage.

**The hypervisor.** macOS uses Apple's Virtualization.framework (`vz`);
Linux uses QEMU+KVM. `lima/agents.yaml` deliberately does not pin
`vmType` or `arch` — both follow the host — so this *should* just work.
Confirm which one you actually got rather than assuming:

```sh
limactl list                       # VMTYPE column: expect vz on macOS
```

The preflight `/dev/kvm` check in `bootstrap.sh` is guarded by
`uname -s = Linux` and should not fire here. If it does, that is a bug.

**The host gateway address.** The VM reaches your model endpoint at
`192.168.5.2`, Lima's user-mode subnet. It is the same under `vz` and
QEMU slirp, which is why this worked on both — but it is load-bearing,
so confirm it rather than assuming. `verify.sh` asserts it for you:

```sh
./verify/verify.sh     # expect: VM gateway address matches the guest's default route
```

This file used to say `limactl shell agents -- ip route`, which
`.claude/settings.json` denies — only two named read-only probes are
allowed in the VM, and that is not one of them. A strict agent would
have stalled on an instruction the permissions forbid.

**Homebrew versus release binaries.** `README.md` tells Linux users to
take the Lima release binary because distro packages lag. On macOS
`brew install lima` is the documented path. Note the Lima version you
actually have; the repo requires 1.0.0 or newer and was last verified on
2.2.1.

**A stale assertion.** `todo.md` records that the old macOS run passed a
check which called an OpenClaw gateway method that no longer exists —
meaning the macOS build was once verified with an assertion that would
now fail. Expect `verify.sh` to behave differently than the old
"25 checks" figure suggests. The current Linux run is 39 passed, 0
failed, 3 skipped.

---

## The check nothing automated covers

**Message each agent on Telegram and have it fetch a web page.** No
script substitutes for this. On 2026-10-31 every automated check passed
on Linux while one agent could not reach the web at all; `verify.sh` can
see that a bot is being polled, which is not the same as an agent that
answers.

On 2026-11-04 this was the *only* signal that caught a mute agent:
`verify.sh` read 37 passed, 0 failed both while one agent could not
answer at all and after it was fixed. Nothing in 41 checks could tell
the difference.

Run it after `finish-build.sh`, and do not be put off by how that reads:
narrowing egress to three domains sounds like it would make a web fetch
impossible. It does not. The public web stays open on 80/443, and
`config/allowlist-runtime.conf` only names hosts on non-standard ports —
its own header says so.

**Ask for something from the page body.** A previous run asked for the
items in a nav menu, which `web_fetch`'s Readability extraction strips
by design, so neither agent could answer with the tool the spec requires
and the exchange took three rounds to settle a simple question.

Record each agent's exact words. If one mentions a workaround, a
fallback, a reader proxy, or rate-limiting, quote it — an agent
reporting success by routing around a block is a finding, not a pass.
One agent did exactly that and was right; the other had the same
fallback available and asked permission first. That difference is worth
reporting.

---

## What to write

`MACOS-RESULT.md` in the repo root. **Commit and push it** — the review
happens on a Linux host, so the report only reaches a reviewer through
git. Commit it alongside your changes so they arrive together.

- **Outcome** — the final tally from `verify.sh --models --reboot`, every
  failing check quoted with its message, and separately whether each
  agent fetched a web page over Telegram, in its own words.
- **What differed from Linux** — anything that behaved differently, took
  a different amount of time, or needed a different command. Including
  "nothing did" for a step, which is also a result.
- **Every repo change you made**, with the reason and the symptom that
  prompted it, and whether each one is bounded — i.e. whether a Linux
  host still takes exactly the code it took before. Run
  `./scripts/check-frozen.sh` and report the result.
- **Where the documentation failed you** — any point where you were
  unsure what to do next, had to guess, or looked for something that was
  not there. Quote the passage. Note that `README.md` and
  `docs/spark-handoff.md` are both written from a Linux vantage point;
  say where that shows.
- **Timing** — bootstrap, Pi's build, and whether anything hung. If
  `pi-session.sh` prints `no output for Ns -- killing a turn that has
  stopped working`, record it and say what Pi was doing. That watchdog
  has run across two full Linux builds without firing.
- **Anything you were blocked from doing** — permission denials, missing
  tools, commands that do not exist on macOS.

Never put a token, credential or user id in that file.

Then update `todo.md` item 1, which currently says macOS is unproven.
Say what is now proven and what is not.
