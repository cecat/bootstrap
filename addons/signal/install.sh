#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Signal chat channel for the agents. OPTIONAL -- the base build neither
# needs nor knows about this, and Telegram is untouched by it.
#
# The user does the first two, because they need a phone and a camera:
#   ./scripts/addon-signal.sh link      one-time QR scan, inside the VM
#   ./scripts/addon-signal.sh install   preconditions, push, stage
#
# Then their coding agent takes over, because supervising Pi is its job:
#   ./scripts/addon-signal.sh build     drive Pi
#   ./scripts/addon-signal.sh verify    the evidence
#   ./scripts/addon-signal.sh remove    undo it
#
# Nothing here modifies the base system. It adds files to the VM and gives
# Pi a second spec; bootstrap.sh, verify/verify.sh, lima/agents.yaml and
# spec/pi-target-state.md are untouched and must stay that way.
#
# NOT YET BUILT -- see PLAN.md. This script has never been run.
# ---------------------------------------------------------------------------
set -uo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ADDON/../.." && pwd)"
cd "$REPO"
INSTANCE="${AGENTS_VM:-agents}"
ENVFILE="config/signal.env"

# The daemon's loopback port inside the VM. Overridable only because 8080
# is a popular port; nothing outside the VM can reach it either way.
SIGNAL_PORT="${SIGNAL_PORT:-8080}"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

# Read one value WITHOUT executing the file. Sourcing would be simpler and
# is what the base scripts do for agents.env, but this file holds values a
# user types by hand: one backtick or $(...) in a mistyped number would
# then run as a command on the host. Strip one layer of matched quotes so
# KEY="" reads as empty rather than two quote characters, and trim
# whitespace inside the quotes as well as outside.
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

# E.164: a plus, then 8-15 digits. Checked because every downstream thing
# -- the allowlist match, Note-to-Self detection, the adapters themselves
# -- compares numbers as strings. "(555) 123-4567" and "+15551234567" are
# the same number to a human and two different strings to Signal, and the
# failure mode is an agent that silently answers nobody.
valid_e164() {
  case "$1" in
    +[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
      case "${1#+}" in *[!0-9]*) return 1 ;; esac
      [ "${#1}" -le 16 ] ;;
    *) return 1 ;;
  esac
}

# Which agents this install covers, from SIGNAL_AGENT.
agents_selected() {
  case "$(envval SIGNAL_AGENT)" in
    hermes)   echo "hermes" ;;
    openclaw) echo "openclaw" ;;
    both)     echo "hermes openclaw" ;;
    *)        echo "" ;;
  esac
}

# The number configured for one agent.
number_for() {
  case "$1" in
    hermes)   envval SIGNAL_HERMES_NUMBER ;;
    openclaw) envval SIGNAL_OPENCLAW_NUMBER ;;
  esac
}

# ===========================================================================
# The config handshake. Same shape as bootstrap.sh: create the file, say
# plainly what is needed, exit 2, and wait to be run again.
# ===========================================================================
ensure_config() {
  if [ ! -f "$ENVFILE" ]; then
    install -m 600 "$ADDON/signal.env.example" "$ENVFILE" \
      || fail "could not create $ENVFILE"
  fi
  chmod 600 "$ENVFILE" 2>/dev/null || true

  # Stop on the VALUES being absent, not on the file. Checking only for a
  # missing file means the message fires once per clone and never again --
  # the exact bug bootstrap.sh had, where a second run sailed past a copy
  # still identical to the template.
  local sel missing=""
  sel="$(agents_selected)"
  [ -n "$sel" ] || missing="${missing}      SIGNAL_AGENT (hermes, openclaw or both)\n"
  [ -n "$(envval SIGNAL_ALLOWED_USERS)" ] || missing="${missing}      SIGNAL_ALLOWED_USERS (your own number)\n"
  for a in $sel; do
    [ -n "$(number_for "$a")" ] || missing="${missing}      SIGNAL_$(echo "$a" | tr '[:lower:]' '[:upper:]')_NUMBER\n"
  done

  [ -n "$missing" ] || return 0

  printf '\n' >&2
  cat >&2 <<EOF
  STOP -- this is your turn, and the add-on waits here until you take it.

  $ENVFILE is waiting on you. These are still blank:

EOF
  printf "$missing" >&2
  cat >&2 <<EOF

  Open it in an editor:

      \$EDITOR $ENVFILE

  The decision that matters is SIGNAL_MODE, because Signal has no bots and
  no free second identity -- an account is a phone number:

    note-to-self   Link to YOUR OWN number and talk to the agent by
                   messaging yourself. Costs nothing: no second number, no
                   new SIM, no captcha. Hermes only -- it supports this
                   directly; OpenClaw cannot.

    dedicated      The agent gets its own number. Needed for OpenClaw, and
                   for running both agents on Signal.

  Every number is E.164: a leading +, country code, no spaces or dashes.
  SIGNAL_ALLOWED_USERS cannot be blank -- a live agent has shell access, so
  who may message it is the only thing protecting it.

  The full explanation, including what Note to Self costs you, is in
  addons/signal/README.md.

  Then:  ./scripts/addon-signal.sh link

EOF
  exit 2
}

# Everything that must be true of signal.env before we act on it. Separate
# from ensure_config so a half-filled file is rejected with a reason rather
# than silently re-triggering the exit-2 message.
validate_config() {
  local sel mode n
  sel="$(agents_selected)"
  mode="$(envval SIGNAL_MODE)"

  case "$mode" in
    note-to-self|dedicated) ;;
    *) fail "SIGNAL_MODE is '${mode:-blank}'. It must be note-to-self or dedicated.
See addons/signal/README.md." ;;
  esac

  # The combination that cannot work. Refuse it here rather than let Pi
  # build something that comes up mute: OpenClaw ignores the account
  # owner's own messages by design, so note-to-self plus OpenClaw is an
  # agent that will never answer, with nothing failing anywhere to say so.
  case "$sel" in
    *openclaw*)
      [ "$mode" != "note-to-self" ] || fail "SIGNAL_MODE=note-to-self cannot work with OpenClaw.

OpenClaw deliberately ignores messages from its own account owner (loop
protection), so an agent linked to your own number would never answer you.
Its own documentation says to use a separate bot number for this.

Either set SIGNAL_AGENT=hermes, which does support Note to Self, or set
SIGNAL_MODE=dedicated and give OpenClaw its own number." ;;
  esac

  for a in $sel; do
    n="$(number_for "$a")"
    valid_e164 "$n" || fail "the $a number is not in E.164 form.

It must be a leading +, then country code and number, with no spaces,
dashes or brackets -- for example +15551234567. Signal compares these as
strings, so a number that merely looks right to a human will silently
match nobody."
  done

  # Every entry of the allowlist, same reasoning.
  local IFS=,
  for n in $(envval SIGNAL_ALLOWED_USERS); do
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    [ -n "$n" ] || continue
    valid_e164 "$n" || fail "SIGNAL_ALLOWED_USERS contains an entry that is not E.164.
Each entry needs a leading + and digits only, comma-separated."
  done
}

# Push signal.env into the VM. Pi reads it from there; it never reaches the
# host-side agents.env, which is the base build's file.
push_env() {
  limactl copy "$ENVFILE" "$INSTANCE:/tmp/signal.env" \
    || fail "could not copy $ENVFILE into the VM."
  # NOTE: single-quoted guest script. No apostrophes below this line until
  # the closing quote -- one contraction silently runs the rest on the host.
  limactl shell "$INSTANCE" -- bash -eo pipefail -c '
    install -d -m 0700 "$HOME/.config/agent-sandbox"
    install -m 0600 /tmp/signal.env "$HOME/.config/agent-sandbox/signal.env"
    rm -f /tmp/signal.env
  ' || fail "could not install signal.env in the VM."
}

# Is signal-cli linked? The question every other command needs answered,
# and it must be answered WITHOUT printing the number: listAccounts output
# is matched inside the guest and only a count crosses back.
#
# Counted with `grep -c ... || true` rather than `|| echo 0`. grep -c
# already prints 0 when it matches nothing AND exits 1, so an `|| echo 0`
# fallback appends a second zero -- the caller then compares "00" against
# "0", finds them different, and reports an unlinked account as linked.
# Found by testing this function rather than reading it.
linked_accounts() {
  local n
  n="$(limactl shell "$INSTANCE" -- bash -lc \
        'command -v signal-cli >/dev/null 2>&1 || exit 0
         signal-cli listAccounts 2>/dev/null | grep -cE "^(Number|Account|Path):|^\+[0-9]" || true' \
        2>/dev/null | tr -dc '0-9')"
  printf '%s' "${n:-0}"
}

# ===========================================================================
cmd_link() {
  ensure_config
  validate_config
  vm_running || fail "instance '$INSTANCE' is not running. Build the base system first."

  step "Linking signal-cli to Signal"

  cat <<EOF

  This links signal-cli to a Signal account as a secondary device -- the
  same mechanism Signal Desktop uses. You scan a QR code with your phone.

  It happens INSIDE the VM on purpose. The account keys it creates are the
  linked device, and they belong where the agents run, not on this host.
  Only the short-lived link URI crosses the boundary, to be drawn as a QR
  code on your screen.

EOF

  # signal-cli must exist before it can link, and on a VM where Pi has not
  # run yet it will not. Install it here rather than making the user run
  # `install` first -- the ordering "link, then install" is what the README
  # documents, and reversing it to satisfy a dependency would be a worse
  # user experience than this script doing the work.
  if ! limactl shell "$INSTANCE" -- bash -lc 'command -v signal-cli >/dev/null 2>&1'; then
    step "Installing signal-cli first (3-8 minutes)"
    printf '      %sdownloads ~190 MB and prints little while it works%s\n\n' "$Y" "$Z"
    # Documented in spec.md too, because Pi re-applies it idempotently in
    # setup-signal.sh. Doing it here as well is what makes `link` work on a
    # VM Pi has not touched yet.
    limactl shell "$INSTANCE" -- bash -eo pipefail -c '
      set -u
      sudo curl -fsSL --max-time 120 -o /etc/apt/trusted.gpg.d/morph027-signal-cli.asc \
        https://packaging.gitlab.io/signal-cli/gpg.key
      echo "deb https://packaging.gitlab.io/signal-cli signalcli main" \
        | sudo tee /etc/apt/sources.list.d/morph027-signal-cli.list >/dev/null
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openjdk-25-jre-headless
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq signal-cli-jre
    ' || fail "could not install signal-cli in the VM.

If openjdk-25-jre-headless was not found, the noble-updates pocket is
missing -- Java 25 is not in base noble."

    # The one command that proves the native library loaded. On arm64 a
    # wrong build fails here with UnsatisfiedLinkError, and finding that
    # out now is far cheaper than finding it out mid-link.
    ver="$(limactl shell "$INSTANCE" -- bash -lc 'signal-cli --version 2>&1' | head -1)"
    case "$ver" in
      *signal-cli*) ok "$ver" ;;
      *) fail "signal-cli is installed but will not run: $ver

If this mentions UnsatisfiedLinkError, the package does not match this
VM's architecture. See the fallback in addons/signal/README.md." ;;
    esac
  fi

  command -v qrencode >/dev/null 2>&1 || fail "qrencode is not installed on this host.

It renders the link QR code for you to scan. signal-cli prints one itself
only when its output is a terminal, which it is not when a script captures
it -- so this script draws the code instead.

  Debian/Ubuntu:  sudo apt install qrencode
  macOS:          brew install qrencode"

  step "Starting the link"
  printf '      %sthe QR code appears below in a few seconds%s\n' "$Y" "$Z"

  # Ask the VM to start a link and hand back only the URI. signal-cli runs
  # until linking completes or the timeout expires -- the wiki is explicit
  # that killing it early leaves a half-linked account, so the URI has to
  # be read while the process keeps running. A FIFO would be neater; a
  # background process plus a polled file is portable between the GNU and
  # BSD userlands this repo has to work on.
  limactl shell "$INSTANCE" -- bash -lc '
    rm -f ~/.signal-link-uri ~/.signal-link-done
    nohup signal-cli link -n "agent-sandbox" > ~/.signal-link-uri 2>&1 &
    echo started
  ' >/dev/null 2>&1 || fail "could not start the link in the VM."

  uri=""
  for _ in $(seq 1 30); do
    sleep 2
    uri="$(limactl shell "$INSTANCE" -- bash -lc \
      'grep -o "sgnl://linkdevice?[^ ]*" ~/.signal-link-uri 2>/dev/null | head -1' \
      2>/dev/null | tr -d '[:space:]')"
    [ -n "$uri" ] && break
  done

  [ -n "$uri" ] || {
    limactl shell "$INSTANCE" -- bash -lc 'pkill -f "signal-cli link" 2>/dev/null; cat ~/.signal-link-uri 2>/dev/null | head -5' >&2
    fail "signal-cli did not produce a link URI (output above).

A 'Connection closed' error here usually is NOT a Signal outage: it is the
proxy path failing. See addons/signal/README.md."
  }

  printf '\n'
  qrencode -t UTF8 "$uri"
  cat <<EOF

  ${B}Scan the code above with your phone:${Z}

      Signal  ->  Settings  ->  Linked devices  ->  +

  Then wait here. This finishes by itself once your phone confirms; it
  does not need another keystroke. Waiting up to 5 minutes.

  If the code looks mangled, make this window wider and re-run -- it is
  drawn with block characters and needs the room.

EOF

  # Wait for signal-cli to exit, which is how it reports success. Do not
  # kill it early: the wiki warns that interrupting leaves the account
  # half-linked.
  linked=0
  for _ in $(seq 1 60); do
    sleep 5
    if ! limactl shell "$INSTANCE" -- bash -lc 'pgrep -f "signal-cli link" >/dev/null 2>&1'; then
      linked=1; break
    fi
  done

  if [ "$linked" != "1" ]; then
    limactl shell "$INSTANCE" -- bash -lc 'pkill -f "signal-cli link" 2>/dev/null' >/dev/null 2>&1
    fail "the link did not complete within 5 minutes.

Nothing is broken -- the code simply expired. Re-run this command for a
fresh one. If your phone said it linked, run 'verify' to check."
  fi

  # Trust the account list, not the exit of a backgrounded process.
  [ "$(linked_accounts)" != "0" ] || {
    limactl shell "$INSTANCE" -- bash -lc 'tail -5 ~/.signal-link-uri 2>/dev/null' >&2
    fail "signal-cli exited but no account is registered (output above)."
  }

  # Record that linking happened, without recording what was linked. The
  # number is already in this file; this flag only distinguishes "linked"
  # from "not yet" for the scripts that follow.
  stamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  for a in $(agents_selected); do
    key="SIGNAL_$(echo "$a" | tr '[:lower:]' '[:upper:]')_LINKED"
    if grep -qE "^$key=" "$ENVFILE"; then
      sed -i.bak "s|^$key=.*|$key=\"$stamp\"|" "$ENVFILE" && rm -f "$ENVFILE.bak"
    else
      printf '%s="%s"\n' "$key" "$stamp" >> "$ENVFILE"
    fi
  done
  chmod 600 "$ENVFILE"

  limactl shell "$INSTANCE" -- bash -lc 'rm -f ~/.signal-link-uri' >/dev/null 2>&1

  ok "linked"
  cat <<EOF

  ${B}Next:${Z}  ./scripts/addon-signal.sh install

EOF
}

# ===========================================================================
cmd_install() {
  ensure_config
  validate_config

  step "Preconditions"

  vm_running || fail "instance '$INSTANCE' is not running. Build the base system first."

  limactl shell "$INSTANCE" -- bash -lc 'test -x "$HOME/agent-bootstrap/setup.sh"' 2>/dev/null \
    || fail "the base build is not finished -- ~/agent-bootstrap/setup.sh is missing
in the VM. Run ./bootstrap.sh and ./scripts/pi-session.sh build first."
  ok "base build present"

  [ "$(linked_accounts)" != "0" ] || {
    cat >&2 <<EOF

  No Signal account is linked yet. That is your step, and it needs your
  phone:

      ./scripts/addon-signal.sh link

EOF
    exit 2
  }
  ok "signal-cli is linked"

  # The allowlist precondition. Once this add-on is in, whoever can message
  # the agent can run shell commands on it, so an empty allowlist is not a
  # configuration detail -- it is the whole exposure. validate_config has
  # already checked the form; this checks it exists at all.
  [ -n "$(envval SIGNAL_ALLOWED_USERS)" ] \
    || fail "SIGNAL_ALLOWED_USERS is empty in $ENVFILE.

A live agent has shell access and no permission prompts. Who may message
it is the only control, so this cannot be left open."
  ok "allowlist is not empty"

  for a in $(agents_selected); do ok "$a will get a Signal channel"; done

  step "Base system still verifying"
  BASELOG="$(mktemp -t signal-base-verify.XXXXXX)"
  # Anything that can outlast a user's patience says how long it will be.
  # This runs the whole base suite with its output redirected, so it prints
  # nothing for minutes and reads like a hang.
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

  step "Pushing the add-on into $INSTANCE"
  push_env
  ok "signal.env installed at ~/.config/agent-sandbox/signal.env (0600)"

  step "Staging the spec for Pi"
  limactl copy "$ADDON/spec.md" "$INSTANCE:agent-bootstrap/SIGNAL-ADDON.md" \
    || fail "could not copy the add-on spec into the VM."
  ok "spec placed at ~/agent-bootstrap/SIGNAL-ADDON.md"

  # Stop here, deliberately. Everything above needed a phone, a camera, or
  # a file only the user can edit. Everything below is supervising Pi,
  # which is a coding agent's job.
  step "Your part is done -- hand over to your coding agent"
  cat <<EOF

  signal-cli is linked and Pi has its spec. What remains is a build and a
  review of it: roughly 5-15 minutes of Pi working, then reading what it
  claims against what the checks measure.

  ${B}Tell your coding agent:${Z}

      Install the Signal add-on: run ./scripts/addon-signal.sh build,
      then supervise Pi and verify it as addons/signal/README.md
      describes.

  It will come back to you once, at the end, with the one check no script
  can do: message the agent on Signal and watch it answer.

EOF
}

# ===========================================================================
# The agent's half: drive Pi, then report.
# ===========================================================================
cmd_build() {
  vm_running || fail "instance '$INSTANCE' is not running."

  limactl shell "$INSTANCE" -- bash -lc 'test -f "$HOME/agent-bootstrap/SIGNAL-ADDON.md"' 2>/dev/null \
    || fail "the add-on spec is not in the VM, so the setup half has not run.
The user needs to do their part first -- see addons/signal/README.md:
./scripts/addon-signal.sh link, then install."

  limactl shell "$INSTANCE" -- bash -lc 'test -s "$HOME/.config/agent-sandbox/signal.env"' 2>/dev/null \
    || fail "signal.env is not in the VM. Run the install step first."

  [ "$(linked_accounts)" != "0" ] \
    || fail "no Signal account is linked. The user must run 'link' first."

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
    "New task, from ~/agent-bootstrap/SIGNAL-ADDON.md -- not AGENTS.md. Build what it describes, leaving setup.sh, the Telegram config and the rest of the base build untouched." \
    || warn "the Pi turn returned non-zero -- read ./scripts/pi-session.sh summary before concluding anything."

  step "Next"
  cat <<EOF
  Read what Pi claims:   ./scripts/pi-session.sh summary
  What it actually did:  ./scripts/pi-session.sh steps
  Then check it:         ./scripts/addon-signal.sh verify --live --base

  A summary is a claim; verify.sh is evidence. Push back with
  ./scripts/pi-session.sh say "..." rather than fixing the VM by hand.
EOF
}

# ===========================================================================
cmd_verify() {
  # Pass flags through. Swallowing them here would silently disable --live,
  # which is the only check that exercises the link.
  exec "$ADDON/verify.sh" "$INSTANCE" "$@"
}

# ===========================================================================
cmd_remove() {
  vm_running || fail "instance '$INSTANCE' is not running."

  step "Removing the add-on from $INSTANCE"

  # If Pi put the add-on's work in setup.sh instead of its own script, the
  # base deliverable now rebuilds this on every run and removing files is
  # not enough. Say so rather than reporting a clean removal.
  if limactl shell "$INSTANCE" -- bash -lc 'grep -qi "signal" "$HOME/agent-bootstrap/setup.sh" 2>/dev/null'; then
    warn "~/agent-bootstrap/setup.sh mentions signal -- Pi put add-on work in the"
    warn "base deliverable, against its spec. Removing files will not stick: the"
    warn "next run of setup.sh puts them back. Have Pi take it out of setup.sh."
  fi

  limactl shell "$INSTANCE" -- bash -lc '
    set -u
    systemctl --user disable --now signal-cli.service 2>/dev/null || true
    rm -f "$HOME/.config/systemd/user/signal-cli.service"
    rm -f "$HOME/.config/agent-sandbox/signal.env"
    rm -f "$HOME/agent-bootstrap/setup-signal.sh" "$HOME/agent-bootstrap/SIGNAL-ADDON.md"
    systemctl --user daemon-reload 2>/dev/null || true
  ' || warn "some files could not be removed; check by hand."
  ok "daemon stopped and add-on files removed"

  # Deliberately NOT removed: the signal-cli data directory. It holds the
  # linked device's keys, and deleting it silently makes the user re-scan a
  # QR code to come back. Removing an add-on should not destroy something
  # only a human can recreate.
  warn "The signal-cli account data was NOT deleted. It is what makes this a"
  warn "linked device, and re-creating it means another QR scan. To remove it:"
  warn "  unlink from your phone first (Signal -> Settings -> Linked devices),"
  warn "  then delete ~/.local/share/signal-cli inside the VM."

  warn "Channel config was NOT removed from the agents, because Pi wrote it"
  warn "and knows its shape. Ask it to undo that:"
  warn "  ./scripts/pi-session.sh say \"Remove the Signal channel configuration from both agents, leaving Telegram untouched, then restart the gateways once.\""

  cat <<EOF

  ${B}This does not unlink anything at Signal's end.${Z} Until you remove the
  linked device from your phone, Signal still considers it attached:

      Signal -> Settings -> Linked devices -> remove "agent-sandbox"

EOF
}

case "${1:-}" in
  link)    cmd_link ;;
  install) cmd_install ;;
  build)   cmd_build ;;
  verify)  shift; cmd_verify "$@" ;;
  remove)  cmd_remove ;;
  *)
    sed -n '3,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
