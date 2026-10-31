# Rebuild test result — 2026-10-31

A fresh agent with no context drove a clean build from the committed spec,
following `REBUILD-TEST.md`. Kept as the baseline the next run is measured
against; delete once a later run supersedes it.

**36 passed, 1 failed, 4 skipped** (`verify.sh --models`), and **zero
interventions during the run** — no messages to Pi, no retries, no repo
edits. The previous run needed three interventions and a mid-run repo fix.
Bootstrap and the `agents.env` fill were done before handoff, so the
honest count is 2, both before the agent started.

Pi's build took 28.5 min, `finish-build.sh` ~2 min.

## What it found

**The 15-minute turn timeout killed a healthy build.** Pi was writing the
OpenClaw Telegram allowlist, 8,052 events into the log, when the
wall-clock limit fired. `pi-session.sh` then called it "no work produced"
and auto-retried — the path its own comments say must never run on a turn
that acted. It recovered only because Pi kept its session.

Fixed in `8970c05`: silence, not elapsed time, is now the hang signal.

**Hermes answered no completion**, with `HTTP 401: Incorrect API key
provided: catlett` — the ANL username reaching OpenAI directly instead of
the local translation proxy. Pi fixed `configure_hermes` in `setup.sh`;
`verify.sh --models` now passes.

**Seven stale or self-contradictory documents.** All text, no gaps — the
instructions themselves were sufficient and the agent never had to guess.
Addressed in the cleanup pass that follows this commit.

## What it could not test

The Telegram web-fetch check never ran: `AskUserQuestion` is unavailable
in a subagent context. That is the check that caught the previous run's
hidden failure — every automated check green while an agent could not
reach the web — so it still needs a human to message both bots. Run by
hand afterwards: LuoJi fetched a page cleanly; Hermes answered once its
401 was fixed.

## Still unproven

`verify.sh --reboot` has never been run. `scripts/diag-stream.sh` is
blocked by the Claude Code permission classifier under both invocation
forms.
