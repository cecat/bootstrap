# TODO

Deferred work, with enough context to pick up cold. Ordered roughly by when
it will bite.

---

## 0. RESOLVED: Hermes endpoint

The gateway is argo-proxy and serves `/v1/chat/completions` as well as
`/v1/messages` -- verified with real completions in both shapes. No shim is
needed. The spec previously claimed otherwise and Pi correctly refused to
configure Hermes as a result. Fixed in `spec/pi-target-state.md`.

What remains: `hermes -z` hangs with no output even against a working
endpoint. Cause unknown; needs someone who knows the tool.

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
host. `CLAUDE.md` shrinks to "if you are an agent reading this, run
`./bootstrap.sh`." Pi stays inside the VM, where the work *is* open-ended:
installing two third-party tools whose docs drift, and writing the idempotent
setup script.

---

## 4. `verify/` suite

**Status:** not written. `CLAUDE.md` Step 8 cannot run.

- `openclaw gateway status`, `openclaw doctor`, `hermes doctor`
- reboot persistence (services come back, egress policy re-applies)
- **negative egress test** — assert a non-allowlisted host is *blocked*. A test
  that only checks the allowed path proves nothing. Note that the agent uid is
  blocked from direct egress by iptables *and* by squid's allowlist; the test
  should distinguish which layer refused, or it will pass for the wrong reason.
- **Do not pick a test host the network itself blocks.** On the build network
  `api.telegram.org` and `tailscale.com` are both unreachable regardless of our
  policy, so using either as the "blocked" case would pass for the wrong reason
  and keep passing if the sandbox were removed entirely. Choose a host that is
  reachable from the host Mac but absent from the allowlist, and assert the
  refusal comes from squid (HTTP 403) or iptables (connect refused).
- model path: `/health`, then a real completion through both API shapes.

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

**Status:** plumbed, never exercised. No tokens have been supplied.

**Telegram is blocked on the build network**, so the channel path cannot be
exercised here even once tokens exist. Tokens for Pat and Trav plus the
allowed user id are filled in, but nothing can confirm them until the VM is on
a network that can reach `api.telegram.org`.

`config/agents.env` has the three fields. `spec/pi-target-state.md` requires Pi
to configure channels **disabled** and stop before enabling them. Nothing has
tested that path, including whether `api.telegram.org` needs adding to the
runtime allowlist (it is present but commented out).

---

## 8. Smaller items

- **`hermes setup` may be interactive.** The spec tells Pi to stop rather than
  drive it with `expect`. If there is no non-interactive path, this blocks the
  Hermes half of the build and needs a different approach.
- **Other providers**: `~/.gemini/settings.json`, `~/.pi/agent/models.json` and
  local Ollama are worth adding to the picker once MAG proves the pattern.
- **`limactl validate` does not catch everything.** It passed a config whose
  allowlist made squid refuse to start. The allowlist is validated in the guest
  by `agent-egress`; there is no host-side check before a VM exists.
