#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh -- the deterministic half of the build, then stop.
#
#   ./bootstrap.sh             build (resumes; safe to re-run)
#   ./bootstrap.sh --rebuild   destroy the VM and generated config first
#   ./bootstrap.sh --dry-run   preflight and detection only, writes nothing
#
# Run this yourself if you like, but it is meant to be run by a coding
# agent: it never prompts, and every step is deterministic. The one thing
# it cannot do is invent your Telegram tokens, so it stops early and tells
# you to fill in config/agents.env if that has not been done.
#
# Secrets are the user's to type, into a file, in an editor -- never into a
# conversation with an agent, where they would end up in a transcript.
#
# Then it stops before Pi, which is where judgment starts and determinism
# ends. scripts/pi-session.sh drives Pi from there.
#
# When a step fails, fix the script or the spec and re-run. Do not reach
# into the VM by hand: a VM repaired by hand looks like success while the
# repo still produces failure for the next person who clones it.
# ===========================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO"
INSTANCE="${AGENTS_VM:-agents}"

REBUILD=0 DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --rebuild) REBUILD=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; }
say()  { printf '%s==>%s %s\n' "$B" "$Z" "$*"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

# ===========================================================================
step "Preflight"

for c in jq curl openssl diff limactl; do
  command -v "$c" >/dev/null 2>&1 || fail "$c is required but not installed.
On macOS limactl is 'brew install lima'; on Linux take the release binary,
as distro packages lag badly. Then see docs/gotchas.md."
done
ok "jq, curl, openssl, diff, lima $(limactl --version 2>&1 | head -1 | awk '{print $NF}')"

# Warn, never fail: a frozen artifact may legitimately change on the platform
# that owns it, and wedging a build over a hash would be worse than the drift.
# Saying it out loud every run is the point -- see scripts/check-frozen.sh.
./scripts/check-frozen.sh >/dev/null 2>&1 \
  || warn "a platform-frozen artifact has changed -- run ./scripts/check-frozen.sh"

if [ "$(uname -s)" = "Linux" ]; then
  [ -e /dev/kvm ] || fail "/dev/kvm does not exist; QEMU would fall back to
emulation, which is far too slow to use."
  { [ -r /dev/kvm ] && [ -w /dev/kvm ]; } || fail "/dev/kvm is not accessible.
Add yourself to the kvm group and start a new shell:  sudo usermod -aG kvm \$USER
Do not use setfacl -- the grant does not survive a qemu package upgrade."
  ok "/dev/kvm accessible"
fi

# Nothing under config/ may ever reach git. Checked before anything writes
# there, so a bad .gitignore is caught while the directory is still clean.
exposed="$( { git -C "$REPO" ls-files -- config/
              git -C "$REPO" status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
[ -z "$exposed" ] || { printf '%s\n' "$exposed" >&2
  fail "the files above are under config/ and visible to git. Fix .gitignore;
if one is already tracked, 'git rm --cached' it and rotate what it holds."; }

# Same hazard, anywhere in the tree: a user saving tokens before a rebuild
# puts them somewhere convenient, which once was a file called 'secrets'.
loose="$(git -C "$REPO" status --porcelain -uall 2>/dev/null | cut -c4- \
         | grep -iE '(^|/)(secrets?|tokens?|credentials?)(\.[a-z]+)?$|\.(env|key|pem|token)$' \
         | grep -vE '\.example$' || true)"
[ -z "$loose" ] || { printf '%s\n' "$loose" >&2
  warn "the files above look like secrets and are not ignored by git."; }
ok "nothing secret is visible to git"

# ===========================================================================
if [ "$REBUILD" = "1" ]; then
  step "Rebuild"
  say "deleting instance '$INSTANCE' (both agents and everything they have
  learned) and the generated files under config/. agents.env goes too:
  re-supplying it is part of the test. local/ is untouched."
  limactl delete -f "$INSTANCE" 2>/dev/null || true
  rm -f config/allowlist-bootstrap.conf config/allowlist-runtime.conf \
        config/model-access.env config/model-gateway config/pi-models.json \
        config/agents.env
  ok "deleted"
fi

# ===========================================================================
step "Model access"

./scripts/detect-model-access.sh --dry-run || fail "detection failed (above).
It needs an endpoint it can find: ANTHROPIC_BASE_URL in this shell, or a
~/.claude/settings*.json that declares one. Run this from the same
environment your coding agent uses."

[ "$DRY_RUN" = "0" ] || { say "dry run: nothing written"; exit 0; }

./scripts/detect-model-access.sh > /dev/null || fail "writing model-access.env failed."
ok "config/model-access.env written (0600)"

# ===========================================================================
step "Config"

# The one thing this script cannot do for you. Tokens belong in a file you
# edit, not in a conversation with an agent: a secret pasted into a chat is
# a secret in a transcript. A blank gateway token is filled in here because
# it is generated, not supplied.
if [ ! -f config/agents.env ]; then
  install -m 600 config/agents.env.example config/agents.env 2>/dev/null \
    || fail "config/agents.env.example is missing."
fi
chmod 600 config/agents.env

# Stop on the *values*, not on the file. Checking only for a missing file
# meant a second run sailed past a copy still byte-identical to the
# template: the first run creates it and exits 2, nobody fills it in, and
# the build continues to two mute agents with every check green. The exit-2
# message below is the only cue the user ever gets, so it has to fire on
# the state it describes.
# shellcheck disable=SC1091
missing="$( set -a; . config/agents.env 2>/dev/null; set +a
  for n in OPENCLAW_TELEGRAM_BOT_TOKEN HERMES_TELEGRAM_BOT_TOKEN \
           TELEGRAM_ALLOWED_USER_ID; do
    [ -n "$(eval "printf %s \"\${$n:-}\"")" ] || printf '      %s\n' "$n"
  done )"
if [ -n "$missing" ]; then
  cat >&2 <<EOF

  STOP -- this is your turn, and the build waits here until you take it.
  Nothing else will prompt you later: this message is the only cue, and
  re-running the script is how you say you are done.

  config/agents.env is waiting on you. These are still blank:

$missing

  Open it in an editor and fill them in:

      \$EDITOR config/agents.env

    OPENCLAW_AGENT_NAME          two names you choose; the shipped
    HERMES_AGENT_NAME            defaults are fine

    OPENCLAW_TELEGRAM_BOT_TOKEN  one dedicated bot per agent from
    HERMES_TELEGRAM_BOT_TOKEN    @BotFather (/newbot), never a personal
                                 account

    TELEGRAM_ALLOWED_USER_ID     your own numeric id from @userinfobot --
                                 digits, not an @handle

  Telegram is part of the base build, not an extra. Leave those blank and
  the agents come up mute: no chat channel, and the one check no script
  can perform -- messaging an agent and watching it fetch a web page --
  cannot be done at all.

  Leave OPENCLAW_GATEWAY_TOKEN blank. It is generated here, fresh per
  build, on the next run. It is the script's line, not yours.

  You can re-edit this file whenever you like afterwards and re-run; an
  existing value is kept as you wrote it. The exception is --rebuild,
  which deletes the file and brings you back to this message.

  Then: ./bootstrap.sh

EOF
  exit 2
fi
chmod 600 config/agents.env

# A generated value, so generate it rather than asking. Read it the way the
# shell will, not with a regex: OPENCLAW_GATEWAY_TOKEN="" is two quote
# characters to grep but an empty string to everything that consumes it, and
# that mismatch shipped a build whose gateway token was never generated.
# shellcheck disable=SC1091
cur_tok="$( set -a; . config/agents.env 2>/dev/null; set +a
            printf %s "${OPENCLAW_GATEWAY_TOKEN:-}" )"
if [ -z "$cur_tok" ]; then
  tok="$(openssl rand -hex 32)"
  if grep -qE '^OPENCLAW_GATEWAY_TOKEN=' config/agents.env; then
    sed -i.bak "s|^OPENCLAW_GATEWAY_TOKEN=.*|OPENCLAW_GATEWAY_TOKEN=$tok|" config/agents.env
    rm -f config/agents.env.bak
  else
    printf 'OPENCLAW_GATEWAY_TOKEN=%s\n' "$tok" >> config/agents.env
  fi
  ok "generated OPENCLAW_GATEWAY_TOKEN"
fi

# Validate without printing a single value.
# shellcheck disable=SC1091
( set -a; . config/agents.env; set +a
  for n in OPENCLAW_AGENT_NAME HERMES_AGENT_NAME; do
    v="$(eval "printf %s \"\${$n:-}\"")"
    case "$v" in
      ''|*[!A-Za-z0-9._-]*)
        echo "error: $n is empty or has characters outside [A-Za-z0-9._-]." >&2
        exit 1 ;;
    esac
  done
  # Every character must be a digit. `*[0-9]` only tests the LAST one, so
  # it accepted 'handle7' and '12 34' -- and an empty value, which is the
  # state the exit-2 guard above exists to catch.
  case "${TELEGRAM_ALLOWED_USER_ID:-}" in
    ''|*[!0-9]*)
      echo "error: TELEGRAM_ALLOWED_USER_ID wants a numeric id, not an @handle." >&2
      exit 1 ;;
  esac
) || fail "config/agents.env is not usable (see above). Edit it and re-run."

# A set/blank summary, never a value.
# shellcheck disable=SC1091
( set -a; . config/agents.env 2>/dev/null; set +a
  for n in OPENCLAW_AGENT_NAME HERMES_AGENT_NAME OPENCLAW_GATEWAY_TOKEN \
           OPENCLAW_TELEGRAM_BOT_TOKEN HERMES_TELEGRAM_BOT_TOKEN \
           TELEGRAM_ALLOWED_USER_ID; do
    v="$(eval "printf %s \"\${$n:-}\"")"
    case "$n" in
      *NAME) printf '      %-28s %s\n' "$n" "${v:-<blank>}" ;;
      *)     printf '      %-28s %s\n' "$n" "$([ -n "$v" ] && echo set || echo '<blank>')" ;;
    esac
  done )
ok "config/agents.env validated"

# ===========================================================================
step "VM"

if [ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1)" = "Running" ]; then
  ok "instance '$INSTANCE' already running"
else
  say "provisioning takes about ten minutes on a first run (it downloads an
  Ubuntu image, then installs Node, Pi, squid and Tailscale)."
  limactl start --name="$INSTANCE" --tty=false lima/agents.yaml \
    || fail "the VM failed to start. On Linux the usual causes are /dev/kvm
permissions and a too-old Lima."
  ok "provisioned"
fi

# ===========================================================================
step "Push config, lock egress"

./scripts/install-config.sh "$INSTANCE" \
  || fail "install-config.sh failed (above). It stops rather than continue
with a broken model path, because that resurfaces later as confusing Pi
failures."

# ===========================================================================
step "Next: Pi"

cat <<EOF

  The deterministic half is done: the VM is up, config is pushed, and
  egress is locked to the bootstrap allowlist. Pi is installed and has
  built nothing yet.

  Hand it to a coding agent, which should read spec/pi-target-state.md and
  then drive these:

      ./scripts/pi-session.sh build        # Pi builds; ~30 minutes
      ./scripts/pi-session.sh summary      # what Pi claims it did
      ./scripts/pi-session.sh steps        # what it actually did
      ./scripts/pi-session.sh say "..."    # push back, same session
      ./scripts/finish-build.sh            # idempotence, narrow egress, verify

  Pi over-claims -- it has reported success over code that did nothing --
  so ./verify/verify.sh is the evidence, not Pi's summary.

  Keep supervision prompts short. Long ones have hung this setup; two
  sentences has worked where fifty lines did not. See docs/gotchas.md.

EOF
