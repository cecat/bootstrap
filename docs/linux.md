# Running this on Linux

**Audience: the coding agent.** Read `AGENTS.md` first. This is only what
a Linux host needs that the top-level README does not say.

Verified on a DGX Spark: aarch64, Ubuntu 24.04 (DGX OS), Lima 2.2.1,
QEMU 8.2.2 with KVM. `lima/agents.yaml` pins neither `vmType` nor `arch`,
so an x86_64 host gets the amd64 image and should work the same way; that
has not been run.

## Before `./bootstrap.sh`

`bootstrap.sh` checks all of this and says which is missing. It installs
none of it, because every one needs `sudo` on the host, which is the
user's to give.

**Lima, from the release binary.** Distro packages lag the required
1.0.0: <https://github.com/lima-vm/lima/releases>.

**QEMU.**

```sh
sudo apt-get install -y qemu-system-arm qemu-utils qemu-efi-aarch64   # arm64
sudo apt-get install -y qemu-system-x86 qemu-utils ovmf               # x86_64
```

**KVM, through the `kvm` group.** Without KVM, QEMU falls back to
software emulation and provisioning takes hours, which reads as a hang.

```sh
sudo usermod -aG kvm "$USER"
```

No new login is needed afterwards: when the shell predates the group,
`bootstrap.sh` re-runs itself under `sg kvm`. Do **not** grant access with
`setfacl` — udev recreates `/dev/kvm` whenever the qemu packages change
and silently drops the ACL, so it works until minutes after you confirmed
it.

`verify.sh --reboot` starts the VM again and needs the group too. From a
shell that still predates it: `sg kvm -c './verify/verify.sh --reboot'`.

## The model gateway must be up, and stay up

The agents reach Argo through a gateway on this host's loopback, via
Lima's host address (`192.168.5.2`). That gateway is not part of this
repo. If it stops — a dropped SSH tunnel, a host reboot — both agents go
quiet with no error on Telegram. `./verify/verify.sh --models` tells you
in one run; a 200 from `/health` does not.

Detection is fresh on every host. Never copy `config/` from another
machine.

## Things that look wrong here and are not

| What you see | What it is |
|---|---|
| `apt-get update` fails the NVIDIA repos with a certificate error | A DNS filter resolving them to a block page. This build takes nothing from those repos. |
| Tailscale fails to install in the VM | Some networks block `tailscale.com`. Non-fatal by design; only the unverified vLLM fallback wants it. |
| Provisioning takes two minutes, or twelve | Both are fine **if KVM is active**. If it looks hung, check `/dev/kvm` before anything else. |

## Memory

The VM takes 8 GiB. On a Spark that is unified memory, taken from
whatever is on the GPU: a vLLM server holding most of the machine leaves
too little for a second VM, though one is fine. Do not give the VM GPU
access; none is configured and none is wanted.

## Work inside tmux

A Pi build is thirty minutes and a dropped SSH session kills it. See
`docs/tmux.md`.
