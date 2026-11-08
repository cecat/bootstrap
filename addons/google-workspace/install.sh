#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Google Workspace add-on for the Hermes agent. OPTIONAL -- the base build
# neither needs nor knows about this.
#
# The user does the first two, because they need a browser and a secret:
#   ./scripts/addon-google-workspace.sh auth      one-time browser consent
#   ./scripts/addon-google-workspace.sh install   preconditions, push, stage
#
# Then their coding agent takes over, because supervising Pi is its job:
#   ./scripts/addon-google-workspace.sh build     drive Pi
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
# Surrounding whitespace is stripped too, inside the quotes as well as
# outside. A value pasted out of a browser arrives with a leading space
# often enough that it is worth handling rather than diagnosing: Google
# answers a client id with a space in front of it with "Error 401:
# invalid_client -- The OAuth client was not found", which reads like a
# console problem and is not.
envval() {
  awk -v k="$1" '
    index($0, k "=") == 1 {
      v = substr($0, length(k) + 2)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
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

  It needs an OAuth client from Google Cloud Console, which only you can
  make. The five steps are in addons/google-workspace/README.md.

  Then, rather than copying two long strings by hand:

    Credentials -> the download icon beside your Desktop client ->
    put the .json in  secrets/

  It arrives named client_secret_*.json; leave the name alone. That
  directory is gitignored, and the next command reads the file itself.
  (If you would rather, fill GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET
  in $ENVFILE by hand instead.)

  Either way, do not paste these values into a chat with an agent -- a
  secret in a conversation is a secret in a transcript.

  One step matters more than the rest: publish the consent screen. Left
  in "Testing", Google expires the refresh token after seven days and the
  add-on quietly stops working every week.

  Then:  ./scripts/addon-google-workspace.sh auth

EOF
    exit 2
  fi
  chmod 600 "$ENVFILE" 2>/dev/null || true
}

require_client() {
  # Either source will do: the downloaded JSON, or the two values typed
  # into the env file. `auth` reads the JSON and copies them across.
  ls "$REPO"/secrets/client_secret_*.json >/dev/null 2>&1 && return 0
  [ -n "$(envval GOOGLE_CLIENT_ID)" ] && [ -n "$(envval GOOGLE_CLIENT_SECRET)" ] || {
    cat >&2 <<EOF

  No OAuth client yet. Create one in Google Cloud Console (see
  addons/google-workspace/README.md), then either:

    - download its JSON and drop it in  secrets/  -- nothing to retype, or
    - fill GOOGLE_CLIENT_ID and GOOGLE_CLIENT_SECRET in $ENVFILE

  Then run this again.

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
  ok "credentials present in $ENVFILE -- consent already done, not repeated"

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
  # Anything that can outlast a user's patience says how long it will be.
  # This runs the whole base suite with its output redirected, so it
  # prints nothing for minutes and reads like a hang. It duly did.
  printf '      %sthis takes 3-6 minutes and prints nothing until it finishes%s\n' "$Y" "$Z"
  printf '      watch it live:  tail -f %s\n' "$BASELOG"
  if ./verify/verify.sh >"$BASELOG" 2>&1; then
    ok "base verify.sh passed"
  else
    warn "base verify.sh reported failures (see $BASELOG)."
    warn "Fix the base build before adding to it -- an add-on layered on a"
    warn "broken base produces failures that look like the add-on's fault."
    tail -15 "$BASELOG" >&2
    fail "refusing to install onto a failing base build."
  fi

  # The two files Hermes' bundled skill declares under
  # required_credential_files, written host-side by the consent flow.
  # Pushing them is what lets the VM skip the browser it does not have.
  # The names are the skill's and are not ours to choose: Hermes looks for
  # them by name, and a job whose skill is missing one is refused before it
  # runs.
  email="$(envval GOOGLE_ACCOUNT_EMAIL)"
  [ -n "$email" ] || fail "GOOGLE_ACCOUNT_EMAIL is blank in $ENVFILE.
Re-run: ./scripts/addon-google-workspace.sh auth --force"

  TOKENJSON="config/google_token.json"
  SECRETJSON="config/google_client_secret.json"
  for f in "$TOKENJSON" "$SECRETJSON"; do
    [ -f "$f" ] || fail "$f is missing. It is written by the consent step.

If you consented before this add-on moved to the bundled skill, the old
MCP-format credential will not do -- the skill needs scopes it never
requested. Re-run:

    ./scripts/addon-google-workspace.sh auth --force"
  done

  step "Pushing the add-on into $INSTANCE"
  limactl shell "$INSTANCE" -- rm -rf /tmp/google-skill-push
  limactl shell "$INSTANCE" -- mkdir -p /tmp/google-skill-push
  limactl copy "$TOKENJSON" "$INSTANCE:/tmp/google-skill-push/google_token.json" \
    || fail "could not copy the token into the VM."
  limactl copy "$SECRETJSON" "$INSTANCE:/tmp/google-skill-push/google_client_secret.json" \
    || fail "could not copy the client secret into the VM."

  # NOTE: single-quoted guest script. No apostrophes below this line until
  # the closing quote -- one contraction silently runs the rest on the host.
  # Staged into ~/google-skill-push rather than installed into ~/.hermes
  # directly: placing them is Pi work, specified in spec.md, so that the
  # repo-committed spec is what a fresh clone reproduces.
  limactl shell "$INSTANCE" -- bash -eo pipefail -c '
    rm -rf "$HOME/google-skill-push"
    install -d -m 0700 "$HOME/google-skill-push"
    install -m 0600 /tmp/google-skill-push/google_token.json "$HOME/google-skill-push/"
    install -m 0600 /tmp/google-skill-push/google_client_secret.json "$HOME/google-skill-push/"
    rm -rf /tmp/google-skill-push
  ' || fail "could not stage the add-on files in the VM."
  ok "credentials staged in ~/google-skill-push for $email"

  step "Staging the spec for Pi"
  limactl copy "$ADDON/spec.md" "$INSTANCE:agent-bootstrap/GOOGLE-ADDON.md" \
    || fail "could not copy the add-on spec into the VM."
  ok "spec placed at ~/agent-bootstrap/GOOGLE-ADDON.md"

  # Stop here, deliberately. Everything above needed a browser, a secret,
  # or a file only the user can edit. Everything below is supervising Pi,
  # which is a coding agent's job -- reading a summary sceptically against
  # verify.sh is the whole skill, and this repo exists because a human
  # should not have to do it. `install` used to run straight on into the
  # Pi turn, which left whoever typed it watching a progress view for
  # fifteen minutes with no idea what they were meant to be checking.
  step "Your part is done -- hand over to your coding agent"
  cat <<EOF

  Credentials are in place and Pi has its spec. What remains is a build
  and a review of it: roughly 5-15 minutes of Pi working, then reading
  what it claims against what the checks measure.

  ${B}Tell your coding agent:${Z}

      Install the Google Workspace add-on: run
      ./scripts/addon-google-workspace.sh build, then supervise Pi and
      verify it as addons/google-workspace/README.md describes.

  It will come back to you once, at the end, with the one check no
  script can do: message the Hermes bot and ask what is on your
  calendar.

EOF
}

# ===========================================================================
# The agent's half: drive Pi, then report. Separate from install so the
# human-facing setup can finish and hand over cleanly.
# ===========================================================================
cmd_build() {
  vm_running || fail "instance '$INSTANCE' is not running."

  limactl shell "$INSTANCE" -- bash -lc 'test -f "$HOME/agent-bootstrap/GOOGLE-ADDON.md"' 2>/dev/null \
    || fail "the add-on spec is not in the VM, so the setup half has not run.
The user needs to do their part first -- see addons/google-workspace/README.md:
./scripts/addon-google-workspace.sh auth, then install."

  limactl shell "$INSTANCE" -- bash -lc 'test -s "$HOME/google-skill-push/google_token.json" && test -s "$HOME/google-skill-push/google_client_secret.json"' 2>/dev/null \
    || fail "the staged credentials are not in the VM. Run the install step first."

  step "Pi builds the add-on"
  printf '      %sthis takes 5-15 minutes.%s Pi'"'"'s progress view follows; long gaps\n' "$Y" "$Z"
  printf '      between lines are normal -- it is thinking, not stuck. The watchdog\n'
  printf '      kills a turn only after %ss with no output at all.\n' "${PI_SILENCE:-600}"
  printf '      From another shell:  ./scripts/pi-session.sh steps\n\n'

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
  What it actually did:  ./scripts/pi-session.sh steps
  Then check it:         ./scripts/addon-google-workspace.sh verify --live --base

  A summary is a claim; verify.sh is evidence. Push back with
  ./scripts/pi-session.sh say "..." rather than fixing the VM by hand.
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

  # Two layouts to clean, not one. The second group is the MCP server this
  # add-on used before it moved to Hermes' bundled skill: a machine
  # installed under the old scheme still has those files, and leaving them
  # means a parked MCP server and a stale systemd drop-in surviving a
  # "removal" that reported success.
  limactl shell "$INSTANCE" -- bash -lc '
    set -u
    rm -f "$HOME/.hermes/google_token.json" "$HOME/.hermes/google_client_secret.json"
    rm -f "$HOME/.hermes/google_oauth_pending.json"
    rm -rf "$HOME/google-skill-push"
    rm -f "$HOME/.config/agent-sandbox/google.env"
    rm -rf "$HOME/.config/agent-sandbox/google-creds"
    rm -rf "$HOME/google-mcp-src" "$HOME/.local/share/agent-sandbox/google-mcp"
    rm -f "$HOME/.config/systemd/user/hermes-gateway.service.d/20-google.conf"
    rm -f "$HOME/agent-bootstrap/setup-google.sh" "$HOME/agent-bootstrap/GOOGLE-ADDON.md"
    systemctl --user daemon-reload 2>/dev/null || true
  ' || warn "some files could not be removed; check by hand."
  ok "credentials and any legacy MCP server files removed"

  warn "Two config edits were NOT made automatically, because Pi wrote them"
  warn "and knows their shape. Ask it to undo them:"
  warn "  ./scripts/pi-session.sh say \"Remove the proxy entries from terminal.env_passthrough in the Hermes config, and any google-workspace mcp_servers entry if one is left, then restart the gateway.\""

  cat <<EOF

  ${B}This does not revoke anything at Google.${Z} The refresh token still
  works until you say otherwise, and your local copy is still in
  $ENVFILE. To actually cut access:

      https://myaccount.google.com/permissions

  Then delete $ENVFILE, config/google_token.json and
  config/google_client_secret.json.

EOF
}

case "${1:-}" in
  auth)    shift; cmd_auth "$@" ;;
  install) cmd_install ;;
  build)   cmd_build ;;
  verify)  shift; cmd_verify "$@" ;;
  remove)  cmd_remove ;;
  *)
    sed -n '3,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
