#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bring an existing VM up to the current sandbox WITHOUT rebuilding it.
#
#   ./scripts/upgrade-vm.sh [instance]      (default instance: agents)
#
# For a VM built before 2026-11-14, whose agents are worth keeping. Those
# VMs let an agent reach every loopback service on the host through squid,
# have no IPv6 lockdown, and leave the agent user with passwordless sudo
# (docs/gotchas.md). `./bootstrap.sh --rebuild` fixes all of that and
# destroys the agents and everything they have learned. This does not.
#
# It stops and starts the VM once: the agents are off Telegram for a few
# minutes. Nothing inside ~/.hermes or ~/.openclaw is touched.
#
# Why it works. "Editing lima/agents.yaml does not change an existing VM"
# because Lima froze a copy at creation -- but it re-reads THAT copy on
# every boot, and the provisioning step that writes squid.conf and
# agent-egress runs on every boot too. So the frozen copy is the thing to
# replace. In order:
#
#   1. install-config.sh, against the old VM. It writes the model-gateway
#      port file the new squid rules need and the hash of the host's admin
#      secret. The old policy ignores both, so nothing changes yet.
#   2. Stop the VM, keep the old frozen definition, put the current one in
#      its place, start the VM.
#   3. On that boot the new policy is written and agent-egress re-applies
#      the phase the VM was already in. For a finished VM that is
#      `runtime`, which now also closes sudo -- possible only because step
#      1 left the hash that lets the host back in.
#   4. verify.sh, which is the evidence.
#
# Step 1 before step 2 is the whole trick: done the other way round, the
# VM boots with a squid that allows the model gateway on no port, and
# with no way to lock sudo.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
INSTANCE="${1:-${AGENTS_VM:-agents}}"
LIMA_HOME_DIR="${LIMA_HOME:-$HOME/.lima}"
FROZEN="$LIMA_HOME_DIR/$INSTANCE/lima.yaml"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running. Start it first: limactl start $INSTANCE"
[ -f "$FROZEN" ] || fail "$FROZEN not found; is LIMA_HOME set somewhere unusual?"
[ -f config/agents.env ] && [ -f config/model-access.env ] \
  || fail "config/ here has no agents.env or model-access.env. Run this from the
checkout the VM was built from -- its config/ is what gets re-pushed."

if cmp -s lima/agents.yaml "$FROZEN"; then
  say "'$INSTANCE' already runs the current definition; only re-pushing config"
  AGENTS_VM="$INSTANCE" ./scripts/install-config.sh "$INSTANCE"
  exit 0
fi

PHASE="$(limactl shell "$INSTANCE" -- cat /etc/agent-sandbox/phase 2>/dev/null | tr -dc 'a-z' || true)"
say "upgrading '$INSTANCE' in place (phase: ${PHASE:-none}). The agents will be off
    Telegram for a few minutes while the VM restarts."

say "1/4  pushing config, the gateway port and the admin-secret hash"
AGENTS_VM="$INSTANCE" ./scripts/install-config.sh "$INSTANCE" >/dev/null \
  || fail "install-config.sh failed; nothing has been changed in the VM's definition.
Run it by hand to see why: ./scripts/install-config.sh $INSTANCE"
[ -s config/admin-secret ] || fail "config/admin-secret was not created; stopping before the VM is locked with no way back in."

BACKUP="$FROZEN.before-upgrade-$(date -u +%Y%m%dT%H%M%SZ)"
say "2/4  stopping the VM and replacing its frozen definition"
limactl stop "$INSTANCE" >/dev/null 2>&1 || fail "could not stop '$INSTANCE'."
cp -p "$FROZEN" "$BACKUP"
cp lima/agents.yaml "$FROZEN"
say "     the old definition is kept at ${BACKUP/#$HOME/~}"

say "3/4  starting the VM on the new definition (a few minutes)"
if ! limactl start "$INSTANCE" --tty=false >/dev/null 2>&1; then
  cp -p "$BACKUP" "$FROZEN"
  fail "the VM did not start on the new definition. The old one has been put
back; start it with: limactl start $INSTANCE"
fi
for _ in $(seq 1 30); do limactl shell "$INSTANCE" -- true >/dev/null 2>&1 && break; sleep 5; done

# The boot re-applied the phase with the NEW agent-egress, but install-config
# is what knows the policy files are current -- and on a VM that was locked
# it now goes through the admin helper, which is itself part of the proof.
say "4/4  re-applying policy and verifying"
AGENTS_VM="$INSTANCE" ./scripts/install-config.sh "$INSTANCE" >/dev/null \
  || fail "install-config.sh failed after the restart. The VM is up on the new
definition; run ./scripts/install-config.sh $INSTANCE to see why."

echo
if AGENTS_VM="$INSTANCE" ./verify/verify.sh; then
  say "upgraded. Now message each bot: nothing here proves an agent answers."
else
  printf '\033[31merror:\033[0m verify.sh reported failures (above). The VM is running on the new\n' >&2
  printf 'definition. To go back: limactl stop %s, copy\n  %s\nover %s, and start it again.\n' \
    "$INSTANCE" "$BACKUP" "$FROZEN" >&2
  exit 1
fi
