# Handoff: running this on a DGX Spark (or any Linux host)

**Audience: the coding agent running on the Spark.** Read `AGENTS.md` first
(`CLAUDE.md` is a symlink to it) —
it is the build procedure and it still applies. This file is only the delta
between the host it was built on and the host you are on.

---

## What you are inheriting

This repo was built and verified end to end on a **macOS arm64 laptop** using
Lima with the `vz` backend. The full chain worked there:

| | Status on macOS |
|---|---|
| VM provisions (Node 22, squid, iptables, Pi) | verified |
| Host model access detected from `~/.claude/settings*.json` | verified |
| VM reaches the host's model gateway at `192.168.5.2` | verified |
| Egress lockdown (squid allowlist + iptables uid filter) | verified, incl. negative test |
| Pi builds OpenClaw + Hermes from `spec/pi-target-state.md` | verified, both answered a real completion |
| `setup.sh` idempotent over two runs | verified |

**Update — 2026-10-20: the full chain has now been run on a DGX Spark.**
(aarch64, Ubuntu 24.04, DGX OS, Lima 2.2.1, QEMU 8.2.2 with KVM.) The VM
provisioned in about two minutes, `192.168.5.2` carried over to QEMU slirp
unchanged, egress lockdown held including the negative tests, and Pi built
both agents. `verify/verify.sh --models` reports **27 passed, 0 failed**.
Tailscale installed cleanly here, unlike on the macOS build network.

What is still unproven on Linux: `--reboot` persistence, and the Telegram
channel path (nothing has configured a channel yet on any host). The traps
that cost time on this run are in sections 1 and 5 below — read them.

---

## 1. The hypervisor: use QEMU

`lima/agents.yaml` no longer pins `vmType`. **Do not set it to `vz`** — that
is Apple Virtualization.framework and does not exist on Linux. On Linux, Lima
defaults to `qemu`, which is what you want. Leave it unset and let Lima
choose.

`arch` is also unset, so the guest follows the host. The images block lists
both `aarch64` and `x86_64` Ubuntu 24.04 cloud images; Lima picks the matching
one. On the Spark (Grace/Neoverse, arm64) that is the arm64 image.

### KVM is not optional

QEMU without KVM falls back to TCG software emulation. The VM will still
boot — and provisioning will take hours instead of ten minutes, which reads
as a hang, not as a misconfiguration. **Check this before you start the VM:**

```sh
ls -l /dev/kvm                       # must exist
[ -r /dev/kvm ] && [ -w /dev/kvm ] && echo "KVM usable" || echo "KVM NOT usable"
id -nG | tr ' ' '\n' | grep -qx kvm && echo "in kvm group" || echo "NOT in kvm group"
```

If `/dev/kvm` exists but is not readable/writable by you:

```sh
sudo usermod -aG kvm "$USER"         # then log out and back in, or: newgrp kvm
```

**Do not rely on `setfacl` for this.** Granting yourself an ACL
(`sudo setfacl -m u:$USER:rw /dev/kvm`) looks like the way to avoid logging
out, and it works — until udev recreates the device node, which installing
the qemu packages does. The ACL is silently dropped, including any
pre-existing entries, and QEMU starts failing with `Could not access KVM
kernel module: Permission denied` some minutes after you confirmed it
working. Group membership is the durable fix.

For an **already-running shell** that cannot log out — a coding agent's
session, for instance — prefix the commands instead:

```sh
sg kvm -c 'limactl start --name=agents lima/agents.yaml'
sg kvm -c 'limactl shell agents -- ...'
```

`sg` grants the group immediately and needs no password. Verified on the
Spark: this is how the whole build was driven.

If `/dev/kvm` does not exist at all, stop and tell the user. Do not proceed
into TCG emulation and do not quietly reduce `cpus`/`memory` to compensate.

### Packages Lima needs on Linux

Homebrew is a macOS assumption. On DGX OS / Ubuntu:

```sh
sudo apt-get update
sudo apt-get install -y qemu-system-arm qemu-utils qemu-efi-aarch64 jq openssl
# x86_64 host instead: qemu-system-x86 qemu-utils ovmf jq openssl
```

Lima itself is usually not in the distro repos at a useful version — take the
release binary from <https://github.com/lima-vm/lima/releases> rather than
`apt-get install lima`. Verify `limactl --version` is **1.0.0 or newer**;
`lima/agents.yaml` declares `minimumLimaVersion: "1.0.0"`.

### Sizing on a Spark

The Spark's 128 GB is **unified** memory — whatever the VM takes is taken away
from anything running on the GPU. The committed defaults are deliberately
modest:

```yaml
cpus: 4
memory: "8GiB"
disk: "60GiB"
```

8 GiB is enough for Pi plus both gateways. Raise `memory` to 16 GiB only if
you actually observe pressure. **Do not** give the VM GPU access: there is no
GPU passthrough configured and none is wanted. vLLM, if used, stays on the
host in Docker with the NVIDIA runtime, and the VM reaches it over the network
as an ordinary allowlisted endpoint (see `docs/failover.md`).

---

## 2. The one thing most likely to break: `192.168.5.2`

The VM reaches the host's model gateway at `192.168.5.2`, Lima's user-mode
networking host address. This is the single host-specific constant in the
build, and it is wired into three places:

- `scripts/detect-model-access.sh` — `LIMA_HOST_GATEWAY`, overridable by env
- `lima/agents.yaml` — the `NO_PROXY` list in `.profile`
- the iptables ACCEPT rule written from `/etc/agent-sandbox/model-gateway`

Lima uses the same `192.168.5.0/24` user-mode subnet under QEMU slirp as under
`vz`, so this *should* carry over unchanged. **Verify it rather than trusting
it**, right after the VM comes up and before running `install-config.sh`:

```sh
# 1. What does the guest think the host is?
limactl shell agents -- ip route | grep default        # expect via 192.168.5.2

# 2. Can the guest actually reach a host-side service on that address?
#    Run this on the HOST, in another terminal:
python3 -m http.server 9999 --bind 127.0.0.1
#    then, from the guest:
limactl shell agents -- curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://192.168.5.2:9999
```

A `200` means the path works and you can proceed. Note what that second test
proves: slirp forwards the guest's connection to `192.168.5.2` into a service
bound to the **host's loopback**. That is the mechanism the whole model path
depends on — an SSH tunnel or a local argo-proxy listening on `127.0.0.1`.

If the gateway address differs, override it rather than editing files:

```sh
LIMA_HOST_GATEWAY=<addr> ./scripts/detect-model-access.sh
```

and fix the `NO_PROXY` line in `lima/agents.yaml` before creating the VM —
remember that editing the YAML after creation does nothing (see below).

---

## 3. Model access on the Spark is a fresh detection, not a copy

Do **not** carry `config/model-access.env` over from the Mac. It is gitignored
for this reason. `scripts/detect-model-access.sh` reads the *Spark's* live
`ANTHROPIC_BASE_URL` and its own `~/.claude/settings*.json`, and the answer
will legitimately differ:

- If the Spark sits on the ANL network, the endpoint may be a **real host**
  rather than a `127.0.0.1` tunnel. The script handles both — a loopback
  endpoint is classified as a bridgeable gateway and rewritten to
  `192.168.5.2:<port>`; a routable host is passed through as-is and the VM
  reaches it through squid.
- The credential is the **ANL username** (argo-proxy is username-passthrough),
  resolved via `apiKeyHelper` and never printed.

Run `./scripts/detect-model-access.sh --dry-run`, show the user the summary,
and get confirmation before writing it. This is Step 1 of `AGENTS.md` and it
is the step everything downstream depends on.

---

## 4. Things that bit the previous run — don't rediscover them

**Editing `lima/agents.yaml` does not change an existing VM.** Lima copies the
config into the instance at creation and re-reads *that* copy from
`~/.lima/agents/lima.yaml`. Provision scripts do re-run on every boot, but
from the frozen copy — so your edit is silently ignored and you debug stale
code. This cost two debugging cycles on the Mac. To pick up a change:

```sh
limactl delete -f agents && limactl start --name=agents lima/agents.yaml
```

Cheap before Pi has built anything; destroys the agents afterwards.

**The agent uid is not in the ≥1000 range.** Lima gives the guest user the
host's uid. The egress lockdown keys off that uid, and guessing wrong disables
the sandbox *silently*. Provisioning uses Lima's `{{.User}}` and fails loudly
if it cannot resolve. On Linux the host uid is typically 1000 and the naive
guess would have worked — which is exactly why you should not reintroduce it.

**squid: a dotted entry subsumes bare hosts, and listing both is fatal.**
`.npmjs.org` already covers `registry.npmjs.org`; listing both makes squid
refuse to start. `agent-egress` validates with `squid -k parse` and restores
the previous allowlist on failure, so a bad list is an error message, not an
outage.

**Node ignores `HTTP_PROXY` by default.** `NODE_USE_ENV_PROXY=1` is exported
in `.profile` for this reason. Without it every Node request dies
`EHOSTUNREACH` against the lockdown. Experimental in Node 22, stable in 24+.

**`/health` and `/v1/models` are false greens.** They answer 200 from local
state with a dead upstream. Only a real completion proves the model path. This
is written into `spec/pi-target-state.md` as a hard rule because Pi over-claimed
on exactly this during the Mac run.

**Negative egress tests need the right target.** For HTTPS, squid denies
`CONNECT` and curl reports `000` — indistinguishable from a plain network
failure. Use **plain HTTP** (`http://example.com`) to get a clean `403` from
squid. And do not pick a host the network itself blocks: on the ANL network
`api.telegram.org` and `tailscale.com` are unreachable regardless of policy,
so "blocked" would prove nothing.

---

## 5. Expected deltas, and what to do about them

| Likely difference | What to do |
|---|---|
| Tailscale install fails (network blocks `tailscale.com`) | Non-fatal by design; a skip marker is written. Only affects the vLLM fallback. |
| Provisioning slower or faster than ~10 min | Fine either way **if KVM is active**. If it looks hung, re-check `/dev/kvm` before anything else. |
| `apt-get` mirrors differ on DGX OS | Should be transparent; the bootstrap allowlist covers Ubuntu/Debian/nodesource/npm. |
| `apt-get update` fails the NVIDIA repos with "Certificate verification failed" | Seen on the Spark: NextDNS resolves `repo.download.nvidia.com` and friends to a blockpage, so the TLS name does not match. Harmless **for this build** — qemu and everything else come from `ports.ubuntu.com`, which succeeds. Confirm with `apt-cache policy qemu-system-arm` before dismissing it. It will block CUDA/driver updates, which is a real but separate problem. |
| The host gateway is not `192.168.5.2` | Section 2 above. |
| `limactl copy` behaves differently | It is the only host→guest channel (`mounts: []` is the isolation boundary). If it fails, do not add a mount — fix the copy. |

If you hit something not in this table, **stop and tell the user** rather than
improvising. `AGENTS.md` says the same thing about unwritten steps, and it is
the house rule: this repo prefers a halt with a clear message over a plausible
workaround.

---

## 6. Order of work

Follow `AGENTS.md` Steps 0–9 unchanged, with these insertions:

1. **Before Step 0** — the KVM and packages checks in Section 1 above.
2. **Step 1** — fresh detection (Section 3). Do not reuse the Mac's config.
3. **Between Step 2 and Step 5** — the `192.168.5.2` reachability test
   (Section 2), while the VM is still provisioning.
4. **Step 9 is a hard checkpoint.** Summarize and stop. Do not enable Telegram
   or any other channel before the user says so, and never before verification
   passes.

The safety rules in `AGENTS.md` are not advisory and they are not relaxed by
being on a different host: never ask for a secret in conversation, never pipe
an installer into a shell, never commit anything from `config/`, never leave
`agent-egress unlock` in effect at the end of a session.
