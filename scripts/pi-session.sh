#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Drive Pi inside the VM headlessly, in a session that can be pushed back on.
#
#   ./scripts/pi-session.sh build               start the build
#   ./scripts/pi-session.sh say "<message>"     continue the same session
#   ./scripts/pi-session.sh summary             what Pi claimed it did
#   ./scripts/pi-session.sh steps [n]           what Pi actually did
#   ./scripts/pi-session.sh transcript [n]      the raw event stream
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
# Seconds of no log output before a turn counts as hung. Pi emits nothing
# between starting a tool and that tool returning, so this must clear the
# slowest legitimate one. Measured over a day of builds: longest real tool
# call 327s (a gateway teardown), longest model call 237s, everything else
# under 110s. 600 leaves room for a cold package cache on a slower host.
PI_SILENCE="${PI_SILENCE:-600}"

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v limactl >/dev/null 2>&1 || fail "limactl not found."
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null | head -1 || true)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running."

mkdir -p "$LOGDIR"

# Last-modified time of a file, in epoch seconds, on both GNU and BSD.
#
# GNU first, and this order is not cosmetic: BSD's `stat -f %m` on GNU stat
# exits 1 but still writes to stdout, so trying it first captures an error
# string as the timestamp. Discarding stderr is not enough.
#
# The fallback matters too. This feeds the silence watchdog, and `date +%s`
# makes the computed quiet time 0 forever -- a watchdog that can never fire,
# with no sign that anything is wrong. That is what `stat -c %Y` alone did on
# macOS.
log_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

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

  # --mode json, never plain -p: Pi emits one event per line as it works,
  # where -p prints nothing until the final summary and leaves a healthy
  # turn indistinguishable from a hung one. Raw events to the log, the
  # interesting ones to the terminal.
  #
  # The guest command is single-quoted with the prompt as a positional
  # argument. Do not interpolate it -- a prompt containing a quote would
  # run as shell on the guest.
  #
  # Silence is the hang signal, not elapsed time. Pi emits an event per
  # line as it works, so a working turn never goes quiet -- while a
  # wall-clock limit kills healthy ones: 15m once killed a build mid-way
  # through writing an allowlist, 8,052 events in.
  #
  # Pi writes the log directly rather than through a pipe, so its pid
  # stays killable; the progress view tails that file and stops with it.
  #
  # Point pi-last.log at this run before starting it, not after it ends.
  # Updating it afterwards left `steps` reading a previous session's log
  # for the whole build -- printing nothing and exiting 1 while 2.7 MB of
  # live events went to a file it was not looking at.
  : > "$log"
  ln -sfn "$(basename "$log")" "$LAST"
  limactl shell "$INSTANCE" -- bash -lc '
    cd ~/'"$WORKDIR"' || exit 1
    exec pi -p --mode json --session-id "$1" --provider "$2" --model "$3" -- "$4"
  ' _ "$SESSION_ID" "$PROVIDER" "$MODEL" "$prompt" > "$log" 2>&1 &
  local pid=$!

  tail -f -n +1 --pid="$pid" "$log" | pi_progress &
  local viewer=$!

  local quiet=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 10
    quiet=$(( $(date +%s) - $(log_mtime "$log") ))
    [ "$quiet" -lt "$PI_SILENCE" ] && continue
    say "no output for ${quiet}s -- killing a turn that has stopped working"
    kill "$pid" 2>/dev/null || true
    break
  done

  wait "$pid" 2>/dev/null; local rc=$?
  wait "$viewer" 2>/dev/null
  say "transcript: ${log#"$REPO"/}  ($(wc -l <"$log" | tr -d ' ') events)"

  # Did Pi do anything, or just fail to start? Only a turn that reached no
  # tool call is worth retrying; repeating one that acted would double its
  # side effects.
  if [ "$rc" -ne 0 ] && ! grep -q '"type":"tool_execution_start"' "$log" 2>/dev/null; then
    NO_WORK=1
  fi
  return "$rc"
}

# A watchable view of the event stream. The log is the record; this is
# only the filter, so the matching stays crude rather than requiring jq.
pi_progress() {
  local t0=$SECONDS
  while IFS= read -r line; do
    case "$line" in
      *'"type":"tool_execution_start"'*)
        local tool cmd
        tool="$(sed -n 's/.*"toolName":"\([^"]*\)".*/\1/p' <<<"$line")"
        cmd="$(sed -n 's/.*"command":"\([^"]*\)".*/\1/p' <<<"$line" | cut -c1-90)"
        printf '  [%4ds] %s %s\n' "$((SECONDS-t0))" "${tool:-tool}" "${cmd:-}" >&2 ;;
      *'"type":"turn_start"'*)
        printf '  [%4ds] --- turn ---\n' "$((SECONDS-t0))" >&2 ;;
      *'"type":"error"'*|*'"error":'*)
        printf '  [%4ds] ERROR %.200s\n' "$((SECONDS-t0))" "$line" >&2 ;;
      *'"role":"assistant"'*'"type":"text"'*)
        : ;;  # prose; it is in the log and the final summary repeats it
    esac
  done
}

# Pi's closing summary -- what it CLAIMS it did, to be read against
# verify.sh rather than trusted.
pi_summary() {
  local log="$1" last
  last="$(grep '"type":"turn_end"' "$log" 2>/dev/null | tail -1)"
  [ -n "$last" ] || { echo "(no turn_end in the log -- the turn did not finish)"; return; }
  # python, not sed: the text is JSON-escaped and contains braces, quotes
  # and newlines that a sed version gets wrong.
  printf '%s' "$last" | python3 -c '
import json, sys
try:
    msg = json.load(sys.stdin).get("message", {})
except Exception:
    sys.exit("(could not parse the final event)")
for block in msg.get("content", []):
    if block.get("type") == "text":
        print(block.get("text", "").strip())
'
}

# Retry a turn that produced no work at all. These are transient often
# enough that re-running by hand was the biggest time sink in this repo's
# history -- three in a row once sent a session chasing network theories,
# and the next attempt worked with nothing changed.
#
# Only no-work failures retry. A turn that did something and then failed
# is a real result; repeating it would double the side effects of a script
# whose idempotence is the thing being tested.
PI_MAX_TRIES="${PI_MAX_TRIES:-5}"
pi_turn() {
  local prompt="$1" rc=0 try=1
  while :; do
    pi_attempt "$prompt"; rc=$?
    [ "$NO_WORK" -eq 1 ] || return "$rc"

    if [ "$try" -ge "$PI_MAX_TRIES" ]; then
      cat >&2 <<EOF

  Pi produced no work $PI_MAX_TRIES times running: not one attempt reached
  a single tool call. That is past the point of a transient.

  The event log says where it stopped. If the last event is a turn_start
  with nothing after it, Pi never got a reply from the model:

      ./scripts/pi-session.sh transcript 20

  Then check the path Pi actually uses, which tests the agents' real
  request rather than a convenient approximation of it:

      ./verify/verify.sh --models
      bash scripts/diag-stream.sh

  Note a rejected credential presents as a stream dying mid-flight, not as
  a 401 -- see docs/gotchas.md.

EOF
      return "$rc"
    fi

    local wait=$(( try * 15 ))
    say "no work produced (attempt $try/$PI_MAX_TRIES). Retrying in ${wait}s."
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
    # Re-copy the spec every turn. The supervision loop edits the spec and
    # then pushes back, so by the time `say` runs the host copy has usually
    # changed -- and a message like "re-read rule 2" must not point at the
    # version Pi was first given.
    if [ -f "$REPO/spec/pi-target-state.md" ]; then
      limactl copy "$REPO/spec/pi-target-state.md" "$INSTANCE:$WORKDIR/AGENTS.md" \
        || fail "could not refresh the spec in the VM."
    fi
    pi_turn "$*"
    ;;

  # What Pi SAID -- its closing summary, which is the claim to read against
  # verify.sh. This is what you usually want after a build.
  summary)
    [ -e "$LAST" ] || fail "no Pi run yet."
    pi_summary "$LOGDIR/$(readlink "$LAST")"
    ;;

  # What Pi DID -- every tool call in order. Read this against `summary`
  # when a claim looks thin.
  steps)
    [ -e "$LAST" ] || fail "no Pi run yet."
    grep '"type":"tool_execution_start"' "$LOGDIR/$(readlink "$LAST")" 2>/dev/null \
      | sed -n 's/.*"toolName":"\([^"]*\)".*/\1/p' | sort | uniq -c | sort -rn
    echo
    grep '"type":"tool_execution_start"' "$LOGDIR/$(readlink "$LAST")" 2>/dev/null \
      | sed 's/.*"toolName":"\([^"]*\)".*"command":"\([^"]*\)".*/  \1: \2/' \
      | cut -c1-120 | tail -n "${2:-40}"
    ;;

  # The raw event stream, for when the filtered views are not enough.
  transcript)
    [ -e "$LAST" ] || fail "no Pi run yet."
    tail -n "${2:-200}" "$LOGDIR/$(readlink "$LAST")"
    ;;

  capabilities)
    limactl shell "$INSTANCE" -- bash -lc 'pi --help 2>&1' | head -80
    ;;

  *)
    sed -n '3,8p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
    ;;
esac
