# Changing how an agent behaves

**Talk to the agent.** That is the whole interface.

```
you:   show me your SOUL.md
you:   add a paragraph saying you should never summarize my email without asking
you:   change "be concise" to "be concise, but always show your reasoning on money"
```

Each agent keeps its character in its own `SOUL.md`, reads it at the start of
every session, and can edit it with the tools it already has. There is nothing
to sync, no file in this repo to change, and no restart needed.

| Agent | File |
|---|---|
| OpenClaw | `~/.openclaw/agents/<agent-id>/SOUL.md` (inside the VM) |
| Hermes | `~/.hermes/SOUL.md` (inside the VM) |

## Why not edit the files directly

You can (see below), but it is the worse default, for two reasons that come
out of decisions made elsewhere in this repo:

- **The VM has no mounts.** That is the isolation boundary. There is no host
  path pointing at these files, by design.
- **Hermes writes to its own state.** It builds `memories/MEMORY.md`,
  `memories/USER.md` and `skills/` as it learns. A copy you maintain by hand
  would drift from the copy it maintains by itself.

The repo ships a ten-line *seed* `SOUL.md` that Pi writes once at bootstrap.
After that the file belongs to the agent and the setup script never touches it
again, so re-running setup will not revert anything you have changed.

## Escape hatch

When an agent is too broken to talk to — a mangled `SOUL.md`, or a bad edit
made while running on the degraded fallback model — **you** can shell in and
fix the file. A coding agent cannot: `limactl shell agents -- <anything>` is
denied to it, because a VM repaired by hand looks like success while the repo
still produces the failure for the next person.

```sh
limactl shell agents -- openclaw agents list     # get the id first
limactl shell agents -- nano ~/.openclaw/agents/<agent-id>/SOUL.md
limactl shell agents -- nano ~/.hermes/SOUL.md
```

For anything worse than a bad paragraph, rebuild. The agents are cheap to
recreate and a snapshot is not a reliable undo — see `docs/snapshots.md`.
