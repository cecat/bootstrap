#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Validate the Telegram bot tokens in config/agents.env against getMe.
#
#   ./scripts/check-telegram-tokens.sh
#
# Separates "wrong config" from "wrong credential" in one call, which is why
# spec/pi-target-state.md requires Pi to do the same thing inside the VM. A
# token that looks right and is dead presents as a bot that simply never
# answers, and that is expensive to debug from the far end.
#
# The token is read from the 0600 file and passed to curl on stdin (-K -),
# never on the command line, so it is not visible in ps or in shell history.
# Nothing here prints a token.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="$REPO/config/agents.env"

[ -f "$ENVF" ] || { echo "config/agents.env not found. Nothing to check." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

rc=0
for var in OPENCLAW_TELEGRAM_BOT_TOKEN HERMES_TELEGRAM_BOT_TOKEN; do
  tok="${!var:-}"
  if [ -z "$tok" ]; then
    printf '  %-28s blank (no channel will be configured)\n' "$var"
    continue
  fi

  body="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$tok" \
          | curl -sS --max-time 20 -K - 2>&1)"

  if printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf '  %-28s OK -- @%s\n' "$var" "$(printf '%s' "$body" | jq -r '.result.username')"
  elif printf '%s' "$body" | jq -e '.ok == false' >/dev/null 2>&1; then
    printf '  %-28s REJECTED -- %s\n' "$var" "$(printf '%s' "$body" | jq -r '.description')"
    rc=1
  else
    # Not JSON: the request never reached Telegram. A network problem, not a
    # bad token -- and on a network that blocks api.telegram.org the channel
    # cannot be exercised at all, which is worth knowing before blaming Pi.
    printf '  %-28s UNREACHABLE -- %s\n' "$var" "$(printf '%s' "$body" | head -1)"
    rc=1
  fi
done

uid="${TELEGRAM_ALLOWED_USER_ID:-}"
case "$uid" in
  '')            printf '  %-28s blank (bots would answer nobody)\n' "TELEGRAM_ALLOWED_USER_ID" ;;
  *[!0-9]*)      printf '  %-28s NOT NUMERIC -- this must be a user id, not a @handle\n' "TELEGRAM_ALLOWED_USER_ID"; rc=1 ;;
  *)             printf '  %-28s set (%s digits)\n' "TELEGRAM_ALLOWED_USER_ID" "${#uid}" ;;
esac

exit "$rc"
