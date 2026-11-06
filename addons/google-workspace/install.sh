#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Google Workspace add-on for the Hermes agent. OPTIONAL -- the base build
# neither needs nor knows about this.
#
#   ./scripts/addon-google-workspace.sh auth      one-time browser consent
#   ./scripts/addon-google-workspace.sh install   build it
#   ./scripts/addon-google-workspace.sh verify    the evidence
#   ./scripts/addon-google-workspace.sh remove    undo it
#
# Nothing here modifies the base system. It adds files to the VM and gives
# Pi a second spec; bootstrap.sh, verify/verify.sh, lima/agents.yaml and
# spec/pi-target-state.md are untouched and must stay that way.
# ---------------------------------------------------------------------------
set -uo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ADDON/../.." && pwd)"
cd "$REPO"
INSTANCE="${AGENTS_VM:-agents}"
ENVFILE="config/google.env"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

# Read one value WITHOUT executing the file. Sourcing it would be simpler
# and is what the base scripts do for agents.env, but this file holds
# values the user pastes out of a browser: one backtick or $(...) in a
# mistyped secret would then run as a command on the host. Strip one layer
# of matched quotes so that KEY="" reads as empty rather than two quote
# characters -- reading these with a naive grep shipped a bug once already.
envval() {
  awk -v k="$1" '
    index($0, k "=") == 1 {
      v = substr($0, length(k) + 2)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      print v; exit
    }' "$ENVFILE" 2>/dev/null
}

vm_running() {
  [ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ]
}

# ===========================================================================
# The config handshake. Same shape as bootstrap.sh: create the file, say
# plainly what is needed, exit 2, and wait to be run again.
# ===========================================================================
ensure_config() {
  if [ ! -f "$ENVFILE" ]; then
    install -m 600 "$ADDON/google.env.example" "$ENVFILE" \
      || fail "could not create $ENVFILE"
    cat >&2 <<EOF

  STOP -- this is your turn, and the add-on waits here until you take it.

  $ENVFILE has been created. It needs two values from Google Cloud
  Console, which only you can get:

      \$EDITOR $ENVFILE

    GOOGLE_CLIENT_ID       from an OAuth client of type "Desktop app"
    GOOGLE_CLIENT_SECRET

  The five steps to create one are in
  addons/google-workspace/README.md. One of them matters more than the
  others: publish the consent screen. Left in "Testing", Google expires
  the refresh token after seven days and the add-on quietly stops working
  every week.

  Do not paste these values into a chat with an agent. Type them into the
  file, in an editor, where they stay out of a transcript.

  Then:  ./scripts/addon-google-workspace.sh auth

EOF
    exit 2
  fi
  chmod 600 "$ENVFILE" 2>/dev/null || true
}

require_client() {
  [ -n "$(envval GOOGLE_CLIENT_ID)" ] && [ -n "$(envval GOOGLE_CLIENT_SECRET)" ] || {
    cat >&2 <<EOF

  GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET are still blank in
  $ENVFILE. Fill them in from Google Cloud Console -- see
  addons/google-workspace/README.md -- and run this again.

EOF
    exit 2
  }
}

# ===========================================================================
cmd_auth() {
  ensure_config
  require_client
  step "Google consent"
  python3 "$ADDON/auth/google-oauth.py" "$@" || fail "consent did not complete."
}

# ===========================================================================
cmd_install() {
  ensure_config
  require_client

  step "Preconditions"

  [ -n "$(envval GOOGLE_REFRESH_TOKEN)" ] || {
    cat >&2 <<EOF

  No refresh token yet. Run the consent step first:

      ./scripts/addon-google-workspace.sh auth

EOF
    exit 2
  }
  ok "credentials present in $ENVFILE"

  vm_running || fail "instance '$INSTANCE' is not running. Build the base system first."

  limactl shell "$INSTANCE" -- bash -lc 'test -x "$HOME/agent-bootstrap/setup.sh"' 2>/dev/null \
    || fail "the base build is not finished -- ~/agent-bootstrap/setup.sh is missing
in the VM. Run ./bootstrap.sh and ./scripts/pi-session.sh build first."

  limactl shell "$INSTANCE" -- bash -lc 'command -v hermes >/dev/null' 2>/dev/null \
    || fail "hermes is not installed in the VM. This add-on extends the Hermes
agent, so the base build has to have produced one."
  ok "base build present"

  # The allowlist precondition. Once this add-on is in, whoever can message
  # the Hermes bot can read the user's mail -- so an empty allowlist stops
  # being a configuration detail and becomes the whole exposure.
  allowed="$(limactl shell "$INSTANCE" -- bash -lc \
    'grep -hE "^TELEGRAM_ALLOWED_USERS=" "$HOME/.hermes/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"[:space:]"' 2>/dev/null)"
  if [ -z "$allowed" ]; then
    fail "the Hermes bot has an empty TELEGRAM_ALLOWED_USERS.

This add-on gives the Hermes agent your mailbox, your calendar and your
Drive. Who may message that bot is the only thing deciding who can reach
them, so it cannot be left open.

Set TELEGRAM_ALLOWED_USER_ID in config/agents.env, re-run the base build,
and come back. If the Hermes channel is deliberately off, turn it on or
leave this add-on uninstalled -- an agent with your mail and an empty
allowlist is the one combination this refuses to create."
  fi
  ok "Hermes Telegram allowlist is not empty"

  step "Base system still verifying"
  BASELOG="$(mktemp -t gw-base-verify.XXXXXX)"
  if ./verify/verify.sh >"$BASELOG" 2>&1; then
    ok "base verify.sh passed"
  else
    warn "base verify.sh reported failures (see $BASELOG)."
    warn "Fix the base build before adding to it -- an add-on layered on a"
    warn "broken base produces failures that look like the add-on's fault."
    tail -15 "$BASELOG" >&2
    fail "refusing to install onto a failing base build."
  fi

  # The credential file the server's own store reads, written by the host
  # consent flow. Pushing it is what lets the VM skip the browser it does
  # not have: workspace-mcp finds a populated store and never opens a
  # consent page.
  email="$(envval GOOGLE_ACCOUNT_EMAIL)"
  [ -n "$email" ] || fail "GOOGLE_ACCOUNT_EMAIL is blank in $ENVFILE.
Re-run: ./scripts/addon-google-workspace.sh auth --force"
  CREDJSON="config/google-credentials-$email.json"
  [ -f "$CREDJSON" ] || fail "$CREDJSON is missing. It is written by the consent
step; re-run: ./scripts/addon-google-workspace.sh auth --force"

  step "Pushing the add-on into $INSTANCE"
  limactl shell "$INSTANCE" -- rm -rf /tmp/google-mcp-push
  limactl shell "$INSTANCE" -- mkdir -p /tmp/google-mcp-push
  limactl copy "$ADDON/requirements.txt" "$INSTANCE:/tmp/google-mcp-push/requirements.txt" \
    || fail "could not copy requirements.txt into the VM."
  limactl copy "$ENVFILE" "$INSTANCE:/tmp/google-mcp-push/google.env" \
    || fail "could not copy credentials into the VM."
  limactl copy "$CREDJSON" "$INSTANCE:/tmp/google-mcp-push/cred.json" \
    || fail "could not copy the credential file into the VM."

  # NOTE: single-quoted guest script. No apostrophes below this line until
  # the closing quote -- one contraction silently runs the rest on the host.
  # The credential file is named for the account because that is how the
  # server's LocalDirectoryCredentialStore looks it up.
  limactl shell "$INSTANCE" -- bash -eo pipefail -c '
    install -d -m 0700 "$HOME/.config/agent-sandbox"
    install -m 0600 /tmp/google-mcp-push/google.env "$HOME/.config/agent-sandbox/google.env"
    install -d -m 0700 "$HOME/.config/agent-sandbox/google-creds"
    install -m 0600 /tmp/google-mcp-push/cred.json "$HOME/.config/agent-sandbox/google-creds/$1"
    install -d -m 0755 "$HOME/google-mcp-src"
    install -m 0644 /tmp/google-mcp-push/requirements.txt "$HOME/google-mcp-src/"
    rm -rf /tmp/google-mcp-push
  ' _ "$email.json" || fail "could not install the add-on files in the VM."
  ok "credential store populated for $email; pinned requirements in ~/google-mcp-src"

  step "Handing the spec to Pi"
  limactl copy "$ADDON/spec.md" "$INSTANCE:agent-bootstrap/GOOGLE-ADDON.md" \
    || fail "could not copy the add-on spec into the VM."
  ok "spec placed at ~/agent-bootstrap/GOOGLE-ADDON.md"

  # Short on purpose: fifty-line supervision prompts have hung this setup.
  # It must still say which file to follow, because `say` re-copies the
  # base spec to AGENTS.md on every turn -- so Pi is looking at two specs,
  # and the other one tells it setup.sh is the deliverable.
  ./scripts/pi-session.sh say \
    "New task, from ~/agent-bootstrap/GOOGLE-ADDON.md -- not AGENTS.md. Build what it describes, leaving setup.sh and the rest of the base build untouched." \
    || warn "the Pi turn returned non-zero -- read ./scripts/pi-session.sh summary before concluding anything."

  step "Next"
  cat <<EOF
  Read what Pi claims:   ./scripts/pi-session.sh summary
  Then check it:         ./scripts/addon-google-workspace.sh verify

  A summary is a claim; verify.sh is evidence.
EOF
}

# ===========================================================================
cmd_verify() {
  # Pass flags through. Swallowing them here would silently disable
  # --live, which is the only check that exercises the credential.
  exec "$ADDON/verify.sh" "$INSTANCE" "$@"
}

# ===========================================================================
cmd_remove() {
  vm_running || fail "instance '$INSTANCE' is not running."

  step "Removing the add-on from $INSTANCE"

  # If Pi put the add-on's work in setup.sh instead of its own script, the
  # base deliverable now rebuilds this on every run and removing files is
  # not enough. Say so rather than reporting a clean removal.
  if limactl shell "$INSTANCE" -- bash -lc 'grep -qiE "google|mcp_servers" "$HOME/agent-bootstrap/setup.sh" 2>/dev/null'; then
    warn "~/agent-bootstrap/setup.sh mentions google -- Pi put add-on work in the"
    warn "base deliverable, against its spec. Removing files will not stick: the"
    warn "next run of setup.sh puts them back. Have Pi take it out of setup.sh."
  fi

  limactl shell "$INSTANCE" -- bash -lc '
    set -u
    rm -f "$HOME/.config/agent-sandbox/google.env"
    rm -rf "$HOME/.config/agent-sandbox/google-creds"
    rm -rf "$HOME/google-mcp-src" "$HOME/.local/share/agent-sandbox/google-mcp"
    rm -f "$HOME/.config/systemd/user/hermes-gateway.service.d/20-google.conf"
    rm -f "$HOME/agent-bootstrap/setup-google.sh" "$HOME/agent-bootstrap/GOOGLE-ADDON.md"
    systemctl --user daemon-reload 2>/dev/null || true
  ' || warn "some files could not be removed; check by hand."
  ok "credentials, server and drop-in removed"

  warn "the mcp_servers entry in Hermes config was NOT removed automatically."
  warn "Pi wrote it and knows its shape; ask it to remove that entry and"
  warn "restart the gateway:"
  warn "  ./scripts/pi-session.sh say \"Remove the google-workspace mcp_servers entry from the Hermes config and restart the gateway.\""

  cat <<EOF

  ${B}This does not revoke anything at Google.${Z} The refresh token still
  works until you say otherwise, and your local copy is still in
  $ENVFILE. To actually cut access:

      https://myaccount.google.com/permissions

  Then delete $ENVFILE and config/google-credentials-*.json.

EOF
}

case "${1:-}" in
  auth)    shift; cmd_auth "$@" ;;
  install) cmd_install ;;
  verify)  shift; cmd_verify "$@" ;;
  remove)  cmd_remove ;;
  *)
    sed -n '3,9p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
