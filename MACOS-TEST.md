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

**You may fix what you find.** Unlike the Linux rebuild harness this was
derived from, the goal here is a working macOS build, not an untouched
measurement. But fix the *repo* — a script, the spec, a document — and
never the VM by hand. A VM repaired by hand looks like success while the
repo still produces failure for the next person. Record every fix in the
write-up, because each one is a portability defect that was invisible
before today.

**Do not theorise about a failure before measuring it.** Report the
symptom and the exact command output first. A previous session lost
hours to five successive wrong theories before Pi found the real cause
in one short turn.

**One retry, then stop.** `pi-session.sh` retries transient model errors
itself; let it. If a step fails for another reason, run it once more. If
it fails again, stop and report rather than improvising past it.

---

## What is known to be different on macOS

Four things, each with a specific check. Finding one of these is
expected; finding something else is the interesting case.

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
QEMU slirp, which is why this worked on both — but it is load-bearing
and worth confirming before Pi builds anything:

```sh
limactl shell agents -- ip route | grep default     # expect via 192.168.5.2
```

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

Record each agent's exact words. If one mentions a workaround, a
fallback, a reader proxy, or rate-limiting, quote it — an agent
reporting success by routing around a block is a finding, not a pass.

---

## What to write

`MACOS-RESULT.md` in the repo root. It is gitignored; do not commit it.

- **Outcome** — the final tally from `verify.sh --models --reboot`, every
  failing check quoted with its message, and separately whether each
  agent fetched a web page over Telegram, in its own words.
- **What differed from Linux** — anything that behaved differently, took
  a different amount of time, or needed a different command. Including
  "nothing did" for a step, which is also a result.
- **Every repo change you made**, with the reason and the symptom that
  prompted it.
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
