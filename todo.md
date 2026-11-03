# Unfinished

Open items only. Things that went wrong once and were fixed live in
`docs/gotchas.md`; resolved items live in git history
(`git show 95bba16:todo.md` for the 572-line version this replaced).

---

## 1. macOS is stale

**Open, and the repo overstates its portability.**

macOS was the original host and passed 25 checks. Linux (DGX Spark) is
verified from scratch. But everything that raised the Linux number landed
after the Mac run and has never been executed there — including a check that
called an OpenClaw gateway method which no longer exists, meaning the macOS
build was verified with an assertion that would now fail there too.

Treat macOS as unproven until someone runs `./bootstrap.sh --rebuild` on one.

For that run, reuse the harness the Linux rebuilds used: a fresh-context
agent, no repo fixes, every gap recorded rather than patched. It is at
`archive/REBUILD-TEST.md` locally and in git history at `9758e12`
(`archive/` is not committed). Its header says what to re-check first.

## 2. vLLM failover is unverified

`docs/failover.md` describes a fallback to a local model over Tailscale. The
config syntax was never confirmed for any of the three agents and the
tailnet was down when it was written. Spec section 4 tells Pi to skip it
unless `VLLM_BASE_URL` is set, and to write nothing it cannot source from
current documentation. A guessed failover config is worse than none.

## 3. Other providers

Only the Argo path is implemented. The structure generalises — one
translation proxy serving `/v1/messages` and `/v1/chat/completions` — and
`AGENTS.md` sketches what adding one involves. Nobody has tried.
