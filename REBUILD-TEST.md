# Rebuild test — instructions for a fresh coding agent

You are running an experiment, not a build. Read this whole file first.

**The question:** does this repo build two working agents from nothing,
driven only by its committed documents, without a human rescuing it?

The last run scored 36 of 37 with no intervention once it was underway,
but two of its steps had been done by a supervisor beforehand, and the
mechanism that watches Pi has been rewritten since. So the question is
open again, and this run is the test.

**You are the instrument, not the engineer.** Your value is that you have
no prior context. Everything you find confusing, ambiguous or missing is a
finding — it is what the next real user will hit. If you patch over a gap
using your own judgment, the gap becomes invisible and the run is wasted.

---

## Hard rules

1. **Do not fix the repo.** No edits to any file — not the spec, not
   `AGENTS.md`, not the scripts, not `verify.sh`. Write down what is wrong
   and keep going.

2. **Do not theorise about causes.** Report the symptom and the exact
   command output. Do not form hypotheses, and do not run exploratory
   diagnostics to chase one. A previous session lost hours to five
   successive wrong theories; that is what this rule prevents.

   This bars *explaining* a failure, not *noticing* one. Record what you
   observe, including things that look fine — a check that passes while
   the thing it names is broken is the most valuable finding here, and it
   has happened more than once.

3. **Do not shell into the VM.** The one allowed probe is
   `limactl shell agents -- cat /etc/agent-sandbox/phase`. Fixing a VM by
   hand makes a broken repo look like a working one.

4. **Do not read `archive/`, `debug-notes/`, `git log` or `git show`.**
   They hold older versions of these documents and notes from past runs.
   The working tree is current and committed; read the files themselves
   freely.

5. **One retry, then stop.** `scripts/pi-session.sh` retries transient
   model errors itself; let it. If a step fails for another reason, run it
   once more. If it fails again, stop and report.

6. **Do not improvise past a blocker.** Stopping early with a clear
   account is a *successful* run of this experiment. Grinding to a green
   result by working around the documentation is a failed one.

---

## What to do

Work inside `tmux` from the start (see `docs/tmux.md`). A dropped SSH
session killed a build twice on 2026-10-31.

Read `AGENTS.md` first, as a newcomer would. Then follow it. In outline,
though follow the repo rather than this summary if they differ:

```sh
./bootstrap.sh --rebuild            # destroys the VM and both agents
./bootstrap.sh                      # again, once agents.env is filled in
./scripts/pi-session.sh build       # ~30 minutes
./scripts/pi-session.sh transcript
./scripts/finish-build.sh
./verify/verify.sh --models --reboot
```

There is no undo. `limactl snapshot` has twice lost snapshots it had
confirmed, so do not offer one as a safety net. The repo is the
deliverable; the VM is a fixture.

`--rebuild` deletes `config/agents.env` and stops, asking for it to be
filled in. **The user does that, not you.** Ask them, wait, and never ask
for a token, id or secret in the conversation itself — a secret pasted
into a chat is a secret in a transcript.

If `verify.sh` reports failures, **report them. Do not fix them.**

Supervising Pi is in scope: read its summary sceptically and check it
against `verify.sh`. But if Pi gets something wrong, note it and stop. Do
not start a repair loop, and keep any message to Pi to a few sentences —
long prompts have hung this setup where two sentences worked.

### The check nothing automated covers

Ask the user to message each agent on Telegram and have it **fetch a web
page**. On 2026-10-31 every automated check passed while one agent could
not reach the web at all.

Record each agent's exact words. If it mentions a workaround, a fallback,
a reader proxy, or rate-limiting, quote that — an agent reporting success
by routing around a block is a finding, not a pass.

### Watch the watchdog

`scripts/pi-session.sh` kills a turn after `PI_SILENCE` seconds (default
600) with no log output at all. This replaced a 15-minute wall-clock limit
that was killing healthy builds, and **it has never run across a full
build**. If you see `no output for Ns -- killing a turn that has stopped
working`, record it and say what Pi was doing when it fired. That is a
primary result of this run, pass or fail.

---

## What to report

Write `REBUILD-RESULT.md` in the repo root. That file is the deliverable.

**Outcome** — the final tally from `verify.sh --models --reboot`, and every
failing check quoted with its message. Then, separately, whether each agent
fetched a web page over Telegram, in its own words.

**Interventions** — every message to Pi, every retry, every point you had
to decide something, and anything the user had to do beyond filling in
`agents.env`. Zero is the target; say plainly how far off it was.

**Timing** — how long bootstrap took, how long Pi's build took, whether
anything hung, and whether the silence watchdog fired.

**Where the documentation failed you.** The most valuable section. Every
point where you were unsure what to do next, had to guess, or went looking
for something that was not there. Quote the passage. "It was clear" is a
useful finding too.

**What you did that the docs did not tell you to do**, and why.

**Pi's own report** — did it claim anything `verify.sh` contradicts? Quote
rather than paraphrase.

**Anything you were blocked from doing** — permission denials, missing
tools, commands that did not exist.

Do not include any token, credential or user id in that file.

---

## When you are done

Stop. Do not fix what you found, do not tidy the repo, and do not start a
second attempt. Tell the user the result file is written, and leave the VM
in whatever state the run produced — its state is part of the evidence.
