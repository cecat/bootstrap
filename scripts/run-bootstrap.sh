#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Hand spec/pi-target-state.md to Pi inside the VM.
#
#   ./scripts/run-bootstrap.sh [instance]      (default instance: agents)
#
# Pi loads AGENTS.md from its working directory automatically, so this script
# only has to place the spec and start Pi in the right place. It deliberately
# does NOT try to drive Pi non-interactively: you want to watch this run.
# ---------------------------------------------------------------------------
set -euo pipefail

PRINT=0
if [ "${1:-}" = "--print" ]; then PRINT=1; shift; fi
INSTANCE="${1:-agents}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR="agent-bootstrap"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v limactl >/dev/null 2>&1 || fail "limactl not found. macOS: brew install lima. Linux: see docs/spark-handoff.md"
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running."
[ -f "$REPO/spec/pi-target-state.md" ] || fail "spec/pi-target-state.md is missing."

# --- Preconditions the spec itself asserts; fail early rather than let Pi ---
# --- discover them halfway through an install. ------------------------------
say "checking preconditions"
limactl shell "$INSTANCE" -- bash -eo pipefail -c '
  fail() { printf "  MISSING: %s\n" "$1" >&2; exit 1; }
  [ -f "$HOME/.config/agent-sandbox/agents.env" ] || fail "~/.config/agent-sandbox/agents.env (run install-config.sh)"
  [ -f "$HOME/.config/agent-sandbox/model-access.env" ] || fail "~/.config/agent-sandbox/model-access.env (run install-config.sh)"
  . "$HOME/.config/agent-sandbox/model-access.env"
  URL="${VM_BASE_URL:-$UPSTREAM_BASE_URL}"
  code=$(curl -s -o /dev/null -w "%{http_code}" --noproxy "*" --max-time 20 "$URL/health" || echo 000)
  [ "$code" = "200" ] || fail "model gateway unreachable from the VM at $URL (HTTP $code)"
  command -v pi >/dev/null 2>&1 || fail "pi is not installed"
  echo "  ok: agents.env, model-access.env, model endpoint, pi"
' || fail "preconditions not met; fix these before handing anything to Pi."

phase="$(limactl shell "$INSTANCE" -- cat /etc/agent-sandbox/phase 2>/dev/null || echo '<none>')"
[ "$phase" = "bootstrap" ] || fail "egress phase is '$phase', expected 'bootstrap'.
Pi needs the wide allowlist to install OpenClaw and Hermes:
  limactl shell $INSTANCE -- sudo agent-egress bootstrap"

# --- Place the spec --------------------------------------------------------
say "placing spec/pi-target-state.md in ~/$WORKDIR"
limactl shell "$INSTANCE" -- mkdir -p "$WORKDIR/installers"
limactl copy "$REPO/spec/pi-target-state.md" "$INSTANCE:$WORKDIR/AGENTS.md"

cat <<BANNER

  Starting Pi in ~/$WORKDIR. It loads AGENTS.md from there automatically.

  Tell it:      Build the target state described in AGENTS.md.

  Pi has no permission prompts -- it will act on what it decides to do. Watch
  the run. It is instructed to stop rather than weaken the sandbox, and to
  stop before enabling any chat channel.

  When it finishes, narrow egress and verify:
      limactl shell $INSTANCE -- sudo agent-egress runtime
      ./verify/verify.sh

BANNER

if [ "$PRINT" = "1" ]; then
  exec limactl shell "$INSTANCE" -- bash -lc \
    "cd ~/$WORKDIR && pi -p --provider argo --model argo:claude-4.5-sonnet \
       'Build the target state described in AGENTS.md.' </dev/null"
fi
exec limactl shell "$INSTANCE" -- bash -lc "cd ~/$WORKDIR && exec pi"
