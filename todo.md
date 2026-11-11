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

**Decided 2026-11-11: `SOUL.md` is the mitigation, and that is where this
rests.** Each agent's seed now names the other's tree and says to stay out
of it (`spec/pi-target-state.md`, `docs/personality.md`). The stakes do not
justify more: the realistic failure is an agent tidying up and finding a
credential, which an instruction fixes. A *manipulated* agent ignores it,
and that gap is accepted knowingly rather than overlooked.

Both alternatives were costed before deciding. Recorded so nobody
re-derives them, and so the "it's only one line" version of the second-user
idea does not come back untested.

**A second VM** needs no code changes — every script already honours
`AGENTS_VM` and nothing hardcodes the instance name. It costs **memory**:
121 GiB total on this host with ~10 GiB available against an 8 GiB VM, and
vLLM holds most of the rest. Also two base builds drifting apart, two
`verify.sh` runs, and the loss of being able to compare both gateways under
identical conditions.

**A second Unix user** inside the one VM needs no memory, and four things
assume there is exactly one agent user:

- `/etc/agent-sandbox/agent-user` holds **one** name, and the lockdown is a
  single `iptables -m owner --uid-owner` rule. A second user would have **no
  egress restriction at all** and `verify.sh` would still pass, because it
  checks the uid it knows about. That is the dangerous shape: less
  containment than today while appearing to add some.
- **Pi builds as the Lima user.** Provisioning step 4 is `mode: user` and
  `pi-session.sh` always lands as that user, so every `systemctl --user` in
  the build would target the wrong home unless the spec learns `sudo -u`.
- All four verify suites reach in with `limactl shell … bash -lc`, so each
  OpenClaw check would need re-pointing or it reads the wrong home.
- `limactl shell agents` lands you as the Lima user, so talking to the
  second agent by hand becomes `sudo -u <agent> …`.

If it is ever done, the order is: make `agent-user` a list, switch the rule
to match a group, **prove `verify.sh` catches a bypass from both users**,
and only then add the account. The check before the feature — otherwise
there is no way to tell whether it worked.

Revisit alongside the agentic-collaboration work, which wants a
third-party agent anyway. There the isolation is a feature of the
experiment rather than a tax on it, and `lima/agents.yaml` is being
touched regardless.

## 5. Other providers

Only the Argo path is implemented. The structure generalises — one
translation proxy serving `/v1/messages` and `/v1/chat/completions` — and
`AGENTS.md` sketches what adding one involves. Nobody has tried.
