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
| OpenClaw | `SOUL.md` in the agent's **workspace** — `~/.openclaw/workspace/` for the default agent, `~/.openclaw/workspace-<id>/` otherwise |
| Hermes | `~/.hermes/SOUL.md` (or `$HERMES_HOME/SOUL.md`) |

**Ask the tool, do not infer from the filesystem.** OpenClaw's workspace
path is configurable, so resolve it rather than assuming:

```sh
limactl shell agents -- openclaw config get agents.entries.<id>.workspace
```

and `openclaw doctor` reports how many characters of `SOUL.md` were
actually injected — the only reading that proves which file is live. In a
chat with the agent, `/context list` prints the same thing.

**Check the file changed; do not take the agent's word for it.**
(2026-11-07) Asked to edit its `SOUL.md`, Gandalf wrote a convincing 2 kB
file to `~/SOUL.md` — the obvious guess, the wrong path, loaded by
nothing — and reported success. Worse, Hermes then refuses to overwrite
a file the task has not read in full, so the agent gets stuck rewriting
its own decoy while the real file never moves.

An earlier build, on a weaker model, went further and described edits it
had not made at all. Either way the tell is the same and it takes one
command:

```sh
limactl shell agents -- stat -c '%s bytes %y' ~/.hermes/SOUL.md
```

If the size and timestamp have not moved, nothing happened, whatever you
were told. Ask again naming the absolute path, and have it delete the
stray `~/SOUL.md` if one appeared. Seeds written by current builds state
their own path in the first bullet to stop this at the source.

## Keeping each agent out of the other's tree

Both agents run as **the same Unix user**. `~/.hermes/` and `~/.openclaw/`
are two directories in one home, not two homes — so `0600` protects
nothing between them, and either agent can read the other's credentials.
A token read from the other's tree works perfectly well, because a token
is all Google or Telegram ever checks.

The realistic failure is not theft, it is an agent tidying up, finding a
credential file, and deciding it is the one it was looking for. The fix is
to say so in each agent's `SOUL.md`:

> You share this machine with another agent, under the same Unix user.
> Your home is `/home/<user>/.openclaw`; the other agent's tree is
> `/home/<user>/.hermes`. Stay out of it — do not read, write or tidy
> anything there. File permissions will not stop you, because you are both
> the same user, so this is on you.

Builds from 2026-11-11 seed that line automatically
(`spec/pi-target-state.md`). **An agent built before then does not have
it**, and the seed is never re-applied — so add it the way you change
anything else here: ask the agent to.

Be clear about what this is. It is a **convention, not a boundary**, and a
determined or manipulated agent can ignore it. Enforcing it would need a
second Unix user in the VM or a second VM; see `todo.md`.

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
