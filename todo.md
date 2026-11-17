# Unfinished

Open items only. Things that went wrong once and were fixed live in
`docs/gotchas.md`; resolved items live in git history
(`git show 95bba16:todo.md` for the 572-line version this replaced).

---

## 0. Hand-off — where this stands on 2026-11-16, and what is left

Written at the end of a three-day hardening pass, for whoever picks
this up next. The detail of how each thing was found is in
`docs/gotchas.md` and in git history (`git log e59cb32..`); this is
only what is true now and what is still owed.

### What is true now

- **The repo builds a working system from nothing** on Linux arm64
  (DGX Spark, Lima 2.2.1, QEMU+KVM). On 2026-11-16 a fresh VM built by
  Pi reached `verify.sh --models` 63 passed, 0 failed and came back from
  a reboot still locked; the Hermes Google add-on on top of it read 31
  passed, 0 failed with a fresh consent. Both test VMs are gone.
- **The owner's VM (`agents`) was upgraded in place** with
  `scripts/upgrade-vm.sh` and reads `verify.sh --models` 64 passed, 0
  failed. Both agents and Pi run `argo:claude-5.5-opus`; mechanical jobs
  run `argo:claude-5.5-haiku`. Both bots answer.
- **The sandbox is what the README says it is**, which it was not
  before: one host, one port; IPv6 locked; port 53 to the resolvers
  only; no `sudo` for the agents once a build is locked. The host's way
  to root is `config/admin-secret` — back it up; losing it means a
  rebuild.
- `main` is on GitHub, this Mac and the Spark at the same commit.

### Owed before this can be called finished — in order

1. **One more from-scratch build.** The acceptance build ran *before*
   a dozen sentences went into the spec: onboard once, one name for the
   gateway token, `openclaw.json` at 600, Hermes `model.provider`,
   explicit auxiliary providers, the memory review on the main model,
   `memory.nudge_interval: 2`, both stale-timeout keys, the 5.5 models,
   and Pi itself on Opus. Each was proven on a live VM by a targeted
   change; none has been through a build. The spec is a prompt, and
   this is the only test that counts. Needs two throwaway Telegram
   bots, about an hour, and 8 GiB the Spark only has with vLLM stopped.
   Expect it to go better than the last one: Pi's first turns on Opus
   needed no push-back at all.
2. **`~/agent-bootstrap/setup.sh` inside `agents` is not trusted.** It
   was written on 2026-11-09 and patched section by section since. Re-
   running it on 2026-11-16 undid two fixes. Pi says the current copy
   would change nothing; nobody has run it to find out. Either prove it
   (`install-config.sh --reopen`, `verify.sh --idempotence`,
   `finish-build.sh`, and treat any change as a revert) or accept that
   this VM's script is a record, not a tool. `docs/updating.md` says how
   to work in the meantime.
3. ~~**Two add-on installers break on a locked VM.**~~ Fixed
   2026-11-17: both now source `scripts/lib-vm.sh` and go through
   `vm_root`. In `google-openclaw` the download deliberately stays as
   the agent user — root is exempt from the uid rule, so fetching as
   root would bypass squid — and only the `install` into
   `/usr/local/bin` is privileged. `addons/signal/spec.md` also told Pi
   to `apt-get install`, which Pi cannot do on a locked VM; that step
   is now a guard, because the host installer puts signal-cli in
   before linking. **Neither is exercised** — google-openclaw's path
   only runs when gog is absent, and Signal has never been built.
4. ~~**`addons/google-openclaw` still said "NOT YET BUILT".**~~ Fixed
   2026-11-17, against a live `verify.sh --live` run on `agents`: 23
   passed, with a real Google read returning. Its flow now matches the
   Hermes one, and PLAN.md's three open questions are closed with what
   building it taught. `remove` is still unexercised and says so.
   That run also caught a drift: its `DOCTOR_OK` had never received
   `Chromium not installed`, added to the other two suites on
   2026-11-16. All three lists are now identical and say to copy
   rather than extend.
5. **`README.md`'s Status section is a week stale** — check counts,
   dates, models. Rewrite it from item 1's result rather than patching.
   The add-on table row is already current.

### Never exercised — say so rather than assume

- `bootstrap.sh` re-running itself under `sg kvm` (the Spark user is
  already in the group)
- changing a value in `config/agents.env` on a finished VM
  (`docs/updating.md` describes it; nobody has done it)
- the Hermes Google add-on's `remove`
- any of this on **macOS** since the hardening: `ip6tables`, the sudoers
  lock and `upgrade-vm.sh` have only run on Linux. `MACOS-TEST.md` still
  names two files that no longer exist
- an **x86_64** host, ever

### Watch, do not fix yet

- **Does Gandalf now save memories unasked?** The review runs cleanly
  on the main model (one clean run, which chose to save nothing). Run
  `./scripts/diag-memory.sh` after a few days of ordinary use: reviews
  should track Telegram turns at about one in two, and `USER.md` /
  `MEMORY.md` should have moved. A message sent while a review is
  running cancels it — Hermes' design, and no setting changes it.
  `/refine` in the chat forces one.
- **LuoJi has no `MEMORY.md`, and that is expected**: OpenClaw's deep
  phase promotes only at score 0.75, 3 recalls and 3 distinct queries,
  and nothing has got there (118 short-term entries, 0 promoted). Look
  again only if it is still empty in a few weeks. Its newest memory
  file is from 2026-11-11; the hook that writes them fires on a session
  reset. Its embedding probe and vector search both work.

### Known, accepted, or somebody else's to fix

- **`argo:gemini-3.8-flash` cannot hold a tool conversation through
  this gateway** — one tool call, then `400 Invalid thought signature`
  — and its Anthropic-shaped stream fails too. Reproducible from the
  host in ten lines. Worth reporting to whoever runs the Argo gateway;
  nothing here uses it any more. *Listed in `/v1/models` is not
  working*: test a candidate model with a two-step tool call before
  giving it a job.
- **`hermes doctor` warns about Hermes' own npm dependencies.** Two so
  far, found 2026-11-17: "Root npm package deps (0 critical, 4 high, 8
  moderate)" and "web workspace deps (0 critical, 7 high, 3 moderate)".
  The second appeared only once the first was excluded — it is a family,
  so the exclusion matches their shared remediation phrase rather than
  the workspace names. They are about Hermes' bundled npm trees, not
  anything this repo installs, and each says its fix is an upstream
  lockfile bump that a local change would not survive. Nous' own
  threshold agrees: `hermes security audit` defaults to `--fail-on
  critical` and these are 0 critical.
  **The exclusion keeps `0 critical` in the pattern**, so a genuinely
  critical advisory still turns the suite red rather than being
  swallowed. That does mean it matches on the vendor's wording and will
  break if Nous rewords the line — deliberately, since breaking fails
  loud rather than silently open. Worth reporting to Nous.
- **Hermes v0.23 looks a named provider's timeout up under `custom`.**
  The spec sets both keys. Worth reporting to Nous; when it is fixed,
  `providers.custom` can go.
- **Both wire formats stop at 4,096 output tokens when the client sends
  no limit** (measured 2026-11-16 on 5.5 Opus). Hermes sends none.
- **Hermes writes a snapshot of its shell environment** under
  `~/.hermes/cache/scratch/`, and that environment holds both agents'
  bot tokens. So Hermes can read OpenClaw's. Same exposure as item 4
  below; closing it belongs with the second-user work.
- **`verify.sh`'s Telegram polling probe takes the poll it measures**
  and has read "no bot is being polled" over two answering bots. It is
  informational and should probably go, by this repo's own rule.
- Two context windows are guesses: OpenClaw's model row says 128,000
  and Hermes logs "defaulting to 256,000 tokens". Nobody has confirmed
  either for 5.5 Opus through this gateway.

### Only the owner can do

- delete the two test bots in @BotFather, and revoke the test Google
  account's consent at myaccount.google.com/permissions
- `git fetch` in `~/code/bootstrap` on the Spark from a shell with a
  GitHub key — its files are current, its `origin/main` ref is not
- back up `config/admin-secret`

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
