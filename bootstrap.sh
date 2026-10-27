#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh -- build the sandboxed agent VM, end to end.
#
#   ./bootstrap.sh                   build (resumes; safe to re-run)
#   ./bootstrap.sh --rebuild         destroy the VM and generated config first
#   ./bootstrap.sh --dry-run         preflight and detection only, writes nothing
#   ./bootstrap.sh --interactive-pi  supervise Pi yourself in its TUI, instead
#                                    of handing it to a coding agent
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
# What the user is asked, all of it in this one terminal: confirm the
# detected model endpoint, name the two agents, and optionally supply
# Telegram bot tokens. Everything lands in config/agents.env (0600), which
# they can also edit by hand and re-run.
#
# Bot tokens are read with `read -rs` -- not echoed, not in shell history,
# not in the process table. An earlier version instead told the user to go
# and edit the file mid-run; because that edit had to land between two
# prompts, it could only be done from a second terminal window.
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
# for someone who deliberately wants to do the reviewing themselves.
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

# ask VAR "prompt" "default"  -- a visible value, echoed back.
ask() {
  local __var="$1" __prompt="$2" __default="$3" __in
  printf '%s%s%s [%s] ' "$B" "$__prompt" "$Z" "$__default"
  read -r __in </dev/tty || __in=""
  printf -v "$__var" '%s' "${__in:-$__default}"
}

# Print what config/agents.env holds, without ever printing a secret.
agents_env_summary() {
  # Secrets are shown as length + last four characters: enough for the user
  # to recognise their own value and confirm it arrived intact, useless to
  # anyone reading over a shoulder or scrolling back through a transcript.
  # Plain "set" gave no way to tell a good paste from a truncated one.
  _redact() {
    if [ -z "$1" ]; then printf 'blank'
    elif [ "${#1}" -le 8 ]; then printf '%d chars' "${#1}"   # too short to hint at
    else printf '%d chars, ...%s' "${#1}" "${1: -4}"
    fi
  }
  # shellcheck disable=SC1091
  ( set -a; . config/agents.env 2>/dev/null; set +a
    printf '  config/agents.env:\n'
    printf '    OpenClaw agent      : %s\n' "${OPENCLAW_AGENT_NAME:-<unset>}"
    printf '    Hermes agent        : %s\n' "${HERMES_AGENT_NAME:-<unset>}"
    printf '    gateway token       : %s\n' "$(_redact "${OPENCLAW_GATEWAY_TOKEN:-}")"
    printf '    %s bot token : %s\n' "${OPENCLAW_AGENT_NAME:-OpenClaw}" "$(_redact "${OPENCLAW_TELEGRAM_BOT_TOKEN:-}")"
    printf '    %s bot token : %s\n' "${HERMES_AGENT_NAME:-Hermes}" "$(_redact "${HERMES_TELEGRAM_BOT_TOKEN:-}")"
    printf '    your Telegram id    : %s\n' "${TELEGRAM_ALLOWED_USER_ID:-blank}"
  )
}

# ask_secret VAR "prompt"  -- NOT echoed, and never printed back.
#
# A terminal prompt is a different thing from asking in conversation, which
# AGENTS.md forbids and this script still never does. Here the value is not
# echoed, does not enter shell history, is not in the process table, and
# goes straight into a 0600 file. What it avoids is far worse: making the
# user edit a file at an exact moment mid-run, which needs a second
# terminal and invites them to improvise.
ask_secret() {
  local __var="$1" __prompt="$2" __in
  printf '%s%s%s (hidden; Enter to skip): ' "$B" "$__prompt" "$Z"
  read -rs __in </dev/tty || __in=""
  printf '\n'
  # Confirm that something arrived, without revealing it. A silent prompt
  # leaves the user unable to tell a successful paste from a failed one,
  # and a Telegram token is exactly the sort of thing a terminal paste
  # mangles. Length plus the last four characters is enough to recognise
  # your own token and useless to anyone else.
  if [ -z "$__in" ]; then
    printf '  skipped\n'
  elif [ "${#__in}" -le 8 ]; then
    # Too short to show any of: at 8 characters the last four are most of
    # it. A real Telegram token is ~46, so this is also a useful warning.
    printf '%s  ok%s  received %d characters (shorter than a bot token -- mispaste?)\n' \
      "$G" "$Z" "${#__in}"
  else
    printf '%s  ok%s  received %d characters, ending ...%s\n' \
      "$G" "$Z" "${#__in}" "${__in: -4}"
  fi
  printf -v "$__var" '%s' "$__in"
}

# ===========================================================================
# Say up front who will supervise Pi. Offering the choice only at step 7,
# after the user has sat through a provision, is offering it too late to be
# a choice. Re-running is genuinely cheap -- an existing VM is detected and
# not rebuilt -- but nobody should have to discover that.
if [ "$INTERACTIVE_PI" = "0" ]; then
  cat <<'EOF'

  ------------------------------------------------------------------
  This builds a VM, then stops and hands the rest to your coding
  agent. The remaining work is Pi -- an agent inside the VM that
  installs the two agents from a written spec -- and it needs
  supervising, not just watching: reading its transcript against the
  spec and pushing back where it claims more than it did. Four
  earlier builds shipped broken because that review never happened.

  That review is a coding agent's job. You are not expected to do it.

  If you would rather supervise Pi yourself, in its own TUI, stop now
  and re-run with --interactive-pi. You can also just re-run later:
  an existing VM is reused, so you lose nothing but a minute.
  ------------------------------------------------------------------

EOF
fi

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
step "Step 2 -- start the VM (in the background)"

# Started before the questions, deliberately: provisioning takes about ten
# minutes and step 3 is four prompts, so the two overlap and the user never
# watches a progress bar.
#
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
    # --tty=false and stdin from /dev/null: this runs while the user answers
    # step 3, and must never reach for the terminal itself.
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
step "Step 3 -- what the agents are called, and how to reach them"

# Asked here, in this terminal, rather than by telling the user to edit a
# file. An earlier version did that -- and because the edit had to land
# between two prompts, it could only be done from a SECOND terminal window.
# Requiring two windows to answer four questions is not a design, it is an
# accident.
#
# Secrets are read with `read -rs`: not echoed, not in shell history, not in
# the process table, written straight to a 0600 file. That is a different
# thing from asking for a secret in conversation, which AGENTS.md forbids
# and which this script still never does.
# A user who prefers an editor can fill config/agents.env in BEFORE running
# this script -- from the template, or by copying one from another machine.
# In that case the script must not wipe their work; it only adds the one
# field they cannot sensibly produce themselves, the gateway token.
AGENTS_ENV_WAS_NEW=0
if [ -f config/agents.env ]; then
  # Backfill a missing gateway token into a hand-written file, leaving
  # everything else exactly as the user wrote it.
  if ! grep -qE '^OPENCLAW_GATEWAY_TOKEN="..*"' config/agents.env; then
    GEN="$(openssl rand -hex 32)"
    ( umask 077
      while IFS= read -r line; do
        case "$line" in
          OPENCLAW_GATEWAY_TOKEN=*) printf 'OPENCLAW_GATEWAY_TOKEN="%s"\n' "$GEN" ;;
          *)                        printf '%s\n' "$line" ;;
        esac
      done < config/agents.env > config/agents.env.new )
    mv -f config/agents.env.new config/agents.env
    chmod 600 config/agents.env
    unset GEN
    ok "filled in the missing gateway token; your other values are untouched"
  fi

  say "config/agents.env already exists"
  agents_env_summary
  echo
  if confirm "Keep these settings?"; then
    KEEP_ENV=1
  else
    KEEP_ENV=0
    say "re-asking; the gateway token is preserved"
  fi
else
  KEEP_ENV=0
  AGENTS_ENV_WAS_NEW=1
fi

if [ "$KEEP_ENV" = "0" ]; then
  # Preserve an existing gateway token across a re-ask: it is already in the
  # VM's config, and changing it for no reason would break the installed
  # gateway. Generate one only when there is none.
  GW_TOKEN="$(grep -E '^OPENCLAW_GATEWAY_TOKEN=' config/agents.env 2>/dev/null \
              | head -1 | cut -d'"' -f2 || true)"
  if [ -z "$GW_TOKEN" ]; then
    GW_TOKEN="$(openssl rand -hex 32)"
    GW_NOTE="generated"
  else
    GW_NOTE="kept from the existing file"
  fi

  cat <<'EOF'

  Four questions, answered here. Defaults in brackets -- press Enter to
  accept. (Prefer an editor? Ctrl-C, copy config/agents.env.example to
  config/agents.env, fill it in, and re-run: an existing file is kept as
  written and only the gateway token is added.)

  Just names: an agent's character lives in its own SOUL.md inside the VM,
  which you change later by talking to the agent, not by editing this repo.

EOF
  ask OPENCLAW_NAME "Name for the OpenClaw agent" "claw-one"
  ask HERMES_NAME   "Name for the Hermes agent"   "hermes-one"

  for n in "$OPENCLAW_NAME" "$HERMES_NAME"; do
    case "$n" in
      ''|*[!A-Za-z0-9._-]*)
        fail "'$n' is not a usable agent name. Letters, digits, dot, dash
and underscore only -- these names are sourced by shells on both sides of
the VM boundary and passed to agent CLIs as arguments." ;;
    esac
  done

  cat <<'EOF'

  Telegram, so you can talk to the agents from your phone. Optional --
  press Enter to skip, and add it later by editing config/agents.env and
  re-running.

  One DEDICATED bot per agent from @BotFather, never a personal account.
  Each token is hidden as you type; its length and last four characters are
  echoed back so you can see the paste landed.

EOF
  # Name the agent, not the framework: these are two different bots, and
  # "OpenClaw bot token" invites pasting the same one twice.
  ask_secret OC_TG "@BotFather token for the bot that will BE $OPENCLAW_NAME"
  ask_secret HM_TG "@BotFather token for the bot that will BE $HERMES_NAME"
  if [ -n "$OC_TG" ] && [ "$OC_TG" = "$HM_TG" ]; then
    fail "both agents were given the same bot token. Telegram allows one
connection per bot, so they would fight over it and neither would stay
up. Create a second bot with /newbot in @BotFather."
  fi
  TG_UID=""
  if [ -n "$OC_TG" ] || [ -n "$HM_TG" ]; then
    # Not a secret -- it is your own account id, and the bots refuse
    # everyone else. Echoed so a typo is visible.
    ask TG_UID "Your numeric Telegram user id (the only account the bots answer)" ""
    case "$TG_UID" in
      ''|*[!0-9]*) fail "'$TG_UID' is not numeric. That field wants a user
id, not an @handle. @userinfobot will tell you yours." ;;
    esac
  fi

  # Written with a read loop rather than sed: these values came from a
  # human, and a '|' or '&' in one would corrupt the file silently.
  ( umask 077
    while IFS= read -r line; do
      case "$line" in
        OPENCLAW_AGENT_NAME=*)         printf 'OPENCLAW_AGENT_NAME="%s"\n'         "$OPENCLAW_NAME" ;;
        HERMES_AGENT_NAME=*)           printf 'HERMES_AGENT_NAME="%s"\n'           "$HERMES_NAME" ;;
        OPENCLAW_GATEWAY_TOKEN=*)      printf 'OPENCLAW_GATEWAY_TOKEN="%s"\n'      "$GW_TOKEN" ;;
        OPENCLAW_TELEGRAM_BOT_TOKEN=*) printf 'OPENCLAW_TELEGRAM_BOT_TOKEN="%s"\n' "$OC_TG" ;;
        HERMES_TELEGRAM_BOT_TOKEN=*)   printf 'HERMES_TELEGRAM_BOT_TOKEN="%s"\n'   "$HM_TG" ;;
        TELEGRAM_ALLOWED_USER_ID=*)    printf 'TELEGRAM_ALLOWED_USER_ID="%s"\n'    "$TG_UID" ;;
        *)                             printf '%s\n' "$line" ;;
      esac
    done < config/agents.env.example > config/agents.env.new )
  mv -f config/agents.env.new config/agents.env
  chmod 600 config/agents.env
  unset GW_TOKEN OC_TG HM_TG
  echo
  ok "config/agents.env written (0600); gateway token $GW_NOTE"
  agents_env_summary

  cat <<'EOF'

  Channels are configured DISABLED regardless. Nothing is switched on until
  you say so, after verification passes.

  Anything you want to change later lives in config/agents.env -- edit it
  and re-run this script.

EOF
fi

# ===========================================================================
step "Step 4 -- validate config/agents.env"

# Step 2 validates what it prompts for, but the file may also have been
# hand-edited between runs. Check it again here rather than discover a bad
# value much later, inside Pi.
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
  case "${TELEGRAM_ALLOWED_USER_ID:-}" in
    ''|*[0-9]) ;;
    *) printf 'error: TELEGRAM_ALLOWED_USER_ID is not numeric. It wants a\n' >&2
       printf '       user id, not an @handle. Ask @userinfobot for yours.\n' >&2
       exit 1 ;;
  esac
) || fail "config/agents.env is not usable (see above)."
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
  # Written to a file rather than only printed: this is twenty lines, and
  # selecting twenty lines out of a terminal scrollback without catching a
  # stray prompt is a nuisance. The user points their agent at the file.
  HANDOFF="$REPO/NEXT-STEP.md"
  cat > "$HANDOFF" <<EOF
# Next step: supervise Pi

Generated by \`bootstrap.sh\` on $(date -u +%Y-%m-%dT%H:%M:%SZ). Safe to
delete. Regenerated by re-running the script.

---

Read \`AGENTS.md\` in this repo first -- it is the full brief, and the
section "Your actual job is supervising Pi" is specifically for you.

**Where things stand.** \`./bootstrap.sh\` has finished the deterministic
half of the build. The Lima VM \`$INSTANCE\` is provisioned and running,
\`config/\` has been pushed into it over SSH, and its network egress is
locked to the wide bootstrap allowlist. Pi -- a coding agent living inside
that VM -- is installed but has not built anything yet.

**Your job is the rest:** have Pi build the two agents from
\`spec/pi-target-state.md\`, and check its work. It will tell you it
succeeded. Previous builds shipped broken because nobody verified that
claim, so verifying it is the job, not a formality.

\`\`\`sh
./scripts/pi-session.sh build            # run Pi
./scripts/pi-session.sh transcript       # read what it ACTUALLY did
./scripts/pi-session.sh say "..."        # push back, same session
./scripts/finish-build.sh                # verify and finish
\`\`\`

**Do not shell into the VM to fix anything by hand.** When Pi gets something
wrong the fix belongs in \`spec/pi-target-state.md\`: the repo is the
deliverable, not this VM.
EOF

  cat <<EOF

  The deterministic part is done. What remains is Pi, and Pi needs a
  supervisor -- it has over-claimed success on every previous build.

  That supervisor is your coding agent, not you. Start one in this
  directory and give it this, which is all it needs:

      Read NEXT-STEP.md and do what it says.

  (Written to ${HANDOFF#"$REPO"/} -- read it yourself first if you like.)

  To supervise Pi yourself in its own TUI instead, re-run this script
  with --interactive-pi. The VM is already built, so re-running skips
  straight back to here -- about a minute. You do not need to, though:
  a coding agent can do all of it, and is better at the reading.

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
