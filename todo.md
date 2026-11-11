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

## 4. The two agents are not isolated from each other

Both run as the **same Unix user** in one VM. `~/.hermes/` and
`~/.openclaw/` are directories, not homes, so `0600` protects nothing
between them: either agent can read the other's Telegram token, Google
credentials, or keyring password, and a stolen token works because a
token is all the far end ever checks. OpenClaw's own documentation says
the same of its skill allowlists — *"not a shell-time authorization
boundary… that shell can still run external clients or read host files
that are visible to the execution user."*

**Mitigated, not fixed.** Each agent's `SOUL.md` now tells it to stay out
of the other's tree (`spec/pi-target-state.md`, `docs/personality.md`).
That addresses the realistic failure — an agent tidying up and finding a
credential — and does nothing against a manipulated one. It matters more
now that one agent reads mail from strangers.

**The real fix is a second Unix user, or a second VM.** Notes toward it,
from a 2026-11-11 estimate:

- The repo is **already parameterised**: every script honours `AGENTS_VM`
  and nothing hardcodes the instance name, so a second VM is mostly a
  second `limactl start` plus a second config set. Cheaper than it looks.
- **Memory is the constraint on this host**, not the code. 121 GiB total
  with ~10 GiB available; the VM is 8 GiB and vLLM holds most of the
  rest. A second VM needs that budget resolved first.
- The costs are two base builds drifting apart, two `verify.sh` runs, and
  losing the ability to compare both gateways under identical conditions.
- A second Unix user inside the one VM is the cheaper variant and was not
  costed. It keeps one build and one verify run, and `lima/agents.yaml`
  would have to create the account and split the systemd user services.

Worth doing when there is a second reason — the agentic-collaboration
work wants a third-party agent anyway, and there the isolation is a
feature of the experiment rather than a tax on it.

## 5. Other providers

Only the Argo path is implemented. The structure generalises — one
translation proxy serving `/v1/messages` and `/v1/chat/completions` — and
`AGENTS.md` sketches what adding one involves. Nobody has tried.
