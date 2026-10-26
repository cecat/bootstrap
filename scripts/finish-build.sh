#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Everything after Pi: idempotence, narrow egress, verify, report.
#
#   ./scripts/finish-build.sh [instance]      (default instance: agents)
#
# bootstrap.sh calls this at the end of an interactive run. A supervising
# coding agent calls it directly once it is satisfied with what Pi did.
#
# Exits non-zero if anything failed. "Finished" and "passed" are not the
# same thing, and this script never reports the second when it means the
# first -- the whole history of this repo is builds that said they worked.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
INSTANCE="${1:-${AGENTS_VM:-agents}}"

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else B=''; R=''; Y=''; G=''; Z=''; fi
step() { printf '\n%s=== %s ===%s\n' "$B" "$*" "$Z"; }
warn() { printf '%swarning:%s %s\n' "$Y" "$Z" "$*" >&2; }
fail() { printf '%serror:%s %s\n' "$R" "$Z" "$*" >&2; exit 1; }
ok()   { printf '%s  ok%s  %s\n' "$G" "$Z" "$*"; }

[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running."

# Pi must actually have produced something. Running the rest against a VM
# where Pi never finished yields a wall of failures that look like bugs in
# this repo rather than an unfinished build.
limactl shell "$INSTANCE" -- test -x "\$HOME/agent-bootstrap/setup.sh" 2>/dev/null \
  || fail "~/agent-bootstrap/setup.sh does not exist in the VM, so Pi has not
produced its setup script yet. The spec makes that script the deliverable.
Run ./scripts/pi-session.sh transcript to see where it stopped."

# ===========================================================================
step "Idempotence -- before egress narrows"

# Pi's setup.sh fetches from pypi.org, allowlisted in bootstrap only, so
# verify.sh SKIPS this check under the runtime allowlist -- and a skip reads
# like a pass in a thirty-line run. It has to happen here or not at all.
IDEM_RC=0
AGENTS_VM="$INSTANCE" ./verify/verify.sh --idempotence || IDEM_RC=$?
if [ "$IDEM_RC" != "0" ]; then
  warn "idempotence failed (above). Pi's setup.sh changes state on a second
run, so re-running it is not safe and it is not the repeatable artifact the
spec asks for. Continuing to the rest of the verification so everything is
visible at once; usually the cause is a guard that can never match. This
build will not be reported as passing."
fi

# ===========================================================================
step "Narrow egress to the runtime allowlist"

limactl shell "$INSTANCE" -- sudo /usr/local/sbin/agent-egress runtime \
  || fail "could not switch to the runtime allowlist."
ok "egress phase: runtime"

# ===========================================================================
step "Verify"

# --models costs real quota, and a plain run cannot prove the model path:
# /health and /v1/models answer 200 from local state with a dead upstream.
VERIFY_RC=0
AGENTS_VM="$INSTANCE" ./verify/verify.sh --models || VERIFY_RC=$?

# ===========================================================================
step "Stop"

cat <<EOF

  No chat channel is enabled, even if bot tokens were supplied. Turning one
  on is a separate decision, made deliberately, after this passes.

  Still worth checking:

      ./verify/verify.sh --reboot        policy and gateways come back

  Talk to the agents:

      limactl shell $INSTANCE
      openclaw chat
      hermes chat

  Change a personality by asking the agent, not by editing this repo:
  "show me your SOUL.md". See docs/personality.md.

EOF

if [ "$VERIFY_RC" != "0" ] || [ "$IDEM_RC" != "0" ]; then
  fail "verification reported failures (above). The build is NOT proven.
Fix the script or the spec that caused each failure and re-run -- not the VM."
fi

printf '%s==>%s verification passed.\n' "$B" "$Z"
