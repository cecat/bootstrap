# TODO

Deferred work, with enough context to pick up cold. Ordered roughly by when
it will bite.

---

## 00. Re-verify on macOS — the Mac run is now stale

**Status: open, and the repo currently overstates its own portability.**

macOS was the original build host and passed 25 checks. Linux (DGX Spark) was
verified from scratch on 2026-10-21 at **29 pass, 0 fail**. But everything
that made that number go up landed *after* the Mac run, and none of it has
been executed there:

- `verify/verify.sh` — two added checks (gateway proxy env; secrets audit
  `plaintext=0`/`unresolved=0`) and two fixed false negatives. One of those
  was a call to `openclaw gateway call cli.chat.one-shot`, a method that no
  longer exists in OpenClaw 2026.10.5 — so the **macOS build was verified
  with a check that would now fail there too**.
- `scripts/install-config.sh` — proxied-destination gate, delimited and
  rewritten `~/.profile` block, allowlist drift warning.
- `spec/pi-target-state.md` — `VM_BASE_URL`, secrets mechanism, proxy
  drop-in, channel syntax, hard rules 5 (extended) and 6.
- `config/allowlist-*.example` — `api.telegram.org` in both phases.

Two things to watch when someone does run it:

1. **`VM_BASE_URL` vs `UPSTREAM_BASE_URL` may be invisible on a Mac.** If the
   host reaches Argo at a routable address rather than a `127.0.0.1` tunnel,
   the two variables hold the same string and the bug that halted Pi on
   Linux cannot reproduce. Do not read "it worked" as "the fix was
   unnecessary".
2. **The systemd drop-in is guest-side**, and the guest is Ubuntu under
   `vz` just as under `qemu`, so it should carry over. Should.

Until someone runs current `main` end to end on macOS, say "Linux verified
2026-10-21; macOS verified at an earlier commit and not re-run" rather than
"works on both". `AGENTS.md` and `README.md` both carry that wording now.

---

## 0A. Hermes Telegram — spec corrected 2026-10-26, NOT yet proven by Pi

The spec actively prevented Pi from setting up Hermes' Telegram channel. It
said, in section 2: *"No systemd service, and this is correct... Do not
install it."* The reasoning was that a disabled channel has nothing to
serve, which conflated **installing the machinery** with **enabling the
channel**. OpenClaw does the former while the latter stays `false`; Hermes
should too.

Because the service never existed, three real requirements went undiscovered
through four builds. All are now in the spec:

1. **`hermes gateway install` is required** when Telegram tokens are present.
2. **`telegram-platform` ships installed but disabled.** `hermes plugins
   list` shows `not enabled`; it needs `hermes plugins enable
   telegram-platform`. Without it: `No adapter available for telegram`.
3. **Its Python dependency comes from pypi.org**, which is allowlisted in
   **bootstrap only**. So first start must happen during the Pi phase. Later
   it fails `tunnel error: unsuccessful` / `Failed to fetch:
   https://pypi.org/simple/...`, which reads as a network fault rather than
   an egress-phase problem.

Also corrected: the spec claimed *"there is no non-interactive `gateway
setup`"*. False — `hermes setup --non-interactive` and `hermes setup
gateway` both exist. That claim was written from one `--help` glance and is
exactly the unverified assertion rule 5 forbids.

`verify.sh` now keys the gateway check on `TELEGRAM_BOT_TOKEN` in
`~/.hermes/.env` (it previously keyed on `channel_directory.json`, which
Hermes never writes, so the check passed unconditionally) and asserts the
adapter actually connected, from the journal.

**Status: unproven.** These facts were established by hand on a VM that is
now contaminated by those manual fixes. Nothing here counts until Pi
reproduces it from the committed spec on a VM built from scratch.

## 0aa. Idempotence was self-reported and wrong — now checked

`verify.sh --idempotence` re-runs Pi's `setup.sh` and asserts the second run
changes nothing. Added 2026-10-21 after Pi reported "idempotence proven" on
a script where **10 steps acted on every run**.

Two causes, both of which leave a script *looking* guarded:

- **A guard that can never match.** `grep -q '"botToken".*"source":"env"'`
  against pretty-printed JSON — the two keys are on different lines, so the
  pattern never hits and the step runs forever. Use
  `jq -e '.channels.telegram.botToken.source == "env"'`.
- **No guard at all.** The secrets migration ran unconditionally.

Worth knowing how this presented: Pi *noticed* the second run was dirty and
tried to fix it, producing nine run logs with escalating names
(`run2-idempotent`, `run-final`, `run-final-idempotent`,
`run-idempotent-final`, `run-final2`) before shipping anyway and reporting
success. So the symptom to watch for is not silence — it is a flurry of
retries followed by a confident summary.

The check is opt-in (`--idempotence`, included in `--all`) because it
re-runs a real script against a live VM, and it requires the bootstrap
allowlist since `setup.sh` refuses to run under `runtime`.

## 0a. Agent naming and SOUL seeds — found 2026-10-21, spec fixed, needs a run

Three defects in the same area, all caught only because the build was being
taken to production. `verify.sh` now fails on each; none had any check
before, which is why two clean-looking runs shipped them.

1. **The configured agent name was never applied.** `openclaw onboard`
   creates an agent called `main` and does not read `OPENCLAW_AGENT_NAME`.
   Pi's `setup.sh` logged "Creating OpenClaw agent 'LuoJi'", ran
   `openclaw agents list`, logged "agent created" — and renamed nothing.
2. **The seed landed in an unused directory.** The spec hardcoded
   `~/.openclaw/agents/default/SOUL.md`, but the live agent was `main`, so
   `agents/default/` held a correct seed that nothing reads and
   `agents/main/` had none.
3. **Hermes kept the vendor persona.** Its installer writes its own
   `SOUL.md` with the stock Nous Research text, so Pi's
   `[ -f ] && skip "already exists"` guard skipped — leaving an agent that
   has never heard of Gandalf, reported as seeded.

Spec changes: rule 6 now says a log line claiming an action over code that
does not perform it is the same offence as a placeholder; the OpenClaw
section requires reading the name back from `openclaw agents list`; the
seed path is `<live agent id>`, not `default`; and the seed guard is on
**content** (`grep -q "You are <NAME>"`) rather than existence, so a vendor
default is replaced while a user-edited personality is preserved.

Unproven until Pi runs against the corrected spec.

## 0. RESOLVED: Hermes endpoint

The gateway is argo-proxy and serves `/v1/chat/completions` as well as
`/v1/messages` -- verified with real completions in both shapes. No shim is
needed. The spec previously claimed otherwise and Pi correctly refused to
configure Hermes as a result. Fixed in `spec/pi-target-state.md`.

~~What remains: `hermes -z` hangs with no output even against a working
endpoint.~~ **RESOLVED on the Linux build (2026-10-20).** `hermes -z` returns
promptly against the argo-proxy gateway; `verify.sh --models` passes it. The
hang was specific to the earlier macOS environment and did not reproduce.

## 0b. (superseded) Hermes needs an OpenAI-compatible endpoint

**Status:** open, and the one real gap in the Argo path.

The VM no longer runs a model gateway. The ground rule is that the host
already has a working path to models and the VM is configured to use it; for
Argo that path is `https://apps.inside.anl.gov/argoapi`, which speaks the
**Anthropic** shape only.

Pi and OpenClaw are fine. Hermes expects OpenAI-compatible. Options, none
chosen:

- point Hermes at a host-side translator the user already runs, reached over
  Lima's host gateway (`192.168.5.2`) -- costs one hole in the egress policy
- switch the whole VM to MAG, which serves both shapes natively (item 1)
- run Hermes against a different provider entirely
- drop Hermes for now and ship the OpenClaw half

`spec/pi-target-state.md` tells Pi to report precisely what Hermes needs
rather than invent a shim.

## 1. MAG / AmSC provider support

**Status:** detected, not implemented. `bootstrap.sh` should offer it in the
picker and refuse with a clear message if chosen.

MAG (`https://mag.genesis.americansciencecloud.org`) is a second model path
already in use on the build machine, and it is more capable than Argo in one
useful way: **it serves both API shapes natively.**

| | Endpoint | Header | Auth |
|---|---|---|---|
| Anthropic | `…americansciencecloud.org` | `X-AmSC-MAG-Provider: amazon` | `ANTHROPIC_AUTH_TOKEN` |
| OpenAI | `…americansciencecloud.org/v1` | `X-AmSC-MAG-Provider: openai` | env var named by Codex's `env_key` |

Found in `~/.codex/config.toml` (`[model_providers.mag]`, `wire_api = "responses"`)
and in a `claude-amsc` shell function in `~/.zshrc`.

What implementing it requires:

- **Custom headers must survive into the VM.** `X-AmSC-MAG-Provider` selects the
  backend; without it the endpoint does not work. The profile written by
  detection currently has no field for headers — add one.
- **A different auth kind.** Argo authenticates with an ANL username and network
  position; MAG uses a bearer token. Detection must record the *kind* of
  credential, not just a string. This also trips the spend-cap warning that
  Argo correctly skips.
- **Possibly no translation proxy at all.** Because MAG already speaks both
  shapes, Pi/OpenClaw could use the Anthropic endpoint and Hermes the OpenAI
  one directly. That would remove argo-proxy — and with it the separate
  `argoproxy` Linux user and its egress exemption — from the MAG path entirely.
  Worth doing: it is strictly simpler than the Argo path.
- **Allowlist entry** for `mag.genesis.americansciencecloud.org`.

**Do not** parse `~/.zshrc` to find this. Shell functions are not a config
format. Detection reads `~/.codex/config.toml`; anything else goes through the
picker's "enter manually" option.

---

## 2. Multi-source detection picker

**Status:** designed, not built. `detect-model-access.sh` currently finds one
endpoint and proceeds, which is wrong on any machine with more than one.

Probe a **fixed list** of locations — never crawl `$HOME` — and present every
candidate for the user to choose:

- all `~/.claude/settings*.json` (there may be several; the active one is
  chosen with `claude --settings`, so no single file is authoritative)
- `~/.codex/config.toml`
- `~/.config/argoproxy/config.yaml`, `~/.argoproxy/config.yaml`
- `~/.pi/agent/models.json`
- `~/.gemini/settings.json`
- the live environment
- "enter manually"

Flag loopback endpoints (e.g. `settings.argo-tunnel.json` → `127.0.0.1:44497`)
as unreachable from the VM rather than offering them silently.

---

## 3. Collapse the host side into `bootstrap.sh`

**Status:** agreed, not built.

The host-side steps are nearly all deterministic — install Lima, create the VM,
generate config, push it, launch Pi. Driving them with a coding agent adds
variance without adding judgment, and already caused one real problem
(improvised questions and an invented secret-handling policy).

Target: `git clone && ./bootstrap.sh`. No Claude Code, no Codex, no Pi on the
host. `AGENTS.md` shrinks to "if you are an agent reading this, run
`./bootstrap.sh`." Pi stays inside the VM, where the work *is* open-ended:
installing two third-party tools whose docs drift, and writing the idempotent
setup script.

---

## 4. `verify/` suite

**Status:** written as `verify/verify.sh`. 25 checks pass against the macOS
build; `--models` and `--reboot` are implemented but have not themselves been
exercised yet.

Covered: substrate (Node, Pi, agent uid, linger), config permissions, egress
phase/squid/lockdown/allowlist, the negative egress tests, gateway units and
their loopback-only binding, SOUL.md presence, and a channels-are-off
assertion. `--models` sends one real completion per agent; `--reboot` checks
that the policy and the gateways come back.

The negative test resolved the concern recorded here earlier: it uses
`http://example.com` over **plain HTTP**, where squid returns a clean `403`.
A 403 is self-validating — it can only come from squid — so it proves both
that the proxy is up and that it is denying, with no separate positive
control needed. Over HTTPS squid denies `CONNECT` and curl reports `000`,
indistinguishable from the network being down; and `api.telegram.org` /
`tailscale.com` are blocked by the build network itself, so neither is usable
as the blocked case. The iptables leg does need a control, and gets one: the
same request is re-run as root and must **succeed**, which is what rules out
"the VM simply has no network".

**Update 2026-10-20 (Linux build): 27 pass, 0 fail with `--models`.** Two
false negatives were found and fixed in the process, both worth remembering
because each made a *correct* build look broken:

- `--models` called `openclaw gateway call cli.chat.one-shot`, a method
  removed in OpenClaw 2026.10.5. It now uses `openclaw agent --model ...
  --message ...` and reads the model id out of the provider config.
- The Gateways section required `hermes-gateway.service` unconditionally.
  Hermes' gateway serves *messaging channels* only, so a spec-compliant
  channels-off build never installs it. The check now requires it only when
  `~/.hermes/channel_directory.json` exists. Same fix in the `--reboot` leg.

Remaining:

- Exercise `--reboot` at least once.
- Fold in `openclaw doctor` / `hermes doctor`. Not included yet because both
  report a confusing false negative — they probe `api.anthropic.com`, which
  is deliberately not on the allowlist, rather than the configured endpoint.
  A check that needs a paragraph of explanation to read as green is worse
  than no check.
- Verify the Telegram channel path once a network that permits it is
  available.

---

## 5. vLLM failover over Tailscale

**Status:** unverified, and currently un-testable. See `docs/failover.md`.

`tailscale.com` is blocked on the build network (`SSL_ERROR_SYSCALL`), so the
installer fails and the VM records a skip marker. The host's own `tailscaled`
is logged out for the same reason. Nothing about the Spark path has been run.

Also unresolved: squid allows port 8000 for vLLM but restricts CONNECT to 443,
so **HTTPS on port 8000 would be refused**. Add the port to `SSL_ports` if the
Spark serves TLS there. Left unguessed because the Spark's setup is unknown.

---

## 6. Snapshots and porting docs

**Status:** not written. `docs/snapshots.md` is referenced by
`docs/personality.md` and does not exist.

`limactl snapshot` and `limactl clone` both exist in Lima 2.2.1, but **snapshot
support under `vmType: vz` is unverified** — it was historically QEMU-only.
Test before documenting; if it does not work under `vz`, `limactl clone` is the
fallback and the doc should say so plainly.

Also needed: moving the same spec to the DGX Spark or a VPS.

---

## 7. Telegram channels

**Status: NOT plumbed. This item was previously overstated.**

On the 2026-10-20 Linux build, tokens *were* supplied in `config/agents.env`
and Pi reported "Telegram channels: configured but DISABLED". That claim was
false. Its `setup.sh` contains two functions,
`configure_openclaw_telegram` and `configure_hermes_telegram`, whose active
branch logs `"Telegram configuration syntax needs to be determined from
OpenClaw docs"` and does nothing. Verified after the fact: `openclaw.json`
has no `channels` key at all, and `~/.hermes/channel_directory.json` does not
exist. The human noticed only because neither bot answered.

`spec/pi-target-state.md` has since been hardened — a new hard rule 6 forbids
leaving a placeholder and reporting it as done, and the channels section now
requires reading back the created state.

**Update 2026-10-21 (clean rebuild):** Pi configured both channels from the
spec unaided — OpenClaw via `channels add` with the token migrated to a
SecretRef, `dmPolicy: allowlist` and `allowFrom` set; Hermes via its
`~/.hermes/.env`. Both left **disabled**, correctly. What it did *not* do is
validate the tokens: no `getMe` call anywhere in `setup.sh`, and it reported
`api.telegram.org` as blocked when the domain was in the active allowlist and
reachable (302). Rule 5 now covers unverified *negative* claims, and the
channels section requires quoting `getMe` output per token.

**The syntax is now known and written into the spec.** Three things blocked
this, all found by hand afterwards:

1. **The command is `openclaw channels`, plural.** Pi tried `openclaw
   channel`, which does not exist, and gave up. `openclaw channels add
   --channel telegram --token <tok> --agent <name>` is the documented
   non-interactive form.
2. **`api.telegram.org` ships commented out of the runtime allowlist**, so
   every Telegram call failed `403 CONNECT tunnel failed` at squid. Enabling
   it is a deliberate human act (it is what lets the agents talk to the
   outside world) and is correctly not Pi's to do.
3. **One of the two supplied bot tokens was invalid** — `getMe` returned
   `Unauthorized`. The spec now tells Pi to validate each token with `getMe`
   and report, which separates "wrong config" from "wrong credential" in one
   call.

Also worth recording: **this network can reach `api.telegram.org`** (302 from
both host and VM). The note above about Telegram being blocked was true of
the macOS build network only.

**Telegram is blocked on the build network**, so the channel path cannot be
exercised here even once tokens exist. Tokens for Pat and Trav plus the
allowed user id are filled in, but nothing can confirm them until the VM is on
a network that can reach `api.telegram.org`.

`config/agents.env` has the three fields. `spec/pi-target-state.md` requires Pi
to configure channels **disabled** and stop before enabling them. Nothing has
tested that path, including whether `api.telegram.org` needs adding to the
runtime allowlist (it is present but commented out).

---

## 7b. Secrets hygiene — fixed, but the lesson generalizes

`openclaw onboard` writes the gateway token and the provider apiKey into
`openclaw.json` **as plaintext**, and the 2026-10-20 run left them there while
reporting compliance with rule 4. `openclaw secrets audit` caught it:
`plaintext=2`.

Fixed on that build and written into the spec: a systemd drop-in supplies the
env vars to the service, `openclaw secrets apply --from <plan>` rewrites both
fields as `{source: "env"}` SecretRefs, and `install-config.sh` now exports
`CREDENTIAL` and `OPENCLAW_GATEWAY_TOKEN` into `~/.profile` so the CLI works
in an interactive shell. `openclaw secrets audit --check` now reports
`plaintext=0`.

The generalizable point: **a rule stated without a mechanism and a check gets
reported as satisfied without being satisfied.** Rule 4 had said "use env
SecretRefs" since the beginning. Any future provider added to this repo needs
the same treatment — the concrete command, plus an audit whose output must be
quoted.

Two follow-ons from the same root, both now fixed in `install-config.sh`:

- **Every SecretRef key must be exported in `~/.profile`, not just the
  gateway token.** Missing the channel tokens gave `unresolved=1`, which is
  invisible from the service side — the gateway resolves refs from its own
  `EnvironmentFile` and stays perfectly healthy while the CLI refuses to run.
  `verify.sh` now asserts `plaintext=0` *and* `unresolved=0`, deliberately
  from a plain login shell, since sourcing `agents.env` first masks it.
- **The `.profile` block is now delimited and rewritten in place.** It used
  to be appended once behind a `grep -q ARGO_CREDENTIAL` guard, so any later
  addition never reached an already-provisioned VM. Upgrades matter here:
  `install-config.sh` is re-run whenever config changes.

## 8. Smaller items

- **`hermes setup` may be interactive.** The spec tells Pi to stop rather than
  drive it with `expect`. If there is no non-interactive path, this blocks the
  Hermes half of the build and needs a different approach.
- **Other providers**: `~/.gemini/settings.json`, `~/.pi/agent/models.json` and
  local Ollama are worth adding to the picker once MAG proves the pattern.
- **`limactl validate` does not catch everything.** It passed a config whose
  allowlist made squid refuse to start. The allowlist is validated in the guest
  by `agent-egress`; there is no host-side check before a VM exists.
