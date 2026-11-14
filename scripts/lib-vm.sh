# shellcheck shell=bash
# ---------------------------------------------------------------------------
# Sourced, not run: how the host scripts act as root inside the VM.
#
#   . scripts/lib-vm.sh
#   vm_root <instance> '<shell script>'      run it as root in the guest
#   vm_admin_init <instance>                 install the admin secret's hash
#
# Why this exists. The agents run as the Lima user, and so does everything
# the host sends through `limactl shell` -- it is the only account Lima
# sets up. That user has passwordless sudo while Pi builds and loses it
# when the build is locked (`agent-egress runtime`), because the egress
# lockdown is matched on uid and root is exempt: an agent that can sudo is
# not confined by it.
#
# After the lock the host still needs root -- to re-push config, reopen the
# build phase, read policy state for verify.sh. It gets there through
# /usr/local/sbin/agent-admin, which runs a script as root only when handed
# a secret whose hash matches a root-only file in the guest. The secret
# lives in config/admin-secret on the host and is never written to the VM,
# so the agents, who share the uid but not the secret, cannot use the door.
#
# A VM built before 2026-11-14 has no agent-admin and an open sudo. Both
# functions fall back to plain sudo there, so the scripts keep working
# against it.
# ---------------------------------------------------------------------------

_LIB_VM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VM_ADMIN_SECRET="${VM_ADMIN_SECRET:-$_LIB_VM_REPO/config/admin-secret}"

# Make the secret if there is none. Generated, never supplied -- the same
# reasoning as OPENCLAW_GATEWAY_TOKEN. Losing this file locks the host out
# of root in a finished VM; the way back is ./bootstrap.sh --rebuild.
vm_admin_secret_ensure() {
  [ -s "$VM_ADMIN_SECRET" ] && return 0
  ( umask 077; openssl rand -hex 32 > "$VM_ADMIN_SECRET" ) || return 1
  chmod 600 "$VM_ADMIN_SECRET"
}

vm_sudo_open() {
  limactl shell "$1" -- sudo -n true >/dev/null 2>&1
}

vm_root() {
  local vm="$1" script="$2"
  if vm_sudo_open "$vm"; then
    limactl shell "$vm" -- sudo bash -c "$script"
  elif [ -s "$VM_ADMIN_SECRET" ]; then
    # The secret is the first line of stdin, the script is the rest. It is
    # never an argument: arguments are visible in the guest's process list
    # to the very user it must be kept from.
    { tr -d '\r\n' < "$VM_ADMIN_SECRET"; printf '\n%s\n' "$script"; } \
      | limactl shell "$vm" -- sudo -n /usr/local/sbin/agent-admin
  else
    echo "vm_root: sudo is locked in '$vm' and ${VM_ADMIN_SECRET#"$_LIB_VM_REPO"/} is missing." >&2
    echo "Without that file the host has no way to root in a finished VM." >&2
    return 1
  fi
}

# Install the hash of the host's secret where only root can read it. Only
# possible while sudo is still open; on a locked VM the hash is already
# there, and a mismatch shows up as agent-admin refusing.
vm_admin_init() {
  local vm="$1" hash
  vm_admin_secret_ensure || { echo "could not create $VM_ADMIN_SECRET" >&2; return 1; }
  vm_sudo_open "$vm" || return 0
  hash="$(tr -d '\r\n' < "$VM_ADMIN_SECRET" | openssl dgst -sha256 | awk '{print $NF}')"
  case "$hash" in *[!a-f0-9]*|'') echo "could not hash the admin secret" >&2; return 1 ;; esac
  limactl shell "$vm" -- sudo bash -c "
    install -d -m 0755 /etc/agent-sandbox
    umask 077
    printf '%s\n' '$hash' > /etc/agent-sandbox/admin.sha256
    chown root:root /etc/agent-sandbox/admin.sha256
    chmod 0600 /etc/agent-sandbox/admin.sha256
  "
}
