# Snapshots

Recovery for a broken agent is a VM snapshot, not a backup mechanism of our
own. The agents own their `SOUL.md`, `MEMORY.md` and skills and rewrite them
as they learn, so anything this repo copied out would be stale by design —
see `docs/personality.md`.

## Do not trust `limactl snapshot` as an undo

It prints `experimental` on every invocation and has earned it: a snapshot
taken on 2026-10-30 and confirmed in the listing was gone the next day, with
`limactl snapshot list` returning empty. That has happened twice. Do not take
one before `bootstrap.sh --rebuild` and believe you can get back.

For a copy you can actually rely on, stop the instance and copy the disk:

```sh
limactl stop agents
cp ~/.lima/agents/disk ~/agents-disk-backup
limactl start agents
```

That is a real file you can put back. It is also the only form that survives
losing `~/.lima/agents/`, since snapshots live inside that same disk image.

## If you still want one

```sh
limactl snapshot create agents --tag before-rebuild
limactl snapshot apply  agents --tag before-rebuild
limactl snapshot delete agents --tag before-rebuild
```

The VM can be running; `limactl snapshot` drives the QEMU monitor directly.
On macOS with the `vz` backend it is not supported at all.

Applying one reverts the whole disk — agent state, packages, egress phase.
It does not re-run provisioning, so a snapshot taken under the `bootstrap`
phase comes back on `bootstrap`: check with `verify/verify.sh` and narrow
with `scripts/finish-build.sh`.
