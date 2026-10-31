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

  # --mode json, not plain -p. Pi emits one JSON event per line AS IT WORKS:
  # turn_start, tool_execution_start with the actual command, tool results,
  # errors. Plain -p prints nothing until the final summary, which made a
  # healthy build and a hung one look identical from outside -- a 4m12s
  # build sat at 0 bytes for 4m11s. Two whole sessions went into theories
  # about that silence before anyone ran `pi --help`.
  #
  # The raw stream goes to the log; the terminal gets the interesting lines.
  # Single-quoted guest command with the prompt as a positional argument,
  # never interpolated: a prompt containing a quote would otherwise run as
  # shell on the guest.
  #
  # The deadline is a crude backstop, nothing cleverer. It was once argued
  # for at length on the grounds that a wall clock was the ONLY option,
  # because a buffered Pi made a working turn and a hung one look alike.
  # That argument died with --mode json: the log now grows continuously, so
  # silence genuinely means stalled and a silence-based watchdog would
  # work. It is deliberately not built. Four hangs is a thin basis for more
  # machinery, the event log will show exactly where the next one stops,
  # and 15m plus the retry below already recovers without a human. Revisit
  # if the logs show hangs recurring -- not before.
  timeout "${PI_TIMEOUT:-15m}" \
  limactl shell "$INSTANCE" -- bash -lc '
    cd ~/'"$WORKDIR"' || exit 1
    exec pi -p --mode json --session-id "$1" --provider "$2" --model "$3" -- "$4"
  ' _ "$SESSION_ID" "$PROVIDER" "$MODEL" "$prompt" 2>&1 \
  | tee "$log" | pi_progress

  local rc=${PIPESTATUS[0]}
  if [ "$rc" -eq 124 ]; then
    say "turn exceeded ${PI_TIMEOUT:-15m} and was killed"
    NO_WORK=1
  fi
  ln -sfn "$(basename "$log")" "$LAST"
  say "transcript: ${log#"$REPO"/}  ($(wc -l <"$log" | tr -d ' ') events)"

  # Did Pi do anything, or just fail to start? With json this is a question
  # about events rather than bytes: a turn that ran tools produced work,
  # whatever happened afterwards. Only a turn that never got going is worth
  # retrying -- repeating one that acted would double its side effects.
  if [ "$rc" -ne 0 ] && ! grep -q '"type":"tool_execution_start"' "$log" 2>/dev/null; then
    NO_WORK=1
  fi
  return "$rc"
}

# Turn the event stream into something a human can watch. Everything is kept
# in the log; this is the filter, not the record. Without jq (not guaranteed
# on the host) the matching stays deliberately crude.
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

# Pi's closing summary, pulled out of the json log. `transcript` shows the
# events; this shows what Pi claims it did -- which is the thing to read
# sceptically against verify.sh.
pi_summary() {
  local log="$1" last
  last="$(grep '"type":"turn_end"' "$log" 2>/dev/null | tail -1)"
  [ -n "$last" ] || { echo "(no turn_end in the log -- the turn did not finish)"; return; }
  # python, not sed: the text is JSON-escaped and may contain braces,
  # quotes and newlines. A sed version shipped a stray closing brace.
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

# Retry a turn that produced no work at all. These are transient often enough
# that a supervisor re-running by hand was the single biggest time sink on
# 2026-10-29: three consecutive no-work failures sent a session chasing slirp,
# squid and credential-resolution theories, and the next attempt worked with
# nothing changed. It earned its place on the next rebuild, killing a real
# hang unattended; attempt 2 then built the entire target state in 4m12s.
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

  # What Pi SAID -- its closing summary, which is the claim to read against
  # verify.sh. This is what you usually want after a build.
  summary)
    [ -e "$LAST" ] || fail "no Pi run yet."
    pi_summary "$LOGDIR/$(readlink "$LAST")"
    ;;

  # What Pi DID -- every tool call in order, with timings. The answer to
  # "where did it actually go wrong", and the thing plain -p could never
  # show: its output was one final blob with the work invisible.
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
