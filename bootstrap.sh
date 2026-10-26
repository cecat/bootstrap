#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh -- build the sandboxed agent VM, end to end.
#
#   ./bootstrap.sh              build (resumes; safe to re-run)
#   ./bootstrap.sh --rebuild    destroy the VM and generated config first
#   ./bootstrap.sh --dry-run    preflight and detection only, change nothing
#
# Why this is a script and not a procedure for a coding agent: every step here
# is deterministic. Driving them with an agent adds variance without adding
# judgment, and it gives the agent a reach into the VM that it should not
# have. The one genuinely open-ended job -- installing two third-party tools
# whose docs drift, and writing an idempotent setup script -- belongs to Pi,
# inside the VM, working from spec/pi-target-state.md.
#
# Two things stay interactive, because a script cannot do them honestly:
#   * confirming the detected model access (everything downstream depends on
#     it, and a wrong endpoint surfaces much later as confusing Pi failures);
#   * the user putting their own bot tokens into config/agents.env. This
#     script never asks for a secret, and neither should anything else --
#     a token typed in conversation is in the transcript forever.
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
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

ask() {
  # ask VAR "prompt" "default" [ENV_OVERRIDE]  -- non-secret values only.
  local __var="$1" __prompt="$2" __default="$3" __envvar="${4:-}" __in
  if [ -n "$__envvar" ] && [ -n "${!__envvar:-}" ]; then
    printf -v "$__var" '%s' "${!__envvar}"
    printf '  %s: %s (from %s)\n' "$__prompt" "${!__envvar}" "$__envvar"
    return 0
  fi
  if [ "$INTERACTIVE" = "0" ]; then
    printf -v "$__var" '%s' "$__default"
    printf '  %s: %s (default)\n' "$__prompt" "$__default"
    return 0
  fi
  printf '%s%s%s [%s] ' "$B" "$__prompt" "$Z" "$__default"
  read -r __in </dev/tty || __in=""
  printf -v "$__var" '%s' "${__in:-$__default}"
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
step "Step 2 -- start the VM"

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
    say "creating instance '$INSTANCE' (about ten minutes; log: ${VM_LOG#"$REPO"/})"
    # --tty=false and stdin from /dev/null: this runs in the background while
    # the user is answering prompts, and must never reach for the terminal.
    limactl start --tty=false --name="$INSTANCE" lima/agents.yaml \
      >"$VM_LOG" 2>&1 </dev/null &
    VM_PID=$!
    ;;
  *)
    say "starting existing instance '$INSTANCE' (status was: $vm_status)"
    limactl start --tty=false "$INSTANCE" >"$VM_LOG" 2>&1 </dev/null &
    VM_PID=$!
    ;;
esac

# ===========================================================================
step "Step 3 -- agent names"

if [ -f config/agents.env ]; then
  # Never print a token. Names only, and set/blank for everything else.
  # shellcheck disable=SC1091
  ( set -a; . config/agents.env; set +a
    printf '  config/agents.env already exists:\n'
    printf '    OpenClaw agent     : %s\n' "${OPENCLAW_AGENT_NAME:-<unset>}"
    printf '    Hermes agent       : %s\n' "${HERMES_AGENT_NAME:-<unset>}"
    printf '    gateway token      : %s\n' "$([ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] && echo set || echo BLANK)"
    printf '    OpenClaw bot token : %s\n' "$([ -n "${OPENCLAW_TELEGRAM_BOT_TOKEN:-}" ] && echo set || echo blank)"
    printf '    Hermes bot token   : %s\n' "$([ -n "${HERMES_TELEGRAM_BOT_TOKEN:-}" ] && echo set || echo blank)"
    printf '    allowed user id    : %s\n' "$([ -n "${TELEGRAM_ALLOWED_USER_ID:-}" ] && echo set || echo blank)"
  )
  echo
  if confirm "Keep this file as it is?"; then
    KEEP_ENV=1
  else
    KEEP_ENV=0
  fi
else
  KEEP_ENV=0
fi

if [ "$KEEP_ENV" = "0" ]; then
  echo
  echo "  Just names. An agent's character lives in its own SOUL.md inside the"
  echo "  VM, which you change by talking to the agent -- see docs/personality.md."
  echo
  ask OPENCLAW_NAME "Name for the OpenClaw agent" "claw-one"   OPENCLAW_AGENT_NAME
  ask HERMES_NAME   "Name for the Hermes agent"   "hermes-one" HERMES_AGENT_NAME

  # agents.env is sourced by shells on both sides and the names reach agent
  # CLIs as arguments. Keep them boring rather than quoting defensively in
  # five places downstream.
  for n in "$OPENCLAW_NAME" "$HERMES_NAME"; do
    case "$n" in
      ''|*[!A-Za-z0-9._-]*)
        fail "'$n' is not a usable agent name. Letters, digits, dot, dash and
underscore only -- these names are sourced by shells and passed to CLIs." ;;
    esac
  done

  # Substitute in bash, not sed: the names come from the user and a '|' or
  # '&' in one would otherwise corrupt the file or vanish silently.
  GEN_TOKEN="$(openssl rand -hex 32)"
  ( umask 077
    while IFS= read -r line; do
      case "$line" in
        OPENCLAW_AGENT_NAME=*)    printf 'OPENCLAW_AGENT_NAME="%s"\n'    "$OPENCLAW_NAME" ;;
        HERMES_AGENT_NAME=*)      printf 'HERMES_AGENT_NAME="%s"\n'      "$HERMES_NAME" ;;
        OPENCLAW_GATEWAY_TOKEN=*) printf 'OPENCLAW_GATEWAY_TOKEN="%s"\n' "$GEN_TOKEN" ;;
        *)                        printf '%s\n' "$line" ;;
      esac
    done < config/agents.env.example > config/agents.env )
  unset GEN_TOKEN
  chmod 600 config/agents.env
  ok "config/agents.env written (0600), gateway token generated"
fi

# ===========================================================================
step "Step 4 -- your Telegram tokens, if you want them"

cat <<EOF

  Open this file in an editor:

      $REPO/config/agents.env

  and fill in these three if you want the agents reachable over Telegram:

      OPENCLAW_TELEGRAM_BOT_TOKEN
      HERMES_TELEGRAM_BOT_TOKEN
      TELEGRAM_ALLOWED_USER_ID

  One dedicated bot per agent from @BotFather -- never a personal account --
  and your own numeric user id, the only account the bots will answer.

  Leave them blank to build without channels; you can add them later.

  This script will not ask you for these values and will not read them back
  to you. A token typed into a terminal prompt or a chat ends up in the
  transcript and in the session log; a token you put in a 0600 file does not.

  Channels are configured DISABLED either way. Nothing is turned on until
  you say so, after verification.

EOF
pause "Press Enter when the file is ready."

# ===========================================================================
step "Step 2 (cont.) -- waiting for the VM"

if [ -n "$VM_PID" ]; then
  say "waiting for provisioning to finish"
  if ! wait "$VM_PID"; then
    tail -40 "$VM_LOG" >&2 || true
    fail "the VM failed to start. Full log: ${VM_LOG#"$REPO"/}
On Linux the usual causes are /dev/kvm permissions and a too-old Lima.
See docs/spark-handoff.md. Fix the cause and re-run ./bootstrap.sh."
  fi
fi
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running. Log: ${VM_LOG#"$REPO"/}"
ok "VM is up"

# ===========================================================================
step "Step 5 -- push config and lock egress down"

./scripts/install-config.sh "$INSTANCE" \
  || fail "install-config.sh failed. It stops rather than continue with a
broken model path, because that only resurfaces later as confusing Pi
failures. Fix what it reported, then re-run ./bootstrap.sh."

# ===========================================================================
step "Step 6 -- hand the spec to Pi"

if [ "$INTERACTIVE" = "0" ]; then
  # Headless: a supervising agent drives Pi and reads the transcript. Stop
  # here rather than run it blind -- Pi over-claiming is this repo's
  # documented failure mode, and an unread transcript is how it survived
  # four builds.
  cat <<EOF

  Everything deterministic is done. What remains is Pi, and Pi needs
  supervision: it has over-claimed success on every previous build.

  Drive it with:

      ./scripts/pi-session.sh build            start the build
      ./scripts/pi-session.sh transcript       read what it actually did
      ./scripts/pi-session.sh say "<message>"  push back, same session

  Read the transcript before believing the summary. Specifically: a flurry
  of retries followed by a confident report, guards that cannot match, and
  log lines that announce work the code below them does not do.

  When Pi is genuinely done, finish the build:

      ./scripts/finish-build.sh

  If Pi got something wrong, fix spec/pi-target-state.md and re-run. Do not
  repair the VM by hand -- the repo is the deliverable.

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
step "Steps 6b-9 -- idempotence, narrow egress, verify"

# One implementation, shared with the headless path, so the two cannot drift.
FINISHED=1
exec ./scripts/finish-build.sh "$INSTANCE"
