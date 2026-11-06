# Unfinished

Open items only. Things that went wrong once and were fixed live in
`docs/gotchas.md`; resolved items live in git history
(`git show 95bba16:todo.md` for the 572-line version this replaced).

---

## 1. macOS: built from scratch and merged

**A from-scratch macOS build works.** On 2026-11-04/05 a Mac (Darwin
25.6.0, arm64, Lima 2.2.1 from Homebrew) ran `./bootstrap.sh --rebuild`
and reached **39 passed, 1 failed, 2 skipped** on
`verify.sh --models --reboot` — parity with the Linux reference of 39/0/3.
The one failure is a check defect, not a build defect. Both agents answer
on Telegram and both fetch the public web. Full account in
`MACOS-RESULT.md`, here on `main`. The old "25 checks" figure in
this item was obsolete and is gone.

**What is proven.** `vz` and aarch64 both follow the host with
`lima/agents.yaml` pinning neither; the `/dev/kvm` preflight correctly
does not fire; the `192.168.5.2` gateway address holds under `vz` exactly
as under QEMU slirp; `brew install lima` gives a version above the floor;
guest-side GNU-isms are safe because the guest is Ubuntu either way;
egress survives a reboot with the runtime phase and lockdown intact.

**The merge gate passed.** On 2026-11-05 the branch was run on the Spark
before merging: **37 passed, 1 failed, 3 skipped**, identical to `main`'s
baseline the same day, same single failure (the Hermes adapter check),
both completions passing. Each change was also checked on its own — the
`uname` branch leaves the Linux `tail -f --pid=` line verbatim, and the
`bootstrap.sh` change produces zero stderr on a valid `agents.env` while
naming the offending line on a broken one. Merged in `abf09e7`.

`MACOS-RESULT.md` is now on `main`; it is the fullest account of how the
port went and what it cost.

**What a clean build still needed.** Two host-side fixes, both BSD-vs-GNU:
a `tail`/`wait` interaction that hung the whole build *after* Pi had
finished (the silence watchdog cannot catch this — its loop has already
exited), and `bootstrap.sh` discarding bash's diagnosis of a syntax error
in `agents.env`. Pi also needed three push-backs: Hermes running as a
standalone `--idle-exit` process that would not survive reboot, a
non-idempotent `setup.sh`, and an OpenClaw Telegram adapter that never
started because `--use-env` wants `TELEGRAM_BOT_TOKEN` and the unit only
had `OPENCLAW_TELEGRAM_BOT_TOKEN`.

**Two gaps worth their own items if they are not fixed soon.**
`verify.sh --idempotence` cannot run once `finish-build.sh` has narrowed
egress, and nothing documents a way back to the bootstrap phase — so any
idempotence fix made after that point is unverifiable. And `verify.sh`
read 37 passed, 0 failed while one agent was completely mute on Telegram,
which is why the manual check in `README.md` is load-bearing.

## 2. No browser in the VM, by decision

Both agents ship a browser tool and neither can use it: OpenClaw drives a
system Chrome that is not installed, Hermes bundles a Chromium that exits
127 on `libatk-1.0.so.0` with at least twelve runtime libraries missing.
Found on macOS 2026-11-04, but the guest is the same Ubuntu either way, so
Linux behaves identically.

**Deliberately not fixed.** Installing Chromium means a dozen apt packages,
probably `--no-sandbox` inside a VM whose whole point is confinement, and
the largest single addition anyone has proposed to a spec that is a prompt
and pays for length. `web_fetch` is what the spec requires, it works, and
both agents answered real web questions with it.

The SOUL seed now tells agents to use `web_fetch` and that no browser is
installed, so they stop reaching for a tool that always fails. Revisit only
if something genuinely needs JavaScript-rendered pages.

## 3. vLLM failover is unverified

`docs/failover.md` describes a fallback to a local model over Tailscale. The
config syntax was never confirmed for any of the three agents and the
tailnet was down when it was written. Spec section 4 tells Pi to skip it
unless `VLLM_BASE_URL` is set, and to write nothing it cannot source from
current documentation. A guessed failover config is worse than none.

## 4. Other providers

Only the Argo path is implemented. The structure generalises — one
translation proxy serving `/v1/messages` and `/v1/chat/completions` — and
`AGENTS.md` sketches what adding one involves. Nobody has tried.
