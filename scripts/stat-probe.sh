#!/usr/bin/env bash
# ===========================================================================
# stat-probe.sh -- does log_mtime() actually work on this host?
#
# Throwaway diagnostic. On 2026-11-04 the Pi silence watchdog failed to fire
# on macOS after an hour of a dead build, with PI_SILENCE=600 and the
# log_mtime fix already in place. This shows what each branch of that
# fallback chain returns here, so the failure can be located rather than
# guessed at.
#
# Delete this once the watchdog is proven on macOS.
# ===========================================================================
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

f="logs/pi-last.log"
[ -e "$f" ] || { echo "no $f on this host -- run this where the build ran"; exit 1; }

echo "host:            $(uname -s)"
echo

printf 'GNU form   stat -c %%Y : '
out="$(stat -c %Y "$f" 2>/dev/null)"; rc=$?
printf '%s   (rc=%s)\n' "${out:-<empty>}" "$rc"

printf 'BSD form   stat -f %%m : '
out2="$(stat -f %m "$f" 2>/dev/null)"; rc2=$?
printf '%s   (rc=%s)\n' "${out2:-<empty>}" "$rc2"

# The chain as pi-session.sh runs it.
mt="$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || date +%s)"
now="$(date +%s)"
echo
echo "log_mtime() returns: $mt"
echo "now:                 $now"

# The subtraction is where a non-numeric value detonates or silently zeroes.
if quiet=$(( now - mt )) 2>/dev/null; then
  echo "computed quiet time: ${quiet}s   (watchdog fires at 600s)"
  if [ "$mt" = "$now" ]; then
    echo
    echo ">> mtime == now: the chain fell through to date +%s."
    echo "   quiet can never grow, so the watchdog can never fire."
  fi
else
  echo
  echo ">> the subtraction FAILED -- log_mtime returned something non-numeric."
fi
