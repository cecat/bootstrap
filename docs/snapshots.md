# Snapshots

Recovery for a broken agent is a VM snapshot, not a backup mechanism of our
own. The agents own their `SOUL.md`, `MEMORY.md` and skills and rewrite them
as they learn, so anything this repo copied out would be stale by design —
see `docs/personality.md`.

## Take one before anything destructive

```sh
limactl snapshot create agents --tag before-rebuild
limactl snapshot list agents
```

Worth doing before `bootstrap.sh --rebuild` (which destroys the instance),
before letting Pi re-run `setup.sh` against working agents, and any time the
agents are in a state you would be annoyed to lose. Snapshots are internal to
the qcow2 disk, so they cost little space and nothing to create.

The VM can be running. `limactl snapshot` drives the QEMU monitor directly.

## Restore

```sh
limactl snapshot apply agents --tag before-rebuild
```

This reverts the whole disk: agent state, installed packages, egress phase,
everything written since the tag. Anything learned in between is gone, which
is the point.

## Delete

```sh
limactl snapshot delete agents --tag before-rebuild
```

## Caveats

`limactl snapshot` prints `experimental` on every invocation. It works on the
qemu backend, which is what Linux hosts use here. On macOS with the `vz`
backend it is not supported — take a copy of `~/.lima/agents/` with the
instance **stopped** instead.

A snapshot is not a backup: it lives inside the same disk image, so losing
`~/.lima/agents/` loses the snapshots with it. For anything you genuinely
cannot lose, copy the file out while the instance is stopped.

Restoring does not re-run provisioning, so a snapshot taken under the
`bootstrap` egress phase comes back on `bootstrap`. Check with
`verify/verify.sh` and narrow with `scripts/finish-build.sh` if needed.
