#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Push local config into the VM and lock egress down.
#
#   ./scripts/install-config.sh [instance]      (default instance: agents)
#
# No model gateway runs in the VM. The host has one; detection recorded
# where, and the VM reaches it through Lima's host gateway.
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
# The live allowlists are gitignored copies of the committed templates.
# Seed when absent, and report drift rather than silently using a stale
# copy: edits to the template would otherwise never take effect, and edits
# to only the copy would vanish on a fresh clone.
for phase in bootstrap runtime; do
  live="$CFG/allowlist-$phase.conf"
  tmpl="$live.example"
  if [ ! -f "$live" ]; then
    cp "$tmpl" "$live"
  elif ! diff -q "$live" "$tmpl" >/dev/null 2>&1; then
    printf '\033[33mnote:\033[0m %s differs from its template.\n' "$live" >&2
    printf '      Using your local copy. If you meant to pick up a template\n' >&2
    printf '      change, diff them and delete the local copy to reseed:\n' >&2
    printf '        diff %s %s\n' "$live" "$tmpl" >&2
  fi
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

  # Export the credentials that the SecretRefs above resolve against.
  #
  # Delimited and rewritten in place, never appended-once. A guard like
  # "is ARGO_CREDENTIAL already present" means later additions to this
  # block never reach a VM that was already provisioned, and this script
  # is re-run whenever config changes.
  PROFILE_BEGIN="# >>> agent-sandbox env >>>"
  PROFILE_END="# <<< agent-sandbox env <<<"
  touch "$HOME/.profile"
  if grep -qF "$PROFILE_BEGIN" "$HOME/.profile"; then
    sed -i "/$PROFILE_BEGIN/,/$PROFILE_END/d" "$HOME/.profile"
  fi
  # Retire the pre-delimiter version of this block if it is still there.
  if grep -q "ARGO_CREDENTIAL" "$HOME/.profile"; then
    python3 - "$HOME/.profile" <<-PYEOF
		import re, sys
		p = sys.argv[1]
		s = open(p).read()
		s = re.sub(r"\n# Model credential, read from the 0600 profile.*?\nfi\n(if \[ -r \"\$HOME/\.config/agent-sandbox/agents\.env\" \]; then.*?\nfi\n)?",
		           "\n", s, flags=re.S)
		open(p, "w").write(s)
	PYEOF
  fi
  {
      echo "$PROFILE_BEGIN"
      echo "# Model credential, read from the 0600 profile rather than inlined."
      echo "if [ -r \"\$HOME/.config/agent-sandbox/model-access.env\" ]; then"
      echo "  . \"\$HOME/.config/agent-sandbox/model-access.env\""
      echo "  export ARGO_CREDENTIAL=\"\$CREDENTIAL\""
      echo "  # Hermes reads its key from the environment. The systemd unit"
      echo "  # gets it via EnvironmentFile, but an interactive shell does not,"
      echo "  # and the gateway rejects an empty key with"
      echo "  # \"the username is not registered in ARGO\"."
      echo "  export HERMES_API_KEY=\"\$CREDENTIAL\""
      echo "  # OpenClaw resolves gateway.auth.token and its provider apiKey"
      echo "  # from env SecretRefs, so openclaw.json holds no plaintext."
      echo "  # Without these, every openclaw CLI call fails with"
      echo "  # \"configured as a secret reference but is unavailable in"
      echo "  # this command path\". The service gets them from a systemd"
      echo "  # drop-in; this is what makes an interactive shell work."
      echo "  export CREDENTIAL"
      echo "fi"
      echo "if [ -r \"\$HOME/.config/agent-sandbox/agents.env\" ]; then"
      echo "  . \"\$HOME/.config/agent-sandbox/agents.env\""
      echo "  # Every secret an agent config may hold as an env SecretRef must"
      echo "  # be exported here, not just the gateway token: openclaw secrets"
      echo "  # audit reports unresolved=N for any ref it cannot see, and the"
      echo "  # CLI refuses the command path. Channel tokens are easy to miss"
      echo "  # because the gateway itself resolves them from its EnvironmentFile"
      echo "  # and keeps working, so only the CLI looks broken."
      echo "  export OPENCLAW_GATEWAY_TOKEN"
      echo "  export OPENCLAW_TELEGRAM_BOT_TOKEN"
      echo "  export HERMES_TELEGRAM_BOT_TOKEN"
      echo "  export TELEGRAM_ALLOWED_USER_ID"
      echo "fi"
      echo "$PROFILE_END"
  } >> "$HOME/.profile"

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
#
# STREAMING, because that is what Pi does. A non-streaming gate passes on a
# path where SSE is broken, and the user then sees Pi die with an opaque
# upstream error that looks like anything but "the gate did not test this".
#
# Retried, because the first real failure here was transient: one attempt
# returned "Upstream stream ended before completion" and every attempt
# afterwards succeeded. A single-shot gate turns a blip into a hard stop
# halfway through a build.
say "issuing a real streaming completion from inside the VM"
ok_path=0
for attempt in 1 2 3; do
  RESP="$(limactl shell "$INSTANCE" -- bash -c "
    curl -sN --noproxy '*' --max-time 90 -X POST '$MODEL_URL/v1/messages' \
      -H 'content-type: application/json' \
      -d '{\"model\":\"argo:claude-4.5-sonnet\",\"max_tokens\":16,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: PATH_OK\"}]}'
  " 2>/dev/null)"
  # Reassemble the text_delta fragments before matching. A stream splits the
  # marker across deltas ("PATH" + "_OK"), so grepping the raw SSE for
  # PATH_OK never matches and this gate fails against a perfectly good
  # gateway -- which it did, on the first run after it was written.
  #
  # message_stop as well as the text: a stream that delivers content and then
  # dies mid-flight is exactly the failure this gate exists to catch.
  TEXT="$(printf '%s' "$RESP" | grep -o '"text": *"[^"]*"' | sed 's/.*: *"//; s/"$//' | tr -d '\n')"
  if [ "$TEXT" = "PATH_OK" ] && printf '%s' "$RESP" | grep -q message_stop; then
    ok_path=1
    [ "$attempt" -eq 1 ] || say "succeeded on attempt $attempt (the first was transient)"
    break
  fi
  [ "$attempt" -lt 3 ] && { say "attempt $attempt failed; retrying in 5s"; sleep 5; }
done

if [ "$ok_path" = "1" ]; then
  say "model path works end to end (streaming)"
else
  printf '\033[31merror:\033[0m streaming completion failed from the VM, 3 times.\n' >&2
  printf 'Endpoint tried: %s\n%s\n' "$MODEL_URL" "$(printf '%s' "$RESP" | head -c 300)" >&2
  printf '\nIf a NON-streaming request to the same URL works, the gateway is\n' >&2
  printf 'reachable but its SSE path is not -- check argo-proxy, not the network.\n' >&2
  exit 1
fi

# --- 6. Gate on a PROXIED destination too ----------------------------------
# The completion above uses --noproxy, because the model gateway is reached
# directly and is exempt from squid by uid. That means it proves nothing
# about the proxy path -- a VM with a broken proxy still passes it, and then
# every channel fails later with EHOSTUNREACH while the model path stays
# green. Check an allowlisted host that must traverse squid.
say "checking the proxy path (not just the direct model path)"
PROXY_CODE="$(limactl shell "$INSTANCE" -- bash -lc "
  curl -s -o /dev/null -w '%{http_code}' --max-time 30 https://pi.dev/ 2>/dev/null
" 2>/dev/null | tr -dc '0-9')"

case "$PROXY_CODE" in
  2??|3??) say "proxy path works (pi.dev -> HTTP $PROXY_CODE)" ;;
  *)
    printf '\033[31merror:\033[0m the proxy path is broken (pi.dev -> %s).\n' "${PROXY_CODE:-no response}" >&2
    printf 'The model path works, so this is easy to miss -- but every\n' >&2
    printf 'allowlisted destination, including chat channels, will fail\n' >&2
    printf 'EHOSTUNREACH until it is fixed. Check http_proxy/https_proxy and\n' >&2
    printf 'NODE_USE_ENV_PROXY in the guest, and squid: agent-egress status.\n' >&2
    exit 1
    ;;
esac

echo
say "done. egress status:"
limactl shell "$INSTANCE" -- sudo /usr/local/sbin/agent-egress status
printf '\nNext: ./scripts/pi-session.sh build\n'
