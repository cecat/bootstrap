# Rebuild test — instructions for a fresh coding agent

You are running an experiment, not a build. Read this whole file first.

**The question being tested:** this repo was cut from ~5,300 lines to
~4,500, including a spec that went from 749 lines to 248. Does a build
driven from the shorter documents still work, from nothing, unattended?

The previous build reached 36 passed / 0 failed — but not in one pass. It
needed three supervisor interventions and a repo fix mid-run, so it does
not answer the question. This run is the real test.

**You are the instrument, not the engineer.** Your value here is that you
have no prior context. Everything you find confusing, ambiguous or missing
is a finding — it is exactly what the next real user will hit. If you patch
over a gap using your own judgment, the gap becomes invisible and the
experiment is wasted.

---

## Hard rules for this run

1. **Do not fix the repo.** No edits to any file: not the spec, not
   `AGENTS.md`, not the scripts, not `verify.sh`. If something is wrong,
   write it down and keep going.

2. **Do not theorise about causes.** If something fails, report the symptom
   and the exact command output. Do not form hypotheses about why, and do
   not run exploratory diagnostics to chase one. The previous session lost
   several hours to five successive wrong theories; that is the specific
   failure mode this rule exists to prevent.

   This bars *explaining* a failure, not *noticing* one. Record everything
   you observe, including things that look fine — a check that passes
   while the thing it names is broken is the most valuable finding here,
   and it has happened.

3. **Do not shell into the VM** beyond what the scripts do themselves. The
   one allowed probe is
   `limactl shell agents -- cat /etc/agent-sandbox/phase`.

4. **Do not read `archive/`, `git log`, `git show`, or `debug-notes/`.**
   They hold older and longer versions of these documents, and notes
   written for a past run. Reading them contaminates the test — the point
   is whether the *current* text is sufficient on its own. The working
   tree is current and committed; read the files themselves freely.

5. **One retry, then stop.** `scripts/pi-session.sh` already retries
   transient model errors by itself; let it. If a step fails for any other
   reason, run it one more time. If it fails again, stop and report.

6. **Do not improvise past a blocker.** If you are stuck, stop and report
   that you are stuck. Stopping early with a clear account is a *successful*
   run of this experiment. Grinding to a green result by working around the
   documentation is a failed one.

---

## What to do

Work inside `tmux` from the start (see `docs/tmux.md`) — a dropped SSH
session killed a build twice on 2026-10-31.

Read `AGENTS.md` first, as a newcomer would. Then:

```sh
./bootstrap.sh --rebuild
```

This destroys the existing VM and both agents. That is intended, and there
is no undo: `limactl snapshot` has twice lost snapshots that it had
confirmed, so do not offer one as a safety net. The repo is the
deliverable; the VM is a fixture.

It will also delete `config/agents.env` and then stop, asking for it to be
filled in. **The user will do that.** Ask them, wait, and do not ask for
any token, id or secret in the conversation itself — those go in the file.

Then continue as `AGENTS.md` describes. In outline, though follow the repo
rather than this summary if they differ:

```sh
./bootstrap.sh                      # again, after the file is filled in
./scripts/pi-session.sh build       # ~30 minutes
./scripts/pi-session.sh transcript
./scripts/finish-build.sh
./verify/verify.sh --models
```

If `verify.sh` reports failures, **report them. Do not fix them.**

Then run the one check `verify.sh` cannot: ask the user to message each
agent on Telegram and have it **fetch a web page**. On 2026-10-31 every
automated check passed while one agent could not reach the web at all.
Record the agent's exact words. If it mentions a workaround, a fallback,
a reader proxy, or rate-limiting, quote that — an agent reporting success
by routing around a block is a finding, not a pass.

Supervising Pi is in scope — reading its summary sceptically and checking
it against `verify.sh` is the job. But if Pi gets something wrong, note it
and stop; do not start a repair loop, and keep any message to Pi to a few
sentences.

---

## What to report back

Write your findings to `REBUILD-RESULT.md` in the repo root. That file is
the deliverable. Cover:

**Outcome** — the final `verify.sh --models` tally (passed/failed/skipped),
and the name of every failing check with its message, quoted. Then,
separately, whether each agent fetched a web page over Telegram, in its
own words.

**How many times you had to intervene.** The question is whether the
documents build this unattended, so every message to Pi, every retry and
every point you had to decide something counts. Zero is the target; say
plainly how far off it was.

**Timing** — roughly how long `bootstrap.sh` took, how long Pi's build
took, and whether anything hung.

**Where the documentation failed you.** The most valuable section. Every
point where you were unsure what to do next, had to guess, went looking for
information that was not there, or did something the docs did not mention.
Be specific and quote the passage. "It was clear" is a useful finding too.

**What you did that the docs did not tell you to do**, if anything, and why.

**Pi's own report** — did it claim anything `verify.sh` contradicts? Did it
say what surprised it? Quote rather than paraphrase.

**Anything you were blocked from doing** — permission denials, missing
tools, commands that did not exist.

Do not include any token, credential or user id in that file.

---

## When you are done

Stop. Do not fix anything you found, do not tidy the repo, and do not start
a second attempt. Tell the user the result file is written and leave the VM
in whatever state the run produced — its state is part of the evidence.
