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
# One attempt. Returns pi's exit code; sets NO_WORK=1 if the whole transcript
# was a single upstream API error, which means Pi never started.
NO_WORK=0
pi_attempt() {
  local prompt="$1" stamp log
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  log="$LOGDIR/pi-$stamp.log"
  NO_WORK=0

  # Single-quoted guest command with the prompt passed as a positional
  # argument, never interpolated: a prompt containing a quote would
  # otherwise run as shell on the guest.
  # timeout, because a stalled turn does not fail -- it waits forever. On
  # 2026-10-29 a one-variable fix sat for 34 minutes with an idle VM (~5% of
  # one core) and an empty log: a model stream that opened and then delivered
  # nothing, with no client-side deadline to end it. An error can be retried;
  # a hang just consumes the session. PI_TIMEOUT is generous because a real
  # cold build legitimately runs ~30 minutes of busy CPU.
  timeout "${PI_TIMEOUT:-45m}" \
  limactl shell "$INSTANCE" -- bash -lc '
    cd ~/'"$WORKDIR"' || exit 1
    exec pi -p --session-id "$1" --provider "$2" --model "$3" -- "$4"
  ' _ "$SESSION_ID" "$PROVIDER" "$MODEL" "$prompt" 2>&1 | tee "$log"

  local rc=${PIPESTATUS[0]}
  # 124 is timeout's "deadline hit". Treat a hang that produced nothing as a
  # no-work failure so it retries like any other transient.
  if [ "$rc" -eq 124 ]; then
    say "turn exceeded ${PI_TIMEOUT:-45m} and was killed"
    [ "$(wc -c <"$log")" -lt 2000 ] && NO_WORK=1
  fi
  ln -sfn "$(basename "$log")" "$LAST"
  printf '\n' >&2
  say "transcript: ${log#"$REPO"/}"

  # A transcript that is only an upstream API error means Pi never started --
  # not a build that went wrong. Seen as "ArgoAuthWarning", "[Errno 104]
  # Connection reset by peer", and an empty stream; a rejected credential
  # kills a stream mid-flight rather than returning 401, so these read as
  # network faults and are not.
  if [ "$rc" -ne 0 ] && [ "$(wc -c <"$log")" -lt 2000 ] \
     && grep -q '"type": *"error"' "$log" 2>/dev/null; then
    NO_WORK=1
  fi
  return "$rc"
}

# Retry a turn that produced no work at all. These are transient often enough
# that a supervisor re-running by hand was the single biggest time sink on
# 2026-10-29: three consecutive no-work failures sent a session chasing slirp,
# squid and credential-resolution theories, and the next attempt worked with
# nothing changed.
#
# Only no-work failures retry. A turn where Pi actually did something and then
# failed is a real result -- repeating it would double the side effects of a
# script that may not be idempotent yet, which is exactly what we are asking
# Pi to prove.
PI_MAX_TRIES="${PI_MAX_TRIES:-5}"
pi_turn() {
  local prompt="$1" rc=0 try=1
  while :; do
    pi_attempt "$prompt"; rc=$?
    [ "$NO_WORK" -eq 1 ] || return "$rc"

    if [ "$try" -ge "$PI_MAX_TRIES" ]; then
      cat >&2 <<EOF

  Pi produced no work $PI_MAX_TRIES times running: every transcript was a
  single upstream API error. That is past the point of a transient.

  Check the path Pi actually uses, which tests the agents' real request
  rather than a convenient approximation of it:

      ./verify/verify.sh --models
      bash scripts/diag-stream.sh

  Note a rejected credential presents as a stream dying mid-flight, not as
  a 401 -- see docs/gotchas.md.

EOF
      return "$rc"
    fi

    local wait=$(( try * 15 ))
    say "no work produced (attempt $try/$PI_MAX_TRIES, upstream error). Retrying in ${wait}s."
    sleep "$wait"
    try=$(( try + 1 ))
  done
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
