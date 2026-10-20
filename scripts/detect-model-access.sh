#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Detect the model access the CALLING coding agent is using, and emit a
# provider profile the VM can be built from.
#
#   ./scripts/detect-model-access.sh            # summary + write the profile
#   ./scripts/detect-model-access.sh --dry-run  # summary only, write nothing
#
# Why this exists: the agents in the VM should reach the same models as the
# coding agent that is building them, without the user retyping endpoints.
#
# Source of truth, in order:
#   1. The live environment (ANTHROPIC_BASE_URL, ANTHROPIC_DEFAULT_*_MODEL).
#      Claude Code is launched as `claude --settings <file>`, so no fixed path
#      is authoritative -- but whatever it loaded is in this process's env.
#   2. ~/.claude/settings*.json, for `apiKeyHelper`, which is not exported.
#      We pick the file whose env.ANTHROPIC_BASE_URL matches the live value.
#
# Writes config/model-access.env (0600, gitignored). Never prints credentials.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/config/model-access.env"
DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

say()  { printf '\033[1m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33mwarning:\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || fail "jq is required but not installed."

# --- 1. Base URL and model names from the live environment -----------------
BASE_URL="${ANTHROPIC_BASE_URL:-}"
SETTINGS_SRC=""

# --- 2. Find the settings file that produced it, for apiKeyHelper ----------
API_KEY_HELPER=""
shopt -s nullglob
for f in "$HOME"/.claude/settings*.json; do
  # Skip backups and other non-JSON leftovers.
  jq -e . "$f" >/dev/null 2>&1 || continue
  f_url="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$f")"
  if [ -n "$BASE_URL" ] && [ "$f_url" = "$BASE_URL" ]; then
    SETTINGS_SRC="$f"
    API_KEY_HELPER="$(jq -r '.apiKeyHelper // empty' "$f")"
    break
  fi
done
# No live base URL: fall back to any settings file that declares one.
if [ -z "$BASE_URL" ]; then
  for f in "$HOME"/.claude/settings*.json; do
    jq -e . "$f" >/dev/null 2>&1 || continue
    f_url="$(jq -r '.env.ANTHROPIC_BASE_URL // empty' "$f")"
    if [ -n "$f_url" ]; then
      BASE_URL="$f_url"; SETTINGS_SRC="$f"
      API_KEY_HELPER="$(jq -r '.apiKeyHelper // empty' "$f")"
      warn "no ANTHROPIC_BASE_URL in the environment; falling back to $(basename "$f")"
      break
    fi
  done
fi
shopt -u nullglob

[ -n "$BASE_URL" ] || fail "could not determine a model endpoint.
Run this from inside the coding agent that already has model access, or set
ANTHROPIC_BASE_URL. See AGENTS.md -> 'Model access'."

MODEL_OPUS="${ANTHROPIC_DEFAULT_OPUS_MODEL:-}"
MODEL_SONNET="${ANTHROPIC_DEFAULT_SONNET_MODEL:-}"
MODEL_HAIKU="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-}"
if [ -n "$SETTINGS_SRC" ]; then
  [ -n "$MODEL_OPUS" ]   || MODEL_OPUS="$(jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // empty' "$SETTINGS_SRC")"
  [ -n "$MODEL_SONNET" ] || MODEL_SONNET="$(jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty' "$SETTINGS_SRC")"
  [ -n "$MODEL_HAIKU" ]  || MODEL_HAIKU="$(jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // empty' "$SETTINGS_SRC")"
fi

# --- 3. Loopback endpoints are a host gateway, not an error ----------------
# Off-site, the working model path is an SSH tunnel on the host to an
# argo-proxy running on an ANL machine (see `claude-argo-home`). The VM cannot
# reach the host's 127.0.0.1, but it CAN reach the host through Lima's user-
# mode gateway at 192.168.5.2 -- verified. So a loopback endpoint is recorded
# as a gateway to bridge, not rejected.
BASE_HOST="$(printf '%s' "$BASE_URL" | sed -E 's|^[a-z]+://||; s|[:/].*$||')"
BASE_PORT="$(printf '%s' "$BASE_URL" | sed -nE 's|^[a-z]+://[^:/]+:([0-9]+).*|\1|p')"
LIMA_HOST_GATEWAY="${LIMA_HOST_GATEWAY:-192.168.5.2}"
VM_BASE_URL=""
IS_GATEWAY=0

case "$BASE_HOST" in
  127.0.0.1|localhost|::1)
    IS_GATEWAY=1
    [ -n "$BASE_PORT" ] || BASE_PORT=44497
    VM_BASE_URL="http://$LIMA_HOST_GATEWAY:$BASE_PORT"
    say "host-side gateway detected on port $BASE_PORT"
    say "the VM will reach it at $VM_BASE_URL"
    if ! curl -fsS --noproxy '*' --max-time 6 "$BASE_URL/health" >/dev/null 2>&1; then
      warn "nothing is answering on $BASE_URL right now."
      warn "If this is your SSH tunnel, bring it up before running install-config.sh."
    fi
    ;;
esac

# --- 4. Resolve the credential (never printed) -----------------------------
CREDENTIAL=""; CRED_SOURCE=""
if [ -n "$API_KEY_HELPER" ]; then
  # A command from the user's own Claude Code settings.
  if CREDENTIAL="$(eval "$API_KEY_HELPER" 2>/dev/null)"; then
    CRED_SOURCE="apiKeyHelper"
  else
    warn "apiKeyHelper failed to run: $API_KEY_HELPER"
  fi
fi
if [ -z "$CREDENTIAL" ]; then
  if [ -n "${ANTHROPIC_API_KEY:-}" ];   then CREDENTIAL="$ANTHROPIC_API_KEY";   CRED_SOURCE="ANTHROPIC_API_KEY"
  elif [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then CREDENTIAL="$ANTHROPIC_AUTH_TOKEN"; CRED_SOURCE="ANTHROPIC_AUTH_TOKEN"
  fi
fi

# --- 5. Classify the provider ----------------------------------------------
if [ "$IS_GATEWAY" = "1" ]; then
  PROVIDER_KIND="gateway"
  PROVIDER_STATUS="implemented"
else
case "$BASE_HOST" in
  apps.inside.anl.gov)
    PROVIDER_KIND="argo"
    PROVIDER_STATUS="implemented"
    ;;
  api.anthropic.com)
    PROVIDER_KIND="anthropic"
    PROVIDER_STATUS="unimplemented"
    ;;
  *)
    PROVIDER_KIND="anthropic_compatible"
    PROVIDER_STATUS="unimplemented"
    ;;
esac
fi

# --- 6. Classify credential risk (drives the spend-cap warning) ------------
# Argo authenticates by ANL username plus network position: no spend to cap.
# Anything key-shaped crossing into a sandbox is a different matter.
CREDENTIAL_RISK="unknown"
if [ "$PROVIDER_KIND" = "argo" ] || [ "$PROVIDER_KIND" = "gateway" ]; then
  CREDENTIAL_RISK="low"
elif [ -z "$CREDENTIAL" ]; then
  CREDENTIAL_RISK="none"
else
  case "$CREDENTIAL" in
    sk-*|*[A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-][A-Za-z0-9_-]*)
      CREDENTIAL_RISK="high" ;;
    *) CREDENTIAL_RISK="low" ;;
  esac
fi

# --- 7. Report -------------------------------------------------------------
cred_desc="none found"
[ -n "$CREDENTIAL" ] && cred_desc="${#CREDENTIAL} chars, from $CRED_SOURCE"

cat >&2 <<SUMMARY

  Detected model access
  ---------------------
  endpoint      : $BASE_URL
  provider kind : $PROVIDER_KIND ($PROVIDER_STATUS)
  settings file : ${SETTINGS_SRC:-<none; from environment>}
  credential    : $cred_desc
  models        : ${MODEL_OPUS:-?} / ${MODEL_SONNET:-?} / ${MODEL_HAIKU:-?}

SUMMARY

if [ "$CREDENTIAL_RISK" = "high" ]; then
  cat >&2 <<'RISK'
  ------------------------------------------------------------------
  This looks like a spend-capable API key, and building the VM copies
  it inside -- into a sandbox whose whole purpose is containing agents
  you do not fully trust. The egress allowlist limits where it can be
  sent, but it does not stop the agents from spending against it.

  Prefer a dedicated key with a spend cap: put it in
  config/model-access.env as CREDENTIAL=... after this script runs.
  ------------------------------------------------------------------
RISK
fi

if [ "$PROVIDER_STATUS" = "unimplemented" ]; then
  cat >&2 <<UNIMPL
  ------------------------------------------------------------------
  Provider kind '$PROVIDER_KIND' is detected but NOT implemented.

  Only the Argo path is built out. The structure generalizes -- the VM
  runs a translation proxy exposing Anthropic to Pi/OpenClaw and
  OpenAI to Hermes -- but the non-Argo backend (LLM-Rosetta) is not
  wired up. Hermes in particular needs an OpenAI-compatible surface
  that $BASE_HOST does not provide on its own.

  See AGENTS.md -> 'Adding a provider'.
  ------------------------------------------------------------------
UNIMPL
  [ "$DRY_RUN" -eq 1 ] || fail "refusing to write a profile for an unimplemented provider."
fi

# --- 8. Write the profile --------------------------------------------------
if [ "$DRY_RUN" -eq 1 ]; then
  say "dry run: nothing written"
  exit 0
fi

mkdir -p "$(dirname "$OUT")"
umask 077
cat > "$OUT" <<PROFILE
# Generated by scripts/detect-model-access.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Gitignored. Regenerate rather than edit, unless you are substituting a
# dedicated API key -- in which case edit CREDENTIAL below and nothing else.
PROVIDER_KIND=$PROVIDER_KIND
UPSTREAM_BASE_URL=$BASE_URL
UPSTREAM_HOST=$BASE_HOST
IS_GATEWAY=$IS_GATEWAY
VM_BASE_URL=$VM_BASE_URL
VM_GATEWAY=${VM_BASE_URL#http://}
PROXY_PORT=${BASE_PORT:-44497}
CREDENTIAL=$CREDENTIAL
CREDENTIAL_SOURCE=$CRED_SOURCE
CREDENTIAL_RISK=$CREDENTIAL_RISK
MODEL_OPUS=$MODEL_OPUS
MODEL_SONNET=$MODEL_SONNET
MODEL_HAIKU=$MODEL_HAIKU
PROFILE
chmod 600 "$OUT"
say "wrote ${OUT#"$REPO"/} (0600)"
