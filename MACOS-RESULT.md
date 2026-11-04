# macOS build test — result

**Host:** macOS (Darwin 25.6.0), arm64. Lima 2.2.1 via Homebrew.
**Date:** 2026-11-03. **Branch:** `macos-port`.
**Method:** `./bootstrap.sh --rebuild` — the existing October VM and all
generated config destroyed first, so this is a from-scratch build driven
only by the committed documents.

*(Status: in progress — Pi's build is running. Sections below are final
unless marked PENDING.)*

---

## Outcome

PENDING — final `verify.sh --models --reboot` tally.

Pre-Pi baseline, for reference: **24 passed, 6 failed, 10 skipped**. All
six failures were "no agent installed yet" (Hermes SOUL.md missing, etc.).
Every sandbox and egress check passed on `vz` before Pi ran.

### Telegram web-fetch check

PENDING.

---

## What differed from Linux

### Nothing differed — steps that behaved identically

- **Preflight.** Passed clean. The `/dev/kvm` check correctly did not fire;
  it is guarded by `if [ "$(uname -s)" = "Linux" ]` at `bootstrap.sh:58`.
- **Model detection.** `scripts/detect-model-access.sh` worked unmodified,
  finding the host Argo gateway on port 44497 and resolving three models.
- **The host gateway address.** Confirmed, not assumed:

  ```
  $ limactl shell agents -- ip route | grep default
  default via 192.168.5.2 dev eth0 proto dhcp src 192.168.5.15 metric 200
  ```

  Identical to QEMU slirp. `verify.sh` independently passed *"VM gateway
  address matches the guest's default route — 192.168.5.2"*. This
  load-bearing assumption holds under `vz`.
- **The hypervisor.** `limactl list` shows `VMTYPE vz`, `ARCH aarch64`, as
  MACOS-TEST.md predicted. `lima/agents.yaml` pins neither, and both
  correctly followed the host. No change needed.
- **`install-config.sh`.** Pushed config, locked egress to the bootstrap
  allowlist (15 domains), and proved both paths from inside the VM —
  streaming completion direct to the gateway, and `pi.dev → HTTP 200`
  through squid. No macOS divergence.
- **Guest-side code.** As predicted, nothing in-guest is at risk. The
  GNU-isms I found by grep (`sed -i` with no suffix in
  `install-config.sh:130`, `stat -c '%a'` and `timeout` in `verify.sh`) are
  all inside `limactl shell … bash -c` blocks running on Ubuntu, and are
  correct there.

### Timing

- `./bootstrap.sh --dry-run`: ~3s.
- `./bootstrap.sh --rebuild` (to the agents.env stop): ~3s.
- `./bootstrap.sh` (provision + config + egress): **1m 30s**, not the
  ~10 minutes the script predicts — the Ubuntu image was already in
  `~/Library/Caches/lima` from the October run. A genuinely cold Mac would
  be slower.
- Pi's build: PENDING.

### Lima version

`brew install lima` gave **2.2.1** — above the repo's 1.0.0 floor and the
same version the Linux run was last verified on. The README's macOS
instruction is accurate and needs no change.

---

## Repo changes made

PENDING — full list and bounded-ness assessment.

`./scripts/check-frozen.sh` result: PENDING.

---

## Where the documentation failed me

PENDING.

---

## Blocked

PENDING.
