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

**Stage 6 — acceptance. The base build passed on 2026-11-16.**

On `agents-test` (checkout `~/code/bootstrap-test`, always
`AGENTS_VM=agents-test`), with two throwaway bots, built from nothing
on this branch:

- `verify.sh --models` under `finish-build.sh`: **63 passed, 0 failed,
  2 skipped**, idempotence passing first. `verify.sh --reboot`: **62
  passed, 0 failed, 3 skipped**, coming back `sudo=locked`. Both agents
  on `argo:claude-5-opus`; OpenClaw 2026.11.3, Hermes v0.23.1, Pi 1.5.2.
- It took **five push-backs to Pi**, none caused by the hardening:
  plaintext auth profiles from eight `openclaw onboard` runs; a second
  name for the gateway token; OpenClaw's timezone unset; Hermes with no
  `model.provider`, then with the model name shortened to hide it;
  `openclaw.json` left world-readable. Four of those are now sentences
  in the spec. **Those sentences have not been through a build.**
- One of those turns ran with sudo closed and fixed four things, which
  is the evidence that a locked VM can still be repaired by Pi.

**The Google add-on passed on the rewritten flow, 2026-11-16**, with a
fresh consent as a separate test account: `verify --live --base` read
**31 passed, 0 failed**, base suite 60 passed, 0 failed underneath it.
The coding agent ran `auth`, opened the tunnel from the laptop itself
and relayed one link; the owner clicked. One push-back: PySocks had gone
into one of Hermes' two environments and the agent's commands run in
the other, so `--check-live` passed while the agent got `Errno 113`.
The spec now says every environment and `verify.sh` checks every one.

Found on the way, **accepted not fixed**: Hermes snapshots its shell
environment to `~/.hermes/cache/scratch/hermes-snap-*.sh` while running
a command, and that environment holds both agents' bot tokens, because
`install-config.sh` exports them for the openclaw CLI. So Hermes can
read OpenClaw's token. Same exposure as item 4; closing it belongs with
the second-user work.

Still open:

The owner messaged both test bots afterwards and reports both answered
(their words were not recorded).

- [ ] Pi's `setup-google.sh` restarts the gateway on every run; it calls
      that idempotent and it is not quite
- [ ] `bootstrap.sh`'s `sg kvm` re-exec is still unexercised (the Spark
      user is already in the group), and so are `remove` and changing a
      value in `agents.env` on a finished VM

**Stage 7 — the real VM. The upgrade path is proven; applying it waits
on the owner.**

`scripts/upgrade-vm.sh` was run on `agents-old`, a VM provisioned from
`main`'s definition (checkout `~/code/bootstrap-old`) and put in the
`runtime` phase with no agents in it. Before: six sandbox checks failed
(host off the model port, private IPv6, port 53, IPv6 bypass, sudo, admin
helper). After: all fifteen pass, and a reboot comes back
`phase=runtime lockdown=active sudo=locked`.

**Applied to `agents` on 2026-11-16.** `~/code/bootstrap` is on
`hardening`; the old definition is at
`~/.lima/agents/lima.yaml.before-upgrade-20261116T161537Z`. Afterwards:
`verify.sh --models` **62 passed, 1 failed, 2 skipped** — every sandbox
check passing, both agents completing, OpenClaw fetching a page, both on
`argo:claude-5-opus`. google-openclaw `verify`: 23 passed, 0 failed.
google-hermes `verify --live`: 30 passed, 1 failed.

**Then two regressions, caused by this work and repaired the same day.**
Telling Pi to "put the fix in setup.sh and run it" on `agents` re-ran a
script from 2026-11-09, which set OpenClaw's memory provider back to
`none` and wrote a stray `SOUL.md` (`docs/gotchas.md`). Pi restored
both directly, without re-running the script. Evidence afterwards, none
of it Pi's word:

- `verify.sh`: **61 passed, 0 failed, 5 skipped**, including two new
  behavioural memory checks — the gateway's own embedding probe answers
  `ok`, and a nonsense word still finds matches by vector
- `diag-workspace.sh`: LuoJi's `SOUL.md` last modified 2026-11-11
  23:16, matching the workspace's own last git commit; no uncommitted
  change to any identity file; Gandalf's `SOUL.md` last modified
  2026-11-11 13:52; the only other `SOUL.md` is in the Trash
- the gateway-token doctor warning is gone and stayed gone across a
  config re-push; PySocks is in all three Hermes environments;
  google-hermes `verify --live` 31/0, google-openclaw `verify` 23/0

Still open on `agents`:

The owner messaged LuoJi and Gandalf after the last restart and reports
both answer. `hardening` was merged to `main` and pushed on 2026-11-16.

- [ ] **`~/agent-bootstrap/setup.sh` on `agents` is not trusted.** Pi
      says it corrected the memory and `SOUL.md` sections; nobody has
      run it since, deliberately. Before anyone does: reopen, run
      `verify.sh --idempotence`, and treat any change it makes as a
      revert
**Models upgraded on `agents`, 2026-11-16.** Both agents and Pi are on
`argo:claude-5.5-opus`; the mechanical jobs are on
`argo:claude-5.5-haiku`; Gandalf's memory review is back on the agent's
own model at `memory.nudge_interval: 2`. `verify.sh --models`: **64
passed, 0 failed, 2 skipped.** Why: `argo:gemini-3.8-flash`, the
auxiliary model since 2026-11-09, fails every tool conversation after
its first step through this gateway (`Invalid thought signature`) and
its Anthropic-shaped stream too — reproduced from the host with no
Hermes involved. `/refine` did save a memory on it (`USER.md`, the first
write since 2026-11-11) and then died on its next step.

Pi's first turn on 5.5 Opus applied all of that in 17 tool calls with no
push-back, and reported three things nobody had asked about:

- [ ] **Hermes `model.provider` is `auto`, with `base_url` naming
      OpenRouter.** Completions reach the gateway anyway, through
      `OPENAI_BASE_URL` in `~/.hermes/.env`. The spec requires
      `argo-gateway`. Probable consequence: `stale_timeout_seconds: 90`
      sits under `providers.argo-gateway` and is not applied — the log
      shows the watchdog at 900s — so "Hermes fails fast on a wedged
      upstream" passes on a setting that is not in force
- [ ] Hermes warns on every start: `providers.argo-gateway: unknown
      config keys ignored: type`
- [ ] older parts of `setup.sh` on `agents` still act unconditionally;
      it remains unsafe to re-run (see above)
- [ ] **Gandalf's review now runs cleanly; whether it saves unasked is
      not yet seen.** After the upgrade, one review ran on
      `argo:claude-5.5-opus` at 21:32 on 2026-11-16: `calls=1 in=0
      out=124 cache_read=80380 result=none`, no error. So the trigger,
      the model, the warm cache and the tool path all work — and the
      model judged that turn held nothing to save. The message with the
      thing worth remembering may have been the second, which does not
      trigger a review until the count reaches 2 again. Look at
      `./scripts/diag-memory.sh` after a few days of ordinary use: the
      reviews column should track Telegram turns at about one in two,
      and `USER.md` / `MEMORY.md` should have moved. `/refine` in the
      chat forces a review at any time. A message sent while a review
      runs cancels it — the vendor's design, not fixable by a setting
- [ ] LuoJi has no `MEMORY.md` and that is expected: deep-phase
      promotion needs score 0.75, 3 recalls and 3 distinct queries, and
      nothing has reached it (118 short-term entries, 0 promoted).
      Worth a second look only if it is still empty in a few weeks.
      Its newest memory file is from 2026-11-11; the hook that writes
      them fires on a session reset
- [ ] `addons/google-openclaw/install.sh` and `addons/signal/install.sh`
      still run `sudo` inside the guest (installing `gog`, apt for
      signal-cli). On a locked VM that fails; they need `vm_root` or
      `install-config.sh --reopen`. Their `verify.sh` is already fixed
- [ ] the owner revokes the test Google account's consent and deletes
      the two test bots (both test VMs and their checkouts are gone)

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
