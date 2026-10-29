#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive Pi inside the VM headlessly, in a session that can be pushed back on.
#
#   ./scripts/pi-session.sh build               start the build
#   ./scripts/pi-session.sh say "<message>"     continue the same session
#   ./scripts/pi-session.sh transcript [n]      last n lines of the last run
#
# This exists so a supervising coding agent can oversee Pi without a human
# sitting at a TUI. Pi makes mistakes and over-claims -- the documented
# failure mode of this repo is Pi reporting success over a script whose
# guards never match -- so somebody has to read what it actually did and
# argue with it. That somebody should not have to be the user.
#
# Pi keeps the session, so `say` continues the same conversation rather than
# starting a fresh one with no memory of what it just built. Everything is
# appended to logs/ on the host, because the point is to be read afterwards.
#
# This script NEVER gives its caller a shell in the VM. That is deliberate.
# When Pi gets something wrong the fix belongs in spec/pi-target-state.md,
# which is the deliverable; a VM repaired by hand looks like success while
# the repo still produces failure for the next person who clones it.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE="${AGENTS_VM:-agents}"
WORKDIR="agent-bootstrap"
SESSION_ID="${PI_SESSION_ID:-agent-bootstrap-build}"
MODEL="${PI_MODEL:-argo:claude-4.5-sonnet}"
PROVIDER="${PI_PROVIDER:-argo}"
LOGDIR="$REPO/logs"
LAST="$LOGDIR/pi-last.log"

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v limactl >/dev/null 2>&1 || fail "limactl not found."
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running."

mkdir -p "$LOGDIR"

# Run one Pi turn. Output goes to the terminal AND to the log, because the
# supervising agent reads the log while the user watches the stream.
pi_turn() {
  local prompt="$1" stamp log
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$LOGDIR/pi-$stamp.log"

  # Single-quoted guest command with the prompt passed as a positional
  # argument, never interpolated: a prompt containing a quote would
  # otherwise run as shell on the guest.
  limactl shell "$INSTANCE" -- bash -lc '
    cd ~/'"$WORKDIR"' || exit 1
    exec pi -p --session-id "$1" --provider "$2" --model "$3" -- "$4"
  ' _ "$SESSION_ID" "$PROVIDER" "$MODEL" "$prompt" 2>&1 | tee "$log"

  local rc=${PIPESTATUS[0]}
  ln -sfn "$(basename "$log")" "$LAST"
  printf '\n' >&2
  say "transcript: ${log#"$REPO"/}"

  # A transcript that is only an upstream API error means Pi never started --
  # it is not a build that went wrong, and it should not be read as one. The
  # first time this happened the error ("Upstream stream ended before
  # completion: ArgoAuthWarning") sent a session chasing a routing bug that
  # did not exist; every later attempt worked. Name it for what it is.
  if [ "$rc" -ne 0 ] && [ "$(wc -c <"$log")" -lt 2000 ] \
     && grep -q '"type": *"error"' "$log" 2>/dev/null; then
    cat >&2 <<EOF

  Pi produced no work: its entire output was one upstream API error.

  That is a model-endpoint problem, not a build problem, and it is often
  transient -- a stream that dies before the first token. Nothing in the VM
  changed, so just run the same command again.

  If it repeats, check the path Pi actually uses:
      ./verify/verify.sh --models

EOF
  fi
  return "$rc"
}

case "${1:-}" in
  build)
    phase="$(limactl shell "$INSTANCE" -- cat /etc/agent-sandbox/phase 2>/dev/null | tr -d '\r' || true)"
    [ "$phase" = "bootstrap" ] || fail "egress phase is '${phase:-none}', expected 'bootstrap'.
Pi needs the wide allowlist to install OpenClaw and Hermes. Run
scripts/install-config.sh first."

    [ -f "$REPO/spec/pi-target-state.md" ] || fail "spec/pi-target-state.md is missing."
    limactl shell "$INSTANCE" -- mkdir -p "$WORKDIR/installers"
    limactl copy "$REPO/spec/pi-target-state.md" "$INSTANCE:$WORKDIR/AGENTS.md" \
      || fail "could not copy the spec into the VM."
    say "spec placed at ~/$WORKDIR/AGENTS.md; starting Pi (session: $SESSION_ID)"
    pi_turn "Build the target state described in AGENTS.md."
    ;;

  say)
    [ $# -ge 2 ] || fail "usage: $0 say \"<message>\""
    shift
    # Re-copy the spec every turn. The supervision loop is "Pi gets it wrong
    # -> fix spec/pi-target-state.md -> push back", so by the time you run
    # `say` the host spec has usually changed. Until 2026-10-28 only `build`
    # copied it, leaving Pi reading the version it was first given: a message
    # saying "re-read rule 2, it has changed" pointed at a file where it had
    # not. Pi noticed and asked rather than guessing, which is the only
    # reason this was caught instead of producing a build against a spec
    # nobody had.
    if [ -f "$REPO/spec/pi-target-state.md" ]; then
      limactl copy "$REPO/spec/pi-target-state.md" "$INSTANCE:$WORKDIR/AGENTS.md" \
        || fail "could not refresh the spec in the VM."
    fi
    pi_turn "$*"
    ;;

  transcript)
    [ -e "$LAST" ] || fail "no Pi run yet."
    tail -n "${2:-200}" "$LOGDIR/$(readlink "$LAST")"
    ;;

  *)
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
