# Unfinished

Open items only. Things that went wrong once and were fixed live in
`docs/gotchas.md`; resolved items live in git history
(`git show 95bba16:todo.md` for the 572-line version this replaced).

---

## 0. Hardening pass — in progress on branch `hardening`

Started 2026-11-14 from a review of the base build and the Hermes Google
add-on. Audience assumed: Argonne people with Argo. Delete each line as
it lands; delete this section when stage 7 is done.

**The standing rule: the running `agents` VM is not touched until stage
7, and only on the owner's say-so.** Tests run on a throwaway VM,
`agents-test`, from a separate checkout (`~/code/bootstrap-test` on the
Spark) with `AGENTS_VM=agents-test` on every command.

**Stages 1–5 are written and committed** (2026-11-14). What that does
and does not mean:

*Proven on `agents-test`* — a VM provisioned from this branch, with no
agents built in it: every new sandbox check passes in both phases; the
lock survives a reboot; `limactl stop`/`start` works with sudo closed;
the admin helper runs root scripts for the host and refuses a wrong
secret; `install-config.sh` re-pushes onto a locked VM and leaves it
locked. Against the live `agents` VM the same checks failed four ways,
which is the evidence the findings were real: through squid the host's
port 22 connected.

*Written but not yet run* — stage 6 is where these are first exercised:

- [ ] a Pi build from the edited spec (sudo rule, `AGENT_MODEL` read
      from `agents.env`). The spec is a prompt; a reword can change what
      gets built
- [ ] `finish-build.sh` locking a VM that has real agents in it, and the
      gateways working with no sudo
- [ ] `bootstrap.sh`'s Telegram token check against real tokens, and its
      `sg kvm` re-exec (the Spark user is already in the group)
- [ ] `verify.sh`'s Versions lines, and `AGENT_MODEL` matching
- [ ] the whole Google add-on flow as rewritten: agent-run `auth` and
      `install`, its own Pi session, one host copy of the token, the
      fuller `remove`
- [ ] changing a value in `agents.env` on a finished VM
      (`docs/updating.md` says this path is unexercised)

*Decided against, so nobody re-proposes them:*

- **Removing the two egress phases.** They now differ in something real
  — sudo — so the phase is kept and `--reopen` is the way back.
- **A table generating both the spec's settings and their checks.** More
  machinery than the duplication costs.
- **Shrinking the spec much.** History came out and the sudo and model
  paragraphs went in; it is 563 lines, not shorter. Every further cut is
  a change to a prompt that has to be paid for with a build.
- `MACOS-TEST.md` still mentions `check-frozen.sh` and
  `spark-handoff.md`, both gone. It is the record of a finished port and
  was left as written.

**Stage 6 — acceptance. In progress; paused 2026-11-14 when the
laptop closed.** Pick up here.

Where it stands, on `agents-test` (checkout `~/code/bootstrap-test`,
always `AGENTS_VM=agents-test`), bots `@Cheetah_cec_bot` (OpenClaw) and
`@Puma_cec_bot` (Hermes):

- `bootstrap.sh` from nothing: passed, incl. the Telegram token check.
- Pi built both agents from the edited spec in 38 min, on
  `argo:claude-5-opus`. Two push-backs to reach `plaintext=0`: it had
  re-run `openclaw onboard` eight times, each leaving a plaintext auth
  profile, and could not find `openclaw models auth logout <profileId>
  --yes`. **Add that command to the spec.**
- `finish-build.sh` locked the VM: **59 passed, 4 failed, 2 skipped.**
  Every sandbox check passes with real agents in it; OpenClaw completes
  and fetches a page.
- A third push-back was sent for the four failures and **was still
  running** when work stopped (`logs/pi-say3.out`, then
  `./scripts/pi-session.sh summary`): Hermes completion returning "Your
  request was not processed"; `OPENCLAW_GATEWAY_TOKEN` conflicting with
  `gateway.auth.token` in openclaw doctor; OpenClaw `userTimezone`
  unset; hermes doctor "Skills Hub directory not initialized".

Next, in order:

- [ ] read Pi's summary for that turn against `./verify/verify.sh --models`
- [ ] add "Chromium not installed" to `DOCTOR_OK` in both verify
      scripts — Hermes v0.23.1 reworded the no-browser warning, and no
      browser is a recorded decision (item 2)
- [ ] `./verify/verify.sh --models --reboot`
- [ ] the owner messages both test bots and has each fetch a web page
- [ ] Google add-on on the test VM. **Not authorised yet**: the owner
      has not said whether the existing Google credentials may be copied
      into the test checkout. Ask.
- [ ] check idempotence once more (`install-config.sh --reopen`,
      `verify.sh --idempotence`, `finish-build.sh`) — Pi ran `setup.sh`
      25 times getting here

**Stage 7 — the real VM.** Prove an in-place upgrade on a throwaway VM
built from `main` first, then apply to `agents` (one stop/start), then
merge and push. vLLM (`vllm-qwen3-coder-next`) was stopped on
2026-11-14 to free memory for the test VM: `docker start` it after.

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

## 6. Conference-ops lives in its own repo now

A specification for using LuoJi to run a conference briefly lived at
`addons/conference-ops/`. It was moved out on 2026-11-12 to
`~/code/conference-assist` (public, standalone): this repo builds agents
and is meant to be cloned by anyone, while that one is a project that
*uses* them. The tell was having to redact the subject matter to make it
fit here.

Nothing in this repo depends on it. `addons/google-openclaw/` is the
plumbing it needs and stands alone.
