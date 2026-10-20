#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Push local config into the VM and lock egress down.
#
#   ./scripts/install-config.sh [instance]      (default instance: agents)
#
# No model gateway is installed in the VM. The host already has a working path
# to models -- on site that is Argo directly, off site an SSH tunnel to an
# argo-proxy on an ANL machine. Detection recorded which, and the VM reaches
# it through Lima's host gateway.
#
# The VM has no mounts, so everything crosses via `limactl copy` over SSH.
# Idempotent: safe to re-run after editing anything in config/.
# ---------------------------------------------------------------------------
set -euo pipefail

INSTANCE="${1:-agents}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CFG="$REPO/config"

say()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v limactl >/dev/null 2>&1 || fail "limactl not found."
[ "$(limactl list --format '{{.Status}}' "$INSTANCE" 2>/dev/null)" = "Running" ] \
  || fail "instance '$INSTANCE' is not running."

# --- 1. The detected model profile -----------------------------------------
PROFILE="$CFG/model-access.env"
[ -f "$PROFILE" ] || fail "config/model-access.env missing. Run ./scripts/detect-model-access.sh"
# shellcheck disable=SC1090
set -a; . "$PROFILE"; set +a
[ -f "$CFG/agents.env" ] || fail "config/agents.env missing. See AGENTS.md Step 4."

case "${PROVIDER_KIND:-}" in
  gateway) MODEL_URL="$VM_BASE_URL"; GATEWAY="$VM_GATEWAY" ;;
  argo)    MODEL_URL="$UPSTREAM_BASE_URL"; GATEWAY="" ;;
  *)       fail "provider '${PROVIDER_KIND:-unknown}' is not implemented. See todo.md." ;;
esac

# A host-side tunnel must actually be up, or everything downstream fails
# confusingly. Check before touching the VM.
if [ -n "$GATEWAY" ]; then
  curl -fsS --noproxy '*' --max-time 8 "$UPSTREAM_BASE_URL/health" >/dev/null 2>&1 \
    || fail "nothing is answering on $UPSTREAM_BASE_URL.
Bring up your SSH tunnel first (the one behind 'claude-argo-home'), then re-run."
  say "host gateway is live; the VM will use $MODEL_URL"
fi

# --- 2. Generate what is derivable ----------------------------------------
for phase in bootstrap runtime; do
  [ -f "$CFG/allowlist-$phase.conf" ] || cp "$CFG/allowlist-$phase.conf.example" "$CFG/allowlist-$phase.conf"
done

# Pi needs a provider before it can run at all; it cannot configure itself.
# argo-proxy runs with username-passthrough: the API key IS the ANL username.
# A placeholder fails with "the username is not registered in ARGO". The key
# is an env reference, so the value is never written into this file.
cat > "$CFG/pi-models.json" <<JSON
{
  "\$schema": "https://pi.dev/schemas/models.schema.json",
  "providers": {
    "argo": {
      "baseUrl": "$MODEL_URL",
      "api": "anthropic-messages",
      "apiKey": "\$ARGO_CREDENTIAL",
      "models": [
        { "id": "argo:claude-5-sonnet" },
        { "id": "argo:claude-4.5-sonnet" },
        { "id": "argo:claude-5-opus" },
        { "id": "argo:claude-4.5-haiku" }
      ]
    }
  }
}
JSON
printf '%s\n' "$GATEWAY" > "$CFG/model-gateway"

# --- 3. Copy into the guest ------------------------------------------------
say "copying config into $INSTANCE"
limactl shell "$INSTANCE" -- rm -rf /tmp/agent-config
limactl shell "$INSTANCE" -- mkdir -p /tmp/agent-config
for f in agents.env model-access.env allowlist-bootstrap.conf allowlist-runtime.conf \
         pi-models.json model-gateway; do
  limactl copy "$CFG/$f" "$INSTANCE:/tmp/agent-config/$f"
done

# NOTE: single-quoted guest script. No apostrophes below this line until the
# closing quote -- one contraction silently runs the rest on the host.
say "installing config"
limactl shell "$INSTANCE" -- bash -eo pipefail -c '
  install -d -m 0700 "$HOME/.config/agent-sandbox"
  install -m 0600 /tmp/agent-config/agents.env       "$HOME/.config/agent-sandbox/agents.env"
  install -m 0600 /tmp/agent-config/model-access.env "$HOME/.config/agent-sandbox/model-access.env"

  # Pi opens ~/.pi/agent/sessions/<cwd>/<id>.jsonl without creating the parent
  # chain, so a missing sessions/ dir aborts the run with ENOENT. Create both.
  install -d -m 0700 "$HOME/.pi/agent" "$HOME/.pi/agent/sessions"
  install -m 0600 /tmp/agent-config/pi-models.json "$HOME/.pi/agent/models.json"

  # Export the credential that the apiKey reference above resolves against.
  if ! grep -q ARGO_CREDENTIAL "$HOME/.profile" 2>/dev/null; then
    {
      echo ""
      echo "# Model credential, read from the 0600 profile rather than inlined."
      echo "if [ -r \"\$HOME/.config/agent-sandbox/model-access.env\" ]; then"
      echo "  . \"\$HOME/.config/agent-sandbox/model-access.env\""
      echo "  export ARGO_CREDENTIAL=\"\$CREDENTIAL\""
      echo "  # Hermes reads its key from the environment. The systemd unit"
      echo "  # gets it via EnvironmentFile, but an interactive shell does not,"
      echo "  # and the gateway rejects an empty key with"
      echo "  # \"the username is not registered in ARGO\"."
      echo "  export HERMES_API_KEY=\"\$CREDENTIAL\""
      echo "fi"
    } >> "$HOME/.profile"
  fi

  sudo install -d -m 0755 /etc/agent-sandbox/allowlists
  sudo install -m 0644 /tmp/agent-config/allowlist-bootstrap.conf /etc/agent-sandbox/allowlists/
  sudo install -m 0644 /tmp/agent-config/allowlist-runtime.conf   /etc/agent-sandbox/allowlists/
  sudo install -m 0644 /tmp/agent-config/model-gateway /etc/agent-sandbox/model-gateway

  rm -rf /tmp/agent-config
'

# --- 4. Lock egress down ---------------------------------------------------
say "applying bootstrap egress policy"
limactl shell "$INSTANCE" -- sudo /usr/local/sbin/agent-egress bootstrap

# --- 5. Gate on a real completion ------------------------------------------
# Not /health: it answers 200 from local state even when the upstream is dead.
# That false green cost hours. Only a completion proves the whole path.
say "issuing a real completion from inside the VM"
RESP="$(limactl shell "$INSTANCE" -- bash -c "
  curl -s --noproxy '*' --max-time 90 -X POST '$MODEL_URL/v1/messages' \
    -H 'content-type: application/json' \
    -d '{\"model\":\"argo:claude-4.5-sonnet\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PATH_OK\"}]}'
" 2>/dev/null)"

if printf '%s' "$RESP" | grep -q PATH_OK; then
  say "model path works end to end"
else
  printf '\033[31merror:\033[0m completion failed from the VM.\n' >&2
  printf 'Endpoint tried: %s\n%s\n' "$MODEL_URL" "$(printf '%s' "$RESP" | head -c 300)" >&2
  exit 1
fi

echo
say "done. egress status:"
limactl shell "$INSTANCE" -- sudo /usr/local/sbin/agent-egress status
printf '\nNext: ./scripts/run-bootstrap.sh\n'
