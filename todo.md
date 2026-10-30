# Unfinished

Open items only. Things that went wrong once and were fixed live in
`docs/gotchas.md`; resolved items live in git history
(`git show 95bba16:todo.md` for the 572-line version this replaced).

---

## 1. The squid-after-reboot fix is unverified

**Open. Fixed in `lima/agents.yaml`, never proven.**

Lima re-runs provision scripts on every boot, and the egress block ended
with an unconditional `systemctl disable --now squid` — which on a reboot
runs *after* `agent-egress.service` has started squid, stopping the proxy a
few seconds into every boot. Confirmed from journal timestamps on
2026-10-28: squid started 07:49:31, Lima stopped it 07:49:34.

Easy to misread as success: iptables stays active so the sandbox remains
fail-closed, and `verify.sh --reboot` reports a blocked domain as `000`
rather than squid's `403`. Every *allowed* destination is equally dead.

The fix makes the disable conditional on `/etc/agent-sandbox/phase` not yet
existing. **Verifying it needs `--rebuild`** — Lima froze a copy of
`agents.yaml` into the instance at creation and re-reads that copy, so the
edit does not affect the current VM.

Next: `./bootstrap.sh --rebuild`, then `verify.sh --reboot`, and confirm a
non-allowed domain returns `403` rather than `000`.

## 2. macOS is stale

**Open, and the repo overstates its portability.**

macOS was the original host and passed 25 checks. Linux (DGX Spark) is
verified from scratch. But everything that raised the Linux number landed
after the Mac run and has never been executed there — including a check that
called an OpenClaw gateway method which no longer exists, meaning the macOS
build was verified with an assertion that would now fail there too.

Treat macOS as unproven until someone runs `./bootstrap.sh --rebuild` on one.

## 3. Snapshots are undocumented

`docs/personality.md` points at `docs/snapshots.md`, which was never
written. Recovery from a broken agent is meant to be a VM snapshot rather
than any backup mechanism of our own — that needs writing down, including
how to take one before `--rebuild` destroys working agents.

## 4. vLLM failover is unverified

`docs/failover.md` describes a fallback to a local model over Tailscale. The
config syntax was never confirmed for any of the three agents and the
tailnet was down when it was written. Spec section 4 tells Pi to skip it
unless `VLLM_BASE_URL` is set, and to write nothing it cannot source from
current documentation. A guessed failover config is worse than none.

## 5. Other providers

Only the Argo path is implemented. The structure generalises — one
translation proxy serving `/v1/messages` and `/v1/chat/completions` — and
`AGENTS.md` sketches what adding one involves. Nobody has tried.
