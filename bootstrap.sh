#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh -- build the sandboxed agent VM, end to end.
#
#   ./bootstrap.sh                   build (resumes; safe to re-run)
#   ./bootstrap.sh --rebuild         destroy the VM and generated config first
#   ./bootstrap.sh --dry-run         preflight and detection only, writes nothing
#   ./bootstrap.sh --interactive-pi  watch Pi yourself in its TUI, instead of
#                                    handing it to a supervising agent
#
# This script runs the deterministic half of the build and then STOPS, before
# Pi. That stop is the design, not an interruption:
#
#   * The steps up to it never vary, so they are a script. Prose let an agent
#     improvise, and improvising past these steps into the VM is what
#     contaminated two earlier builds.
#   * Pi is the opposite -- genuinely open-ended, and it over-claims. It has
#     reported success over guards that could never match and over an agent
#     it never renamed. Someone has to read the transcript against the spec.
#   * That someone is a coding agent, driving scripts/pi-session.sh. Not the
#     user. A human babysitting a TUI is how four bad builds shipped.
#
# The user supplies exactly one thing: config/agents.env, handed to them in
# step 2 and edited while the VM provisions. Agent names, Telegram tokens,
# everything -- one file, documented in itself, and their coding agent can
# help fill it in. Nothing here asks for a secret at a prompt: that puts it
# in the shell history and the transcript, where a 0600 file does not.
#
# The only other question is confirming the detected model endpoint, which
# the script genuinely cannot decide alone.
#
# Hard rule for anyone maintaining this: when a step fails, fix the script or
# the spec and re-run. Do not reach into the VM and fix it by hand. A VM made
# to work by hand looks like success while the repo still produces failure
# for the next person. See docs/handoff-2026-10-26.md.
# ===========================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"

INSTANCE="${AGENTS_VM:-agents}"
ORIG_ARGS="$*"
REBUILD=0
DRY_RUN=0
# Default: stop before Pi and hand it to a supervising coding agent. Driving
# Pi is the agent's job -- it over-claims, and catching that means reading a
# transcript against the spec. --interactive-pi opts into the TUI instead,
# for someone who deliberately wants to watch it themselves.
INTERACTIVE_PI=0
for a in "$@"; do
  case "$a" in
    --rebuild)        REBUILD=1 ;;
    --dry-run)        DRY_RUN=1 ;;
    --interactive-pi) INTERACTIVE_PI=1 ;;
    -h|--help) sed -n '3,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done
if [ "$REBUILD" = "1" ] && [ "$DRY_RUN" = "1" ]; then
  echo "--rebuild and --dry-run are contradictory." >&2; exit 2
fi

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi

step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; CURRENT_STEP="$*"; }
say()  { printf '%s==>%s %s\n' "$B" "$Z" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; FINISHED=1; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

# A bare `set -e` death prints nothing at all. That happened on the first
# real run: limactl exits 1 when an instance does not exist, which is the
# normal case right after --rebuild, and the script vanished mid-step with
# no message and no VM. Anything that exits without reaching the end says
# so, and says where.
CURRENT_STEP="startup"
FINISHED=0
on_exit() {
  local rc=$?
  [ -n "${TICKER_PID:-}" ] && kill "$TICKER_PID" 2>/dev/null || true
  [ "$rc" -eq 0 ] && return 0
  [ "$FINISHED" = "1" ] && return 0
  printf '\n%serror:%s bootstrap.sh exited (status %d) during: %s\n' \
    "$R" "$Z" "$rc" "$CURRENT_STEP" >&2
  printf 'If no message explains why, a command failed under set -e.\n' >&2
  printf 'Re-run with:  bash -x ./bootstrap.sh %s\n' "$ORIG_ARGS" >&2
}
trap on_exit EXIT

# Interactive or not, decided once here rather than guessed per step.
#
# A coding agent driving this script is the intended case, not something to
# defend against: a script is a script, and it cannot improvise whoever
# started it. What must not happen is an agent reaching PAST the script into
# the VM to fix things by hand -- and that is prevented by never handing one
# a VM shell, not by refusing to run.
#
# With a terminal: prompts, and Pi runs interactively.
# Without one: values come from the environment, and Pi runs headless under
# scripts/pi-session.sh so its output can be reviewed and pushed back on.
if [ -t 0 ] && [ -r /dev/tty ]; then
  INTERACTIVE=1
else
  INTERACTIVE=0
  [ "$INTERACTIVE_PI" = "0" ] || fail "--interactive-pi needs a terminal:
Pi's TUI cannot render against a pipe. Drop the flag and let the default
path hand Pi to a supervising agent instead."
fi

# --- /dev/kvm: group membership, not an ACL --------------------------------
# On Linux a setfacl grant on /dev/kvm does not survive the udev event that
# installing or upgrading qemu triggers; group membership does. If this shell
# predates the group being added, re-exec under it rather than making the
# user log out. See docs/spark-handoff.md.
if [ "$(uname -s)" = "Linux" ] && [ "${BOOTSTRAP_SG_KVM:-0}" != "1" ] \
   && [ -e /dev/kvm ] && { [ ! -r /dev/kvm ] || [ ! -w /dev/kvm ]; } \
   && id -nG | tr ' ' '\n' | grep -qx kvm; then
  say "re-execing under the kvm group (this shell predates the membership)"
  export BOOTSTRAP_SG_KVM=1
  exec sg kvm -c "$(printf '%q ' "$0" "$@")"
fi

pause() {
  # Read from the terminal, not stdin: a step may have consumed it.
  if [ "$INTERACTIVE" = "0" ]; then return 0; fi
  printf '\n%s%s%s ' "$B" "$1" "$Z"
  read -r _ignored </dev/tty || true
}

# Non-interactive answers come from BOOTSTRAP_ASSUME_YES, which the caller
# must set deliberately. Defaulting to yes would mean an unattended run could
# destroy a VM nobody meant to destroy.
confirm() {
  local prompt="$1" ans
  if [ "$INTERACTIVE" = "0" ]; then
    if [ "${BOOTSTRAP_ASSUME_YES:-0}" = "1" ]; then
      printf '%s%s%s [y/n] y (BOOTSTRAP_ASSUME_YES)\n' "$B" "$prompt" "$Z"
      return 0
    fi
    fail "no terminal, and this run needs an answer to: $prompt
Set BOOTSTRAP_ASSUME_YES=1 to answer yes to every such question."
  fi
  while :; do
    printf '%s%s%s [y/n] ' "$B" "$prompt" "$Z"
    read -r ans </dev/tty || ans=n
    case "$ans" in
      [Yy]|[Yy]es) return 0 ;;
      [Nn]|[Nn]o)  return 1 ;;
    esac
  done
}

# ===========================================================================
step "Step 0 -- preflight"

for c in jq curl openssl diff; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required but not installed."
done
ok "jq, curl, openssl, diff"

if ! command -v limactl >/dev/null 2>&1; then
  case "$(uname -s)" in
    Darwin) fail "limactl not found. Install it:  brew install lima" ;;
    *)      fail "limactl not found. Install the release binary from
  https://github.com/lima-vm/lima/releases -- distro packages are often older
  than the required 1.0.0. Then read docs/spark-handoff.md." ;;
  esac
fi
ok "lima $(limactl --version 2>&1 | head -1)"

if [ "$(uname -s)" = "Linux" ]; then
  [ -e /dev/kvm ] || fail "/dev/kvm does not exist. QEMU will fall back to
emulation, which is far too slow to be usable. See docs/spark-handoff.md."
  { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } || fail "/dev/kvm is not accessible to you.
Add yourself to the kvm group and start a new shell:
  sudo usermod -aG kvm \$USER
Do not use setfacl: the grant does not survive a qemu package upgrade."
  ok "/dev/kvm accessible"
fi

# Nothing from config/ may ever be committed. Check before anything writes to
# it, so a misconfigured .gitignore is caught while the directory is clean.
# Both halves matter: ls-files catches a secret already tracked, status -uall
# catches one that is merely not ignored and would be swept up by `git add`.
exposed="$( { git -C "$REPO" ls-files -- config/
              git -C "$REPO" status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
if [ -n "$exposed" ]; then
  printf '%s\n' "$exposed" >&2
  fail "the files above are under config/ and visible to git. Nothing from
config/ except *.example and README.md may be committed. Check .gitignore --
and if one is already tracked, 'git rm --cached' it and rotate whatever it
holds."
fi
ok "config/ is fully ignored by git"

# The check above only looked at config/, and a user saving their tokens
# before a rebuild naturally puts the file wherever is convenient -- which
# on 2026-10-26 was a plain file named 'secrets' in the repo root, matching
# the 'secrets/' rule not at all. Warn on anything secret-shaped that git
# can still see, anywhere in the tree.
loose="$(git -C "$REPO" status --porcelain -uall 2>/dev/null | cut -c4- \
         | grep -iE '(^|/)(secrets?|tokens?|credentials?)(\.[a-z]+)?$|\.(env|key|pem|token)$' \
         | grep -vE '\.example$' || true)"
if [ -n "$loose" ]; then
  printf '%s\n' "$loose" >&2
  warn "the files above look like secrets and are NOT ignored by git.
Move them outside the repo, or add them to .gitignore, before you commit
anything. This is a warning rather than a halt because the guess is
name-based and may be wrong."
fi

# ===========================================================================
if [ "$REBUILD" = "1" ]; then
  step "Rebuild -- destroying the VM and generated config"
  cat <<WARNING

  This deletes:
    * the Lima instance '$INSTANCE', and with it both agents and anything
      they have learned or written;
    * config/model-access.env, config/agents.env, the live allowlists, and
      the generated model-gateway / pi-models.json.

  config/agents.env goes too, deliberately: re-entering the tokens is part
  of the test. Pre-populating it gives Pi an artificially easier task.

  local/ is untouched.

WARNING
  confirm "Destroy the VM and generated config?" \
    || fail "nothing was deleted."

  limactl delete -f "$INSTANCE" 2>/dev/null || true
  rm -f config/allowlist-bootstrap.conf config/allowlist-runtime.conf \
        config/model-access.env config/model-gateway config/pi-models.json \
        config/agents.env
  ok "deleted"
fi

# ===========================================================================
step "Step 1 -- detect model access"

./scripts/detect-model-access.sh --dry-run || fail "detection failed (above).
It needs a model endpoint it can find: either ANTHROPIC_BASE_URL in this
shell, or a ~/.claude/settings*.json that declares one. Run bootstrap.sh
from the same environment your coding agent uses."

cat <<'NOTE'

  Read that properly. Everything downstream depends on it, and a wrong
  endpoint does not fail here -- it surfaces much later as confusing
  failures inside Pi.

NOTE
confirm "Is the detected model access correct?" \
  || fail "stopped. Fix your model access and re-run.
If the endpoint is right but the provider is listed as unimplemented, see
AGENTS.md -> 'Adding a provider'."

if [ "$DRY_RUN" = "1" ]; then
  echo
  say "dry run: stopping before anything is written or started."
  FINISHED=1
  exit 0
fi

# The dry run above reports an unimplemented provider but still exits 0, so
# the user gets to see the summary and decide. This call is the one that
# refuses to write a profile for one.
./scripts/detect-model-access.sh || fail "detection refused to write a profile.
If the provider is detected but unimplemented, see AGENTS.md -> 'Adding a
provider'. Only the Argo path is built out."
ok "config/model-access.env written (0600)"

# ===========================================================================
step "Step 2 -- the one file you fill in"

# This is the ONLY thing the user supplies, so it comes before the ten-minute
# VM provision rather than being dribbled out as prompts afterwards. They can
# edit it while the VM builds, and their coding agent can help -- every field
# is documented in the file itself.
#
# Prompting for the agent names would be redundant: they are fields in this
# same file. One input, one place.
AGENTS_ENV_WAS_NEW=0
if [ ! -f config/agents.env ]; then
  # Seed from the template with a real gateway token. Substituted in bash,
  # not sed, so a '|' or '&' in a later edit cannot corrupt the file.
  GEN_TOKEN="$(openssl rand -hex 32)"
  ( umask 077
    while IFS= read -r line; do
      case "$line" in
        OPENCLAW_GATEWAY_TOKEN=*) printf 'OPENCLAW_GATEWAY_TOKEN="%s"\n' "$GEN_TOKEN" ;;
        *)                        printf '%s\n' "$line" ;;
      esac
    done < config/agents.env.example > config/agents.env )
  unset GEN_TOKEN
  chmod 600 config/agents.env
  AGENTS_ENV_WAS_NEW=1
  ok "created config/agents.env (0600) with a generated gateway token"
fi

cat <<EOF

  Everything you need to supply lives in one file:

      $REPO/config/agents.env

  Open it in an editor now. Each field is documented in the file.

    * Agent names -- two of them. Defaults are fine.
    * Telegram, if you want the agents reachable there: one dedicated bot
      per agent from @BotFather (never a personal account), plus your own
      numeric user id, which is the only account they will answer. Leave
      blank to build without channels; you can add them later.
    * The gateway token is done -- bootstrap.sh just generated 64 random
      hex characters into your copy. It is blank in the committed template
      because that template is public; yours is unique to this install.

  Your coding agent can help you fill this in -- it is a normal file.

  Nothing here asks you to type a secret at a prompt or into a chat, by
  design: that puts it in the shell history, the transcript and the session
  log. A 0600 file does not. Channels are configured DISABLED either way;
  nothing is turned on until you say so, after verification.

  The VM starts provisioning next and takes about ten minutes, so you have
  that long to edit this.

EOF

# Print what the file currently holds, without ever printing a secret.
agents_env_summary() {
  # shellcheck disable=SC1091
  ( set -a; . config/agents.env 2>/dev/null; set +a
    printf '  config/agents.env:\n'
    printf '    OpenClaw agent     : %s\n' "${OPENCLAW_AGENT_NAME:-<unset>}"
    printf '    Hermes agent       : %s\n' "${HERMES_AGENT_NAME:-<unset>}"
    printf '    gateway token      : %s\n' "$([ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && echo set || echo BLANK)"
    printf '    OpenClaw bot token : %s\n' "$([ -n "${OPENCLAW_TELEGRAM_BOT_TOKEN:-}" ] && echo set || echo blank)"
    printf '    Hermes bot token   : %s\n' "$([ -n "${HERMES_TELEGRAM_BOT_TOKEN:-}" ] && echo set || echo blank)"
    printf '    allowed user id    : %s\n' "$([ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ] && echo set || echo blank)"
  )
}

# ===========================================================================
step "Step 3 -- start the VM (background)"

# Start it now and keep going. Provisioning is about ten minutes and the next
# step is questions, so there is no reason to make the user watch a bar.
# limactl exits 1 and prints "unmatched instances" when the instance does not
# exist, which under `set -e` kills the script dead the moment it is reached
# -- immediately after --rebuild, every time. The || true is load-bearing:
# "no such instance" is the normal case here, not an error.
vm_status="$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)"
VM_LOG="$REPO/.vm-start.log"
VM_PID=""

case "$vm_status" in
  Running)
    ok "instance '$INSTANCE' is already running"
    warn "an existing instance keeps the lima/agents.yaml it was CREATED with.
Edits to that file are ignored until the instance is recreated:
  ./bootstrap.sh --rebuild"
    ;;
  "")
    # The cloud image dominates a first build and is free on every one
    # after, so the estimate is honest only if it says which case this is.
    if ls "$HOME"/.cache/lima/download/by-url-sha256/*/data >/dev/null 2>&1; then
      VM_WAIT_DESC="Expect roughly 5-10 minutes. The Ubuntu image is already
  cached, so this is boot plus package installation."
    else
      VM_WAIT_DESC="Expect roughly 10-20 minutes, most of it a one-time
  ~600 MB download of the Ubuntu cloud image. Later builds reuse it and
  take about half as long."
    fi
    say "creating instance '$INSTANCE' in the background"
    # --tty=false and stdin from /dev/null: this runs in the background while
    # the user is editing agents.env, and must never reach for the terminal.
    limactl start --tty=false --name="$INSTANCE" lima/agents.yaml \
      >"$VM_LOG" 2>&1 </dev/null &
    VM_PID=$!
    ;;
  *)
    VM_WAIT_DESC="Expect a minute or two: the VM exists already, so this is
  a boot rather than a build. Provision scripts re-run on every boot."
    say "starting existing instance '$INSTANCE' (status was: $vm_status)"
    limactl start --tty=false "$INSTANCE" >"$VM_LOG" 2>&1 </dev/null &
    VM_PID=$!
    ;;
esac

# ===========================================================================
step "Step 4 -- confirm config/agents.env"

# The file was handed over in step 2, before the VM started, so the user has
# had the whole provision to edit it. Confirm it while the clock is still
# running rather than after the wait.
agents_env_summary

if [ "$INTERACTIVE" = "1" ]; then
  pause "Press Enter when config/agents.env is ready."
  agents_env_summary
fi

# Validate what the user actually wrote. These names are sourced by shells on
# both sides and reach agent CLIs as arguments, so keep them boring rather
# than quoting defensively in five places downstream.
# shellcheck disable=SC1091
( set -a; . config/agents.env 2>/dev/null; set +a
  for pair in "OPENCLAW_AGENT_NAME:${OPENCLAW_AGENT_NAME:-}" \
              "HERMES_AGENT_NAME:${HERMES_AGENT_NAME:-}"; do
    case "${pair#*:}" in
      ''|*[!A-Za-z0-9._-]*)
        printf 'error: %s is empty or has characters outside [A-Za-z0-9._-].\n' \
          "${pair%%:*}" >&2
        printf '       Edit config/agents.env and re-run.\n' >&2
        exit 1 ;;
    esac
  done
  [ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] || {
    printf 'error: OPENCLAW_GATEWAY_TOKEN is blank. Generate one:\n' >&2
    printf '       openssl rand -hex 32\n' >&2
    exit 1; }
) || fail "config/agents.env is not usable yet (see above)."
ok "config/agents.env validated"

# ===========================================================================
step "Step 5 -- wait for the VM"

if [ -n "$VM_PID" ]; then
  cat <<EOF

  $VM_WAIT_DESC

  What is happening, roughly in order:
    * downloading the Ubuntu 24.04 cloud image (~600 MB, cached in
      ~/.cache/lima -- only the first build on a machine pays for this)
    * booting it, then apt-get: ca-certificates, curl, git, jq, openssl,
      squid, iptables, python3
    * Node 22 from nodesource, then Pi from npm
    * Tailscale, best-effort -- a failure here is logged and ignored

  Progress is in ${VM_LOG#"$REPO"/} if you want to watch:
      tail -f ${VM_LOG#"$REPO"/}

EOF
  # A heartbeat, so a long silence is distinguishable from a hang. TICKER_PID
  # is reaped by on_exit, which already runs on every path out of here --
  # installing a second EXIT trap would replace that diagnostic.
  START_WAIT=$SECONDS
  ( while :; do
      sleep 30
      printf '  ... still provisioning (%dm%02ds elapsed)\n' \
        $(( (SECONDS - START_WAIT) / 60 )) $(( (SECONDS - START_WAIT) % 60 ))
    done ) &
  TICKER_PID=$!

  if ! wait "$VM_PID"; then
    kill "$TICKER_PID" 2>/dev/null || true
    tail -40 "$VM_LOG" >&2 || true
    fail "the VM failed to start. Full log: ${VM_LOG#"$REPO"/}
On Linux the usual causes are /dev/kvm permissions and a too-old Lima.
See docs/spark-handoff.md. Fix the cause and re-run ./bootstrap.sh."
  fi
  kill "$TICKER_PID" 2>/dev/null || true
  ok "provisioning finished in $(( (SECONDS - START_WAIT) / 60 ))m$(( (SECONDS - START_WAIT) % 60 ))s"
fi
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running. Log: ${VM_LOG#"$REPO"/}"
ok "VM is up"

# ===========================================================================
step "Step 6 -- push config and lock egress down"

./scripts/install-config.sh "$INSTANCE" \
  || fail "install-config.sh failed. It stops rather than continue with a
broken model path, because that only resurfaces later as confusing Pi
failures. Fix what it reported, then re-run ./bootstrap.sh."

# ===========================================================================
step "Step 7 -- hand Pi to a supervising agent"

if [ "$INTERACTIVE_PI" = "0" ]; then
  # The default, and the point of the project. Pi over-claims -- it has
  # reported success over guards that could never match, over channel code
  # whose active branch did nothing, and over an agent it never renamed.
  # Four builds shipped that way because nobody read the transcript.
  #
  # Reading a transcript against a spec is a coding agent's job, not the
  # user's. So the deterministic part ends here and the agent takes over.
  cat <<EOF

  The deterministic part is done. What remains is Pi, and Pi needs a
  supervisor -- it has over-claimed success on every previous build.

  That supervisor is your coding agent, not you. Paste this to it:

      The VM is built and config is pushed. Drive and supervise Pi:
      ./scripts/pi-session.sh build, then read the transcript and push
      back with ./scripts/pi-session.sh say "...". Finish with
      ./scripts/finish-build.sh when Pi is genuinely done.

  (If you would rather watch Pi yourself in its own TUI, re-run with
  --interactive-pi. You do not need to: the agent can do all of it.)

EOF
  FINISHED=1
  exit 0
fi

cat <<'EOF'

  Pi now reads spec/pi-target-state.md and installs OpenClaw and Hermes.
  This is the part of the build that is genuinely open-ended, which is why
  it belongs to an agent and not to this script.

  You are about to get an interactive Pi session. Tell it:

      Build the target state described in AGENTS.md.

  Watch the run. Pi has no permission prompts. It is instructed to stop
  rather than weaken the sandbox, and to stop before enabling any channel.

  When it is done, exit Pi and this script picks up again.

  If something is wrong, do NOT fix it inside the VM by hand -- fix the spec
  and re-run. A VM repaired by hand looks like success while the repo still
  produces failure for the next person.

EOF
pause "Press Enter to start Pi."

./scripts/run-bootstrap.sh "$INSTANCE" || true

echo
confirm "Did Pi report that it finished building the target state?" || {
  cat >&2 <<'EOF'

  Stopping here, with egress still on the wide bootstrap allowlist so you
  can re-run Pi:

      ./scripts/run-bootstrap.sh

  Then re-run ./bootstrap.sh to continue from this point. If Pi was blocked
  by something the spec got wrong, correct spec/pi-target-state.md first --
  that is the deliverable.

EOF
  FINISHED=1
  exit 1
}

# ===========================================================================
step "Steps 8-10 -- idempotence, narrow egress, verify"

# One implementation, shared with the headless path, so the two cannot drift.
FINISHED=1
exec ./scripts/finish-build.sh "$INSTANCE"
