#!/usr/bin/env bash
# ===========================================================================
# check-frozen.sh -- has anything changed that should not have?
#
#   ./scripts/check-frozen.sh            report drift; exit 1 if any
#   ./scripts/check-frozen.sh --update   re-baseline, deliberately
#
# platform-frozen.txt lists the artifacts that took weeks to converge and
# cannot be re-derived by reading them. Nobody can look at the Pi spec and
# say which sentences are load-bearing for Pi's behaviour -- it is a prompt,
# and a plausible-looking reword can change what gets built without changing
# anything a diff review would flag.
#
# This exists because a second platform is being brought up against the same
# repo. A macOS session that "improves" one of these files could cost the
# Linux build the weeks it took to get right, and nobody would find out until
# the next Linux rebuild. Prose asking an agent not to was not enough: the
# rule against hand-fixing the VM was violated twice before it became a
# permission.
#
# Drift is not forbidden -- it is just never silent. To change a frozen file
# on purpose: make the change, run --update, and say so in the commit.
#
# openssl, not sha256sum: sha256sum is GNU-only and macOS ships shasum
# instead. openssl is already a bootstrap.sh preflight dependency and behaves
# identically on both.
# ===========================================================================
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"
MANIFEST="platform-frozen.txt"

if [ -t 1 ]; then R=$'\033[31m'; Y=$'\033[33m'; G=$'\033[32m'; Z=$'\033[0m'
else R=''; Y=''; G=''; Z=''; fi

hash_of() { openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'; }

# The paths under protection. Keep this list short: every addition is
# something a legitimate macOS fix might need and then cannot have.
FROZEN="spec/pi-target-state.md
lima/agents.yaml"

if [ "${1:-}" = "--update" ]; then
  {
    cat <<'EOF'
# Artifacts frozen against platform ports -- see scripts/check-frozen.sh.
#
# These converged over weeks of build-fail-adjust cycles and cannot be
# re-derived by reading them. A second platform (macOS) is being brought up
# against this same repo; changes for it belong in a uname branch in the
# host-side scripts, never in here.
#
# Nothing macOS-specific can legitimately go in the spec anyway: the VM has
# no mounts, so Pi cannot see the host, and it runs the same Ubuntu 24.04
# either way.
#
# Regenerate deliberately with: ./scripts/check-frozen.sh --update
EOF
    printf '\n'
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      printf '%s  %s\n' "$(hash_of "$f")" "$f"
    done <<<"$FROZEN"
  } > "$MANIFEST"
  printf '%s  ok%s  %s re-baselined\n' "$G" "$Z" "$MANIFEST"
  exit 0
fi

[ -f "$MANIFEST" ] || { printf '%serror:%s %s is missing. Re-baseline with --update.\n' \
  "$R" "$Z" "$MANIFEST" >&2; exit 1; }

drift=0 checked=0
while read -r want path; do
  case "$want" in ''|'#'*) continue ;; esac
  checked=$((checked + 1))
  if [ ! -f "$path" ]; then
    printf '%sdrift:%s %s is listed as frozen but does not exist\n' "$R" "$Z" "$path" >&2
    drift=$((drift + 1)); continue
  fi
  got="$(hash_of "$path")"
  [ "$got" = "$want" ] && continue
  printf '%sdrift:%s %s has changed since it was frozen\n' "$R" "$Z" "$path" >&2
  drift=$((drift + 1))
done < "$MANIFEST"

if [ "$drift" -gt 0 ]; then
  cat >&2 <<EOF

  ${Y}$drift of $checked frozen artifact(s) changed.${Z}

  If this was deliberate -- and on Linux it may well be -- re-baseline and
  say so in the commit:

      ./scripts/check-frozen.sh --update

  If you are porting to another platform, it was not deliberate. Put the
  change in a uname branch in the host-side scripts and leave these alone;
  see MACOS-TEST.md.

EOF
  exit 1
fi

printf '%s  ok%s  %s frozen artifact(s) unchanged\n' "$G" "$Z" "$checked"
