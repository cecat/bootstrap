#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Google access for the OpenClaw agent. OPTIONAL -- the base build neither
# needs nor knows about this, and the Hermes agent is untouched by it.
#
# The user does the first two, because they need a browser and an account:
#   ./scripts/addon-google-openclaw.sh auth      one-time consent
#   ./scripts/addon-google-openclaw.sh install   preconditions, push, stage
#
# Then their coding agent takes over, because supervising Pi is its job:
#   ./scripts/addon-google-openclaw.sh build     drive Pi
#   ./scripts/addon-google-openclaw.sh verify    the evidence
#   ./scripts/addon-google-openclaw.sh remove    undo it
#
# This is a SEPARATE add-on from google-hermes, not a variant of it: the
# two agents reach Google by entirely different mechanisms. See PLAN.md.
#
# Nothing here modifies the base system or the Hermes add-on.
#
# NOT YET BUILT -- see PLAN.md. This script has never been run.
# ---------------------------------------------------------------------------
set -uo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ADDON/../.." && pwd)"
cd "$REPO"
INSTANCE="${AGENTS_VM:-agents}"
ENVFILE="config/openclaw-google.env"

# Pinned deliberately, with the digest the vendor publishes. gog is young
# and moves fast -- v0.48.0 was released the day before this was written --
# so an unpinned install would drift under us. Bumping it is a one-line
# change plus a re-verify.
GOG_VERSION="0.48.0"
# arm64 only. Downloaded and checked by hand on 2026-11-11: the tarball
# matched this digest, and the binary inside is a statically linked
# aarch64 ELF with no glibc dependency. No amd64 digest is pinned because
# nobody has run this add-on on amd64 -- that path verifies against the
# vendor's published checksums.txt instead, which covers every asset.
GOG_SHA256_ARM64="fc40524368d2cb6213bdfe0b736b5884e1b55c6368706d7a285542cb7e559b68"
GOG_URL_BASE="https://github.com/openclaw/gogcli/releases/download/v${GOG_VERSION}"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

# Read one value WITHOUT executing the file. Sourcing would be simpler and
# is what the base scripts do for agents.env, but this file holds values a
# user types and pastes: one backtick or $(...) in a mistyped entry would
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

# Write a value back into the env file, creating the key if absent. Used
# for the generated keyring password and the auth-completed marker.
envset() {
  local k="$1" v="$2"
  [ -f "$ENVFILE" ] || install -m 600 /dev/null "$ENVFILE"
  if grep -qE "^$k=" "$ENVFILE"; then
    # The value may contain / and & -- use a delimiter unlikely to appear
    # and escape what sed would otherwise interpret.
    local esc; esc="$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')"
    sed -i.bak "s|^$k=.*|$k=\"$esc\"|" "$ENVFILE" && rm -f "$ENVFILE.bak"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$ENVFILE"
  fi
  chmod 600 "$ENVFILE"
}

vm_running() {
  [ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ]
}

# A Google address, loosely. Not RFC-complete on purpose: the point is to
# catch a blank, a username with no domain, or a stray space -- all of
# which otherwise surface much later as an opaque gog error.
valid_email() {
  case "$1" in
    *@*.*) case "$1" in *" "*|*$'\t'*) return 1 ;; esac; [ "${#1}" -ge 6 ] ;;
    *) return 1 ;;
  esac
}

# ===========================================================================
# The config handshake. Same shape as bootstrap.sh: create the file, say
# plainly what is needed, exit 2, and wait to be run again.
# ===========================================================================
ensure_config() {
  if [ ! -f "$ENVFILE" ]; then
    install -m 600 "$ADDON/openclaw-google.env.example" "$ENVFILE" \
      || fail "could not create $ENVFILE"
  fi
  chmod 600 "$ENVFILE" 2>/dev/null || true

  # Stop on the VALUE being absent, not on the file. Checking only for a
  # missing file means the message fires once per clone and never again --
  # the exact bug bootstrap.sh had, where a second run sailed past a copy
  # still identical to the template.
  [ -n "$(envval GOOGLE_ACCOUNT)" ] && return 0

  cat >&2 <<EOF

  STOP -- this is your turn, and the add-on waits here until you take it.

  It needs a Google account for the OpenClaw agent, and a Google Cloud
  OAuth client for it. Only you can make those. The steps are in
  addons/google-openclaw/README.md -- about fifteen minutes in the
  browser, once.

  Then fill in GOOGLE_ACCOUNT in:

      \$EDITOR $ENVFILE

  Use a DEDICATED account, not your personal one: the agent's files stay
  out of your Drive, and mail it sends comes from the agent rather than
  from you.

  While you are in there, two settings are worth a moment:

    GOOGLE_SERVICES      which Google services the agent may touch.
                         Consent asks for exactly these, so start narrow.

    GOOGLE_ALLOW_SEND    leave at "no" unless you are sure. The agent can
                         still write drafts for you to approve; it just
                         cannot put mail in front of a real person by
                         itself.

  Do not paste any of this into a chat with an agent -- a secret in a
  conversation is a secret in a transcript.

  Then:  ./scripts/addon-google-openclaw.sh auth

EOF
  exit 2
}

validate_config() {
  local acct send
  acct="$(envval GOOGLE_ACCOUNT)"
  valid_email "$acct" || fail "GOOGLE_ACCOUNT does not look like an address.

Expected something like agent-name@gmail.com, with no spaces."

  send="$(envval GOOGLE_ALLOW_SEND)"
  case "$send" in
    yes|no|"") ;;
    *) fail "GOOGLE_ALLOW_SEND is '$send'. It must be yes or no." ;;
  esac

  local services; services="$(envval GOOGLE_SERVICES)"
  [ -n "$services" ] \
    || fail "GOOGLE_SERVICES is empty. At minimum this add-on needs one
service -- see $ENVFILE for the list."

  # Reject a service gog does not know before sending anyone to the Cloud
  # Console. A typo here is otherwise discovered at consent time, after
  # the APIs have been enabled and against a ten-minute handshake clock.
  # This list is gog's, from its own services table.
  local known=" gmail calendar chat drive docs slides contacts tasks sheets forms meet photos "
  local s IFS=,
  for s in $services; do
    s="$(printf '%s' "$s" | tr -d '[:space:]')"
    [ -n "$s" ] || continue
    case "$known" in
      *" $s "*) ;;
      *) fail "GOOGLE_SERVICES contains '$s', which gog does not recognise.

Valid values:$known
Each one maps to a Google API you must enable in the Cloud Console --
see the table in addons/google-openclaw/README.md." ;;
    esac
  done

  # docs and sheets go through Drive, so gog asks for the drive scope
  # whether or not it is listed. Saying so here beats the user wondering
  # why the consent screen mentions Drive when they never asked for it.
  case ",$services," in
    *,docs,*|*,sheets,*)
      case ",$services," in
        *,drive,*) ;;
        *) warn "GOOGLE_SERVICES has docs or sheets but not drive. gog requests the
          Drive scope for both anyway, and the Cloud Console needs the Drive
          API enabled, so add 'drive' to the list to keep the two in step." ;;
      esac ;;
  esac

  # The Hermes add-on must not be using the same account. Two agents on one
  # Google account would both act as the same identity, and the whole point
  # of this add-on is that they do not.
  if [ -f config/google.env ]; then
    local hermes_acct
    hermes_acct="$(awk -v k="GOOGLE_ACCOUNT_EMAIL" '
      index($0, k "=") == 1 { v = substr($0, length(k) + 2)
        gsub(/^[ \t"'"'"']+|[ \t\r"'"'"']+$/, "", v); print v; exit }' config/google.env 2>/dev/null)"
    if [ -n "$hermes_acct" ] && [ "$hermes_acct" = "$acct" ]; then
      fail "GOOGLE_ACCOUNT is the same address the Hermes add-on uses.

Give the OpenClaw agent its own account. Sharing one means both agents
send as the same identity and write into the same Drive, which is the
situation this add-on exists to avoid."
    fi
  fi
}

# ===========================================================================
# Install gog into the VM. Download, verify, then execute -- never pipe.
# ===========================================================================
install_gog() {
  if limactl shell "$INSTANCE" -- bash -lc 'command -v gog >/dev/null 2>&1'; then
    local have
    have="$(limactl shell "$INSTANCE" -- bash -lc 'gog --version 2>&1 | head -1' | tr -d '\r')"
    ok "gog already installed: $have"
    return 0
  fi

  step "Installing gog $GOG_VERSION into $INSTANCE"
  printf '      %sdownloads ~13 MB%s\n' "$Y" "$Z"

  # Architecture follows the guest, which follows the host. The digest
  # below is the arm64 one, measured on this machine; amd64 is verified
  # against the vendor's own checksums.txt instead of a value pinned here,
  # because nobody has run this on amd64 yet and a wrong pin would fail
  # closed with a confusing message.
  # NOTE: single-quoted guest script. No apostrophes below this line until
  # the closing quote -- one contraction silently runs the rest on the host.
  limactl shell "$INSTANCE" -- bash -eo pipefail -c '
    set -u
    ver="$1"; want_arm64="$2"; base="$3"
    case "$(uname -m)" in
      aarch64|arm64) asset="gogcli_${ver}_linux_arm64.tar.gz"; want="$want_arm64" ;;
      x86_64|amd64)  asset="gogcli_${ver}_linux_amd64.tar.gz"; want="" ;;
      *) echo "unsupported architecture: $(uname -m)" >&2; exit 1 ;;
    esac

    tmp="$(mktemp -d)"
    trap "rm -rf $tmp" EXIT
    cd "$tmp"

    curl -fsSL --max-time 300 -o "$asset" "$base/$asset"
    curl -fsSL --max-time 60  -o checksums.txt "$base/checksums.txt"

    got="$(sha256sum "$asset" | cut -d" " -f1)"
    if [ -n "$want" ]; then
      [ "$got" = "$want" ] || { echo "SHA256 mismatch for $asset" >&2; exit 1; }
    fi
    # Belt and braces: the vendor publishes checksums.txt covering every
    # asset, so check against that too. On amd64 it is the only check.
    grep -F "$got" checksums.txt >/dev/null \
      || { echo "SHA256 not found in the published checksums.txt" >&2; exit 1; }

    tar xzf "$asset"
    sudo install -m 0755 gog /usr/local/bin/gog
  ' _ "$GOG_VERSION" "$GOG_SHA256_ARM64" "$GOG_URL_BASE" \
    || fail "could not install gog in the VM."

  # Running it is the only thing that proves the binary matches the
  # architecture: a wrong build fails here rather than much later, in the
  # middle of a consent flow.
  local ver
  ver="$(limactl shell "$INSTANCE" -- bash -lc 'gog --version 2>&1 | head -1' | tr -d '\r')"
  case "$ver" in
    *[0-9]*) ok "gog installed: $ver" ;;
    *) fail "gog installed but will not run: $ver" ;;
  esac
}

# The three variables gog needs on a headless box, in a 0600 file the
# systemd units read. Not inlined into a unit: that puts the password in
# `systemctl show` output.
push_env() {
  local pw
  pw="$(envval GOOGLE_KEYRING_PASSWORD)"
  if [ -z "$pw" ]; then
    pw="$(openssl rand -hex 32)" || fail "could not generate a keyring password."
    envset GOOGLE_KEYRING_PASSWORD "$pw"
    ok "generated a keyring password (stored in $ENVFILE, 0600)"
  fi

  limactl copy "$ENVFILE" "$INSTANCE:/tmp/openclaw-google.env" \
    || fail "could not copy $ENVFILE into the VM."
  limactl shell "$INSTANCE" -- bash -eo pipefail -c '
    install -d -m 0700 "$HOME/.config/agent-sandbox"
    install -m 0600 /tmp/openclaw-google.env "$HOME/.config/agent-sandbox/openclaw-google.env"
    rm -f /tmp/openclaw-google.env
  ' || fail "could not install the env file in the VM."
}

# Is gog authenticated for the configured account? Answered inside the
# guest so no address or token crosses back -- only a yes/no.
#
# `|| true`, never `|| echo 0`: grep -c already prints 0 on no match and
# exits 1, so an echo fallback yields "00" and every comparison downstream
# is wrong. That bug shipped in the Signal add-on and was caught by test.
auth_done() {
  limactl shell "$INSTANCE" -- bash -lc '
    command -v gog >/dev/null 2>&1 || exit 0
    set -a; . "$HOME/.config/agent-sandbox/openclaw-google.env" 2>/dev/null; set +a
    export GOG_KEYRING_BACKEND=file
    export GOG_KEYRING_PASSWORD="${GOOGLE_KEYRING_PASSWORD:-}"
    export DBUS_SESSION_BUS_ADDRESS=disabled:
    gog --no-input --json auth doctor --check 2>/dev/null \
      | jq -se "length == 1 and .[0].status == \"ok\"" >/dev/null 2>&1 && echo yes || true
  ' 2>/dev/null | tr -d '[:space:]'
}

# ===========================================================================
cmd_auth() {
  ensure_config
  validate_config
  vm_running || fail "instance '$INSTANCE' is not running. Build the base system first."

  install_gog
  push_env

  if [ "$(auth_done)" = "yes" ]; then
    ok "already authenticated -- nothing to do."
    printf '\n  Next:  ./scripts/addon-google-openclaw.sh install\n\n'
    return 0
  fi

  step "Google consent"

  local acct services send args
  acct="$(envval GOOGLE_ACCOUNT)"
  services="$(envval GOOGLE_SERVICES)"
  send="$(envval GOOGLE_ALLOW_SEND)"
  args="--services $services"
  # gog accepts exactly: full|readonly|send|read-send. Not "read", which
  # it rejects outright -- confirmed from `gog auth add --help`.
  #
  # There is no draft-but-cannot-send scope. Google does not publish one:
  # creating a draft needs gmail.modify, and anything with modify can also
  # send. So an agent that drafts for human approval necessarily HOLDS the
  # ability to send, and the restraint is an instruction in its SOUL.md,
  # not a boundary the grant enforces. Decided knowingly 2026-11-11.
  #
  # GOOGLE_ALLOW_SEND therefore records INTENT, and verify.sh asserts the
  # grant matches it. "no" still narrows to readonly, which is right for
  # an agent that only reads -- it just cannot draft either.
  [ "$send" = "yes" ] || args="$args --gmail-scope readonly"

  cat <<EOF

  Consent happens INSIDE the VM, in two steps, because the credentials it
  produces belong where the agent runs. Only a URL crosses to you.

  You will need a browser, and about three minutes. There is a ten-minute
  timer on the handshake, so do not start this and walk away.

EOF

  # The OAuth client has to be in place first. gog stores it in its own
  # config dir; the user downloads the JSON from the Cloud Console exactly
  # as they do for the Hermes add-on.
  #
  # Selecting it is fiddly for one reason: the Hermes add-on keeps ITS
  # client in the same directory, under the same client_secret_*.json
  # name. Globbing and taking the first match would hand this agent the
  # other agent's credentials -- which Google would accept, because a
  # client id identifies the app, not the account. The user would then
  # consent as the right account against the wrong project and wonder why
  # two agents share a quota.
  #
  # So: ignore any client already named in the Hermes config, and if more
  # than one candidate remains, stop and ask rather than guessing.
  local hermes_cid cj n
  hermes_cid="$(awk -v k="GOOGLE_CLIENT_ID" '
    index($0, k "=") == 1 { v = substr($0, length(k) + 2)
      gsub(/^[ \t"'"'"']+|[ \t\r"'"'"']+$/, "", v); print v; exit }' config/google.env 2>/dev/null)"

  local cands=()
  for f in "$REPO"/secrets/client_secret_*.json; do
    [ -e "$f" ] || continue
    if [ -n "$hermes_cid" ] && grep -qF "$hermes_cid" "$f" 2>/dev/null; then
      continue   # Gandalf's; not this agent's
    fi
    cands+=("$f")
  done

  n="${#cands[@]}"
  if [ "$n" -eq 0 ]; then
    cat >&2 <<EOF
  No OAuth client JSON for this agent found in secrets/.

EOF
    [ -n "$hermes_cid" ] && printf '  (There is one there already, but it belongs to the Hermes add-on.\n  This agent needs its own, created under its own Google account.)\n\n' >&2
    cat >&2 <<EOF
  In Google Cloud Console, signed in as the AGENT'S account, create an
  OAuth client of type "Desktop app", press the download icon beside it,
  and put the file in  secrets/  -- leave the name as Google gives it.
  That directory is gitignored and nothing retypes the values.

  Full steps: addons/google-openclaw/README.md

EOF
    exit 2
  elif [ "$n" -gt 1 ]; then
    printf '  More than one candidate OAuth client in secrets/:\n\n' >&2
    printf '      %s\n' "${cands[@]##*/}" >&2
    cat >&2 <<EOF

  Refusing to guess which belongs to this agent -- picking wrong would
  authorise it against another project. Move the ones you are not using
  out of secrets/, leaving exactly one, and run this again.

EOF
    exit 2
  fi
  cj="${cands[0]}"
  ok "using OAuth client ${cj##*/}"
  limactl copy "$cj" "$INSTANCE:/tmp/gog-client.json" \
    || fail "could not copy the OAuth client into the VM."
  limactl shell "$INSTANCE" -- bash -lc '
    set -a; . "$HOME/.config/agent-sandbox/openclaw-google.env" 2>/dev/null; set +a
    export GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD="${GOOGLE_KEYRING_PASSWORD:-}"
    export DBUS_SESSION_BUS_ADDRESS=disabled:
    gog auth credentials set /tmp/gog-client.json >/dev/null 2>&1
    rm -f /tmp/gog-client.json
  ' || fail "gog would not accept the OAuth client JSON."
  ok "OAuth client installed in the VM"

  # --- step 1: get the consent URL out of the VM ---------------------------
  step "Step 1 of 2 -- the consent URL"

  local urlfile="$REPO/config/.openclaw-google-consent-url.txt"
  limactl shell "$INSTANCE" -- bash -lc "
    set -a; . \"\$HOME/.config/agent-sandbox/openclaw-google.env\" 2>/dev/null; set +a
    export GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=\"\${GOOGLE_KEYRING_PASSWORD:-}\"
    export DBUS_SESSION_BUS_ADDRESS=disabled:
    gog auth add '$acct' $args --remote --step 1 2>&1
  " > "$urlfile.raw" 2>&1 || true

  local url
  url="$(grep -oE 'https://accounts\.google\.com/[^[:space:]]+' "$urlfile.raw" | head -1)"
  if [ -z "$url" ]; then
    head -20 "$urlfile.raw" >&2
    rm -f "$urlfile.raw"
    fail "gog did not produce a consent URL (output above)."
  fi
  printf '%s\n' "$url" > "$urlfile"
  chmod 600 "$urlfile"
  rm -f "$urlfile.raw"

  # Written to a file rather than printed, because the user cannot copy out
  # of his terminal and this URL is several hundred characters. Opening it
  # in an editor is the one reliable way to get it into a browser.
  cat <<EOF

  ${B}The consent URL has been written to:${Z}

      config/.openclaw-google-consent-url.txt

  Open that file, copy the URL into a browser, and sign in as the agent's
  Google account -- ${B}not your personal one${Z}. Approve the access it asks
  for.

  Your browser will then try to reach a 127.0.0.1 address and fail to
  load. ${B}That is expected${Z} -- nothing is listening there. What matters is
  the URL in the address bar.

  ${B}Copy that whole failed URL${Z} and save it into:

      config/.openclaw-google-redirect-url.txt

  Then run this command again. It will pick up from there.

  You have ten minutes from now before the handshake expires. If it does,
  re-run and you will get a fresh URL.

EOF

  local redirfile="$REPO/config/.openclaw-google-redirect-url.txt"
  [ -f "$redirfile" ] || exit 2

  # --- step 2: exchange it, inside the VM ----------------------------------
  step "Step 2 of 2 -- completing consent"

  local redir
  redir="$(tr -d '[:space:]' < "$redirfile")"
  case "$redir" in
    http*code=*) ;;
    *) fail "config/.openclaw-google-redirect-url.txt does not look like the
redirect URL. It should start with http and contain code=..." ;;
  esac

  limactl shell "$INSTANCE" -- bash -lc "
    set -a; . \"\$HOME/.config/agent-sandbox/openclaw-google.env\" 2>/dev/null; set +a
    export GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=\"\${GOOGLE_KEYRING_PASSWORD:-}\"
    export DBUS_SESSION_BUS_ADDRESS=disabled:
    gog auth add '$acct' $args --remote --step 2 --auth-url '$redir' 2>&1 | tail -5
  " || warn "step 2 returned non-zero -- checking whether it worked anyway."

  rm -f "$urlfile" "$redirfile"

  [ "$(auth_done)" = "yes" ] || fail "consent did not complete.

If the ten-minute window expired, just run this again for a fresh URL."

  envset GOOGLE_AUTH_COMPLETED "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ok "authenticated"
  cat <<EOF

  ${B}Next:${Z}  ./scripts/addon-google-openclaw.sh install

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

  limactl shell "$INSTANCE" -- bash -lc 'command -v openclaw >/dev/null' 2>/dev/null \
    || fail "openclaw is not installed in the VM. This add-on extends the OpenClaw
agent, so the base build has to have produced one."
  ok "base build present"

  [ "$(auth_done)" = "yes" ] || {
    cat >&2 <<EOF

  Not authenticated with Google yet. That is your step, and it needs a
  browser:

      ./scripts/addon-google-openclaw.sh auth

EOF
    exit 2
  }
  ok "gog is authenticated"

  # Who may message the agent is the only control on what it does with this
  # access. Same precondition the Hermes add-on enforces, for the same
  # reason -- and more pressing here, because this agent can send email.
  local alw
  alw="$(limactl shell "$INSTANCE" -- bash -lc \
    'jq -r "(.channels.telegram.allowFrom // []) | join(\",\")" ~/.openclaw/openclaw.json 2>/dev/null' 2>/dev/null | tr -d '\r')"
  [ -n "$alw" ] || fail "the OpenClaw agent has an empty Telegram allowFrom.

This add-on gives that agent a Google account it can read and write. Who
may message it is the only thing deciding who can reach that account, so
it cannot be left open.

Fix the channel allowlist first, or leave this add-on uninstalled."
  ok "OpenClaw channel allowlist is not empty"

  step "Base system still verifying"
  local BASELOG; BASELOG="$(mktemp -t ocg-base-verify.XXXXXX)"
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
  ok "config installed at ~/.config/agent-sandbox/openclaw-google.env (0600)"

  step "Staging the spec for Pi"
  limactl copy "$ADDON/spec.md" "$INSTANCE:agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md" \
    || fail "could not copy the add-on spec into the VM."
  ok "spec placed at ~/agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md"

  step "Your part is done -- hand over to your coding agent"
  cat <<EOF

  gog is installed and authenticated, and Pi has its spec. What remains is
  a build and a review of it: roughly 5-15 minutes of Pi working, then
  reading what it claims against what the checks measure.

  ${B}Tell your coding agent:${Z}

      Install the OpenClaw Google add-on: run
      ./scripts/addon-google-openclaw.sh build, then supervise Pi and
      verify it as addons/google-openclaw/README.md describes.

  It will come back to you once, at the end, with the one check no script
  can do: ask the agent to read something from Google and watch it answer.

EOF
}

# ===========================================================================
cmd_build() {
  vm_running || fail "instance '$INSTANCE' is not running."

  limactl shell "$INSTANCE" -- bash -lc 'test -f "$HOME/agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md"' 2>/dev/null \
    || fail "the add-on spec is not in the VM, so the setup half has not run.
The user needs to do their part first -- see addons/google-openclaw/README.md:
./scripts/addon-google-openclaw.sh auth, then install."

  [ "$(auth_done)" = "yes" ] \
    || fail "gog is not authenticated. The user must run 'auth' first."

  step "Pi builds the add-on"
  printf '      %sthis takes 5-15 minutes.%s Pi'"'"'s progress view follows; long gaps\n' "$Y" "$Z"
  printf '      between lines are normal -- it is thinking, not stuck. The watchdog\n'
  printf '      kills a turn only after %ss with no output at all.\n' "${PI_SILENCE:-600}"
  printf '      From another shell:  ./scripts/pi-session.sh steps\n\n'

  # Short on purpose: fifty-line supervision prompts have hung this setup.
  # It must still name the file, because `say` re-copies the base spec to
  # AGENTS.md every turn, so Pi is looking at two specs and the other one
  # says setup.sh is the deliverable.
  ./scripts/pi-session.sh say \
    "New task, from ~/agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md -- not AGENTS.md. Build what it describes, leaving setup.sh, everything under ~/.hermes, and the rest of the base build untouched." \
    || warn "the Pi turn returned non-zero -- read ./scripts/pi-session.sh summary before concluding anything."

  step "Next"
  cat <<EOF
  Read what Pi claims:   ./scripts/pi-session.sh summary
  What it actually did:  ./scripts/pi-session.sh steps
  Then check it:         ./scripts/addon-google-openclaw.sh verify --live --base

  A summary is a claim; verify.sh is evidence. Push back with
  ./scripts/pi-session.sh say "..." rather than fixing the VM by hand.
EOF
}

# ===========================================================================
cmd_verify() {
  exec "$ADDON/verify.sh" "$INSTANCE" "$@"
}

# ===========================================================================
cmd_remove() {
  vm_running || fail "instance '$INSTANCE' is not running."

  step "Removing the add-on from $INSTANCE"

  if limactl shell "$INSTANCE" -- bash -lc 'grep -qiE "gog|google" "$HOME/agent-bootstrap/setup.sh" 2>/dev/null'; then
    warn "~/agent-bootstrap/setup.sh mentions google -- Pi put add-on work in the"
    warn "base deliverable, against its spec. Removing files will not stick: the"
    warn "next run of setup.sh puts them back. Have Pi take it out of setup.sh."
  fi

  limactl shell "$INSTANCE" -- bash -lc '
    set -u
    rm -f "$HOME/.config/agent-sandbox/openclaw-google.env"
    rm -f "$HOME/agent-bootstrap/setup-openclaw-google.sh"
    rm -f "$HOME/agent-bootstrap/OPENCLAW-GOOGLE-ADDON.md"
    systemctl --user daemon-reload 2>/dev/null || true
  ' || warn "some files could not be removed; check by hand."
  ok "add-on config and spec removed"

  # Deliberately NOT removed: gog itself, and its keyring. The binary is
  # harmless without credentials, and the keyring is the authenticated
  # device -- deleting it silently costs another consent round. Removing an
  # add-on should not destroy something only a human can recreate.
  warn "gog and its keyring were NOT deleted. The keyring holds the Google"
  warn "authorisation, and re-creating it means another consent flow. To"
  warn "remove it: revoke access at https://myaccount.google.com/permissions"
  warn "first, then delete ~/.config/gogcli and ~/.local/share/gogcli in the VM."

  warn "The MCP server registration was NOT removed, because Pi wrote it and"
  warn "knows its shape. Ask it to undo that:"
  warn "  ./scripts/pi-session.sh say \"Remove the gog MCP server from the OpenClaw config and restart the gateway once. Leave the Hermes agent alone.\""
}

case "${1:-}" in
  auth)    cmd_auth ;;
  install) cmd_install ;;
  build)   cmd_build ;;
  verify)  shift; cmd_verify "$@" ;;
  remove)  cmd_remove ;;
  *)
    sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
    exit 2 ;;
esac
