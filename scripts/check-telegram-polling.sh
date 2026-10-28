#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Is anything actively polling Telegram for these bots?
#
#   ./scripts/check-telegram-polling.sh
#
# "Configured but disabled" and "connected and polling" are different states,
# and config files cannot tell them apart -- a gateway that has already opened
# a long-poll keeps answering regardless of what a directory file says.
#
# Telegram settles it: only ONE getUpdates consumer is allowed per bot. If a
# second call returns 409 Conflict, something else is holding the poll open,
# which means the bot is live and would answer a message now.
#
# Reads tokens from the 0600 config file and passes them to curl on stdin,
# never on the command line. Nothing here prints a token, and getUpdates with
# timeout=0 consumes nothing.
# ---------------------------------------------------------------------------
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENVF="$REPO/config/agents.env"

[ -f "$ENVF" ] || { echo "config/agents.env not found." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required." >&2; exit 1; }

# shellcheck disable=SC1090
set -a; . "$ENVF"; set +a

rc=0
for var in OPENCLAW_TELEGRAM_BOT_TOKEN HERMES_TELEGRAM_BOT_TOKEN; do
  tok="${!var:-}"
  if [ -z "$tok" ]; then
    printf '  %-28s no token configured\n' "$var"
    continue
  fi

  # Sample several times, because the two answers are NOT symmetric. A 409
  # proves a consumer is holding the poll open. A 200 proves only that nobody
  # was holding it *at that instant* -- and a long-poll client reconnects in a
  # loop, so there is a short gap between calls where a probe slips through and
  # sees 200. On 2026-10-28 one run of this script said POLLING and the next
  # five said idle, for a Hermes adapter that was polling the whole time.
  # Treating a single 200 as "idle" is therefore a false pass on the one check
  # that guards against a live bot. Any 409 in the window wins.
  body=''
  for _ in 1 2 3 4 5 6; do
    body="$(printf 'url = "https://api.telegram.org/bot%s/getUpdates?timeout=0&limit=1"\n' "$tok" \
            | curl -sS --max-time 25 -K - 2>&1)"
    printf '%s' "$body" | jq -e '.error_code == 409' >/dev/null 2>&1 && break
    sleep 2
  done

  if printf '%s' "$body" | jq -e '.error_code == 409' >/dev/null 2>&1; then
    printf '  %-28s POLLING -- a consumer is live; this bot would answer now\n' "$var"
    rc=1
  elif printf '%s' "$body" | jq -e '.ok == true' >/dev/null 2>&1; then
    printf '  %-28s idle -- nothing is polling; the bot answers nobody\n' "$var"
  elif printf '%s' "$body" | jq -e '.ok == false' >/dev/null 2>&1; then
    printf '  %-28s rejected -- %s\n' "$var" "$(printf '%s' "$body" | jq -r '.description')"
    rc=1
  else
    printf '  %-28s UNREACHABLE -- %s\n' "$var" "$(printf '%s' "$body" | head -1)"
    rc=1
  fi
done

echo
if [ "$rc" = "0" ]; then
  echo "  No bot is being polled. Channels are off in the way that matters."
else
  echo "  At least one bot is live or unverifiable. If a channel was supposed"
  echo "  to be disabled, 'disabled' is not what the running system is doing."
fi
exit "$rc"
