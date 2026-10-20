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
| OpenClaw | `~/.openclaw/agents/default/SOUL.md` (inside the VM) |
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
made while running on the degraded fallback model:

```sh
limactl shell agents -- nano ~/.openclaw/agents/default/SOUL.md
limactl shell agents -- nano ~/.hermes/SOUL.md
```

For anything worse than a bad paragraph, restore the VM snapshot rather than
repairing by hand. See `docs/snapshots.md`.
