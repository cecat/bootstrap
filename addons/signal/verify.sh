#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Evidence for the Signal add-on.
#
#   ./scripts/addon-signal.sh verify [instance] [--live] [--base]
#
# Same contract as verify/verify.sh: assert the limits hold, not just that
# the happy path works. Pi's summary is a claim; this is the measurement.
#
#   --live   also send a real Signal message to the allowed number. Without
#            it the link is never exercised, and a dead link looks exactly
#            like a live one.
#   --base   also re-run the base verify/verify.sh and require it clean.
#
# Every check here traces to something that can actually go wrong -- the
# JVM ignoring the proxy, an empty allowlist, a second signal-cli fighting
# for the account lock. AGENTS.md: a suite that checks two hundred possible
# problems becomes the thing you debug.
#
# NO PHONE NUMBER IS EVER PRINTED. They are personal data and this output
# gets pasted into chats and issues. Checks compare them inside the guest
# and report only whether they matched.
# ---------------------------------------------------------------------------
set -uo pipefail

ADDON="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$ADDON/../.." && pwd)"
cd "$REPO"

DO_LIVE=0; DO_BASE=0; VM="${AGENTS_VM:-agents}"
for a in "$@"; do
  case "$a" in
    --live) DO_LIVE=1 ;;
    --base) DO_BASE=1 ;;
    --all)  DO_LIVE=1; DO_BASE=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
    *)  VM="$a" ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
if [ -t 1 ]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else R=''; G=''; Y=''; B=''; Z=''; fi

section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n' "$Y" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

g()     { limactl shell "$VM" -- bash -lc "$1" 2>&1; }
groot() { limactl shell "$VM" -- sudo bash -c "$1" 2>&1; }

[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null | head -1 || true)" = "Running" ] || {
  echo "instance '$VM' is not running." >&2; exit 1; }

ENVFILE="config/signal.env"
envval() {
  awk -v k="$1" '
    index($0, k "=") == 1 {
      v = substr($0, length(k) + 2)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      if (v ~ /^".*"$/ || v ~ /^'"'"'.*'"'"'$/) v = substr(v, 2, length(v) - 2)
      gsub(/^[ \t]+|[ \t\r]+$/, "", v)
      print v; exit
    }' "$ENVFILE" 2>/dev/null
}

[ -f "$ENVFILE" ] || { echo "$ENVFILE not found -- the add-on is not configured." >&2; exit 1; }

MODE="$(envval SIGNAL_MODE)"
case "$(envval SIGNAL_AGENT)" in
  hermes)   AGENTS="hermes" ;;
  openclaw) AGENTS="openclaw" ;;
  both)     AGENTS="hermes openclaw" ;;
  *)        AGENTS="" ;;
esac

# ---------------------------------------------------------------------------
section "Config stays private"

# A phone number is personal data, and config/ is one bad .gitignore away
# from a public repo. The base preflight checks this shape too; repeated
# here because this add-on is what adds the file.
if [ -f "$ENVFILE" ]; then
  mode="$(stat -c '%a' "$ENVFILE" 2>/dev/null || stat -f '%Lp' "$ENVFILE" 2>/dev/null)"
  [ "$mode" = "600" ] && pass "$ENVFILE is 0600" || fail "$ENVFILE is 0600" "mode $mode"
  git check-ignore -q "$ENVFILE" \
    && pass "$ENVFILE is invisible to git" \
    || fail "$ENVFILE is invisible to git" "it would be committed -- fix .gitignore"
fi

exposed="$( { git ls-files -- config/
              git status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
[ -z "$exposed" ] && pass "nothing under config/ is visible to git" \
                  || fail "nothing under config/ is visible to git" "$(printf '%s' "$exposed" | tr '\n' ' ')"

# ---------------------------------------------------------------------------
section "signal-cli is installed and actually runs"

ver="$(g 'signal-cli --version 2>&1' | head -1)"
case "$ver" in
  *signal-cli*)
    # Running at all proves the native library loaded -- on the wrong
    # architecture this is where UnsatisfiedLinkError surfaces, and it is
    # the single cheapest architecture check available.
    pass "signal-cli runs" "$ver" ;;
  *UnsatisfiedLinkError*|*libsignal*)
    fail "signal-cli runs" "the native library will not load -- wrong architecture.
        See the fallback in addons/signal/README.md" ;;
  *"not found"*|"")
    fail "signal-cli runs" "not installed" ;;
  *) fail "signal-cli runs" "$(printf '%s' "$ver" | cut -c1-120)" ;;
esac

# The JRE the package demands. A class-file-version error is the symptom,
# and Hermes' own documentation says "Java 17+", which is wrong -- so
# somebody following it would install 17 and get a confusing failure.
jver="$(g 'java -version 2>&1' | head -1 | grep -oE '"[0-9]+' | tr -dc '0-9')"
if [ -z "$jver" ]; then
  skip "Java is at least 25" "could not read java -version"
elif [ "$jver" -ge 25 ]; then
  pass "Java is at least 25" "found $jver"
else
  fail "Java is at least 25" "found $jver -- signal-cli 0.14 needs 25. Hermes' docs say
        'Java 17+' and are wrong. Java 25 is in noble-updates, not noble"
fi

# `|| true`, never `|| echo 0`: grep -c already prints 0 on no match and
# exits 1, so an echo fallback yields "00" and every comparison downstream
# is wrong.
acct="$(g 'signal-cli listAccounts 2>/dev/null | grep -cE "^(Number|Account|Path):|^\+[0-9]" || true' | tr -dc '0-9')"
[ "${acct:-0}" -ge 1 ] \
  && pass "an account is linked" "${acct} account(s) registered" \
  || fail "an account is linked" "signal-cli has no account -- run: addon-signal.sh link"

# ---------------------------------------------------------------------------
section "The daemon, and only one of it"

if g 'systemctl --user is-active signal-cli.service' | grep -q '^active'; then
  pass "signal-cli daemon is active"
  g 'systemctl --user is-enabled signal-cli.service' | grep -q 'enabled' \
    && pass "daemon is enabled at boot" \
    || fail "daemon is enabled at boot" "it will not come back after a reboot"
else
  fail "signal-cli daemon is active" "$(g 'systemctl --user is-active signal-cli.service' | head -1)"
fi

# The HTTP interface has no authentication -- signal-cli says so at
# startup. A loopback bind is therefore load-bearing, not cosmetic, and
# this is the same assertion the base suite makes about the gateways.
if g 'ss -lnt 2>/dev/null' | grep -qE '0\.0\.0\.0:(8080|7583)|\*:(8080|7583)'; then
  fail "the daemon is loopback-only" "it is bound to a wildcard address, and its HTTP
        interface has NO authentication"
else
  pass "the daemon is loopback-only" "its HTTP interface is unauthenticated, so this matters"
fi

# Two signal-cli processes against one data directory cannot both work:
# SignalAccount takes a file lock and the loser throws "Config file is in
# use by another instance". The usual cause is OpenClaw configured with
# managed-native, which spawns its own.
procs="$(g 'pgrep -fc "signal-cli" 2>/dev/null' | tr -dc '0-9')"
if [ -z "$procs" ] || [ "${procs:-0}" -le 1 ]; then
  pass "exactly one signal-cli is running"
else
  fail "exactly one signal-cli is running" "${procs} found -- they fight over the account
        lock. Usual cause: OpenClaw set to managed-native instead of external-native"
fi

# "contains account credentials -- protect it like a password", per the
# vendor. This directory IS the linked device.
dmode="$(g 'stat -c %a ~/.local/share/signal-cli 2>/dev/null' | tr -dc '0-7')"
case "$dmode" in
  700) pass "the account data directory is 0700" ;;
  "")  skip "the account data directory is 0700" "not found" ;;
  *)   fail "the account data directory is 0700" "mode $dmode -- it holds the account keys" ;;
esac

# ---------------------------------------------------------------------------
section "Never reachable without an allowlist"

# THE CHECK THAT MATTERS, and the reason it is phrased as a negative.
# Egress policy does not help: Signal DELIVERS inbound to whoever messages
# the account. The only thing between a stranger and an agent with shell
# access is the adapter's own allowlist. Empty means it answers anybody.
#
# Numbers are compared inside the guest and never printed.
want="$(envval SIGNAL_ALLOWED_USERS)"

# Is every configured number present in a guest file? Checked one number
# at a time: $want is a comma-separated LIST, so a single grep for the
# whole string fails whenever there is more than one entry, or whenever
# the adapter stored them in a different order -- reporting a correctly
# restricted agent as misconfigured. Each number is matched on its own and
# only a verdict comes back.
#
# A number reaching a guest shell is why install.sh validates E.164 first;
# anything with a quote in it would be a command-injection hazard here.
# Re-checked rather than assumed, because verify.sh can run against a
# hand-edited config that install.sh never saw.
all_numbers_present() {
  local file="$1" n
  local IFS=,
  for n in $want; do
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    [ -n "$n" ] || continue
    case "$n" in
      +[0-9]*) case "${n#+}" in *[!0-9]*) return 2 ;; esac ;;
      *) return 2 ;;
    esac
    g "grep -qF -- '$n' $file" >/dev/null 2>&1 || return 1
  done
  return 0
}

for a in $AGENTS; do
  case "$a" in
    hermes)
      if g 'test -f ~/.hermes/.env' >/dev/null 2>&1; then
        n="$(g 'grep -E "^SIGNAL_ALLOWED_USERS=" ~/.hermes/.env | head -1 | cut -d= -f2- | tr -d "\"[:space:]" | tr "," "\n" | grep -c .' | tr -dc '0-9')"
        if [ "${n:-0}" -ge 1 ]; then
          # Does it match what was configured? Compared in the guest so
          # neither value reaches this terminal.
          all_numbers_present '~/.hermes/.env'
          case $? in
            0) pass "Hermes Signal is restricted" "${n} allowed sender(s), all matching signal.env" ;;
            2) skip "Hermes Signal is restricted" "signal.env holds a number that is not E.164, so
        the comparison was not run. Fix config/signal.env" ;;
            *) fail "Hermes Signal is restricted" "${n} allowed sender(s), but NOT every number in
        signal.env -- you may not be able to talk to it, and someone else might" ;;
          esac
        else
          fail "Hermes Signal is restricted" "SIGNAL_ALLOWED_USERS is empty or absent in
        ~/.hermes/.env -- an unrestricted agent answers anyone who finds it"
        fi
      else
        skip "Hermes Signal is restricted" "~/.hermes/.env not readable -- nothing was checked"
      fi
      ;;
    openclaw)
      if g 'jq -e ".channels.signal" ~/.openclaw/openclaw.json >/dev/null 2>&1'; then
        pol="$(g 'jq -r ".channels.signal.dmPolicy // \"unset\"" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
        n="$(g 'jq -r "(.channels.signal.allowFrom // []) | length" ~/.openclaw/openclaw.json 2>/dev/null' | tr -dc '0-9')"
        if [ "$pol" = "allowlist" ] && [ "${n:-0}" -ge 1 ]; then
          pass "OpenClaw Signal is restricted" "dmPolicy=allowlist, ${n} allowed sender(s)"
        else
          fail "OpenClaw Signal is restricted" "dmPolicy=$pol with ${n:-0} entries -- anyone who
        finds this number could talk to an agent with shell access"
        fi

        # managed-native spawns a second signal-cli that collides on the
        # account lock. Caught above as a process count; caught here as
        # the configuration that causes it, which is the actionable form.
        kind="$(g 'jq -r ".channels.signal.transport.kind // \"unset\"" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
        case "$kind" in
          external-native) pass "OpenClaw uses the shared daemon" "transport.kind=external-native" ;;
          managed-native)  fail "OpenClaw uses the shared daemon" "transport.kind=managed-native --
        it will spawn a second signal-cli and collide on the account lock" ;;
          *)               fail "OpenClaw uses the shared daemon" "transport.kind=$kind" ;;
        esac
      else
        skip "OpenClaw Signal is restricted" "no signal channel configured"
      fi
      ;;
  esac
done

# A number in a config file is a number in a backup. The base suite runs
# this shape of check for bot tokens, for the same reason.
#
# One number at a time again, and the adapters' own config files are
# excluded -- the whole point of this add-on is that the number reaches
# ~/.hermes/.env and openclaw.json. What is being looked for is a stray
# COPY somewhere nobody decided on.
if [ -n "$want" ]; then
  leak=""
  IFS=, read -ra _nums <<<"$want"
  for n in "${_nums[@]}"; do
    n="$(printf '%s' "$n" | tr -d '[:space:]')"
    [ -n "$n" ] || continue
    case "$n" in +[0-9]*) case "${n#+}" in *[!0-9]*) continue ;; esac ;; *) continue ;; esac
    hit="$(g "grep -rlF -- '$n' \$HOME/.config/agent-sandbox/ 2>/dev/null | grep -v '/signal\.env$' | tr '\n' ' '")"
    leak="$leak$hit"
  done
  [ -z "$(printf '%s' "$leak" | tr -d '[:space:]')" ] \
    && pass "the number lives in the sanctioned files only" \
    || fail "the number lives in the sanctioned files only" "also in: $leak"
fi

# ---------------------------------------------------------------------------
section "It reaches Signal through squid"

# THE SILENT FAILURE. signal-cli is a Java program and the JVM does not
# read http_proxy/https_proxy. Without -Dhttps.proxyHost it opens a direct
# socket, the uid lockdown rejects it, and the error says "Network is
# unreachable" with no mention of a proxy -- the same shape as the
# httplib2 bug in the Google add-on.
unit="$(g 'systemctl --user cat signal-cli.service 2>/dev/null')"
case "$unit" in
  *proxyHost*)
    pass "the daemon has the JVM proxy settings" "-Dhttps.proxyHost is in the unit" ;;
  "")
    skip "the daemon has the JVM proxy settings" "could not read the unit" ;;
  *)
    fail "the daemon has the JVM proxy settings" "no -Dhttps.proxyHost in the unit. The JVM
        ignores http_proxy, so every Signal connection goes direct into the
        uid lockdown and fails with no proxy error anywhere" ;;
esac

# The cheapest possible proof that the setting actually took effect, as
# opposed to merely being present: squid's own log. A CONNECT tunnel to
# chat.signal.org is traffic that demonstrably went through the proxy.
# This distinguishes "proxy not configured" from "allowlist too narrow"
# from "Signal is down", which otherwise all look identical.
tunnel="$(groot 'grep -c "CONNECT chat.signal.org" /var/log/squid/access.log 2>/dev/null' | tr -dc '0-9')"
if [ "${tunnel:-0}" -ge 1 ]; then
  pass "squid has tunnelled Signal traffic" "${tunnel} CONNECT chat.signal.org in the access log"
else
  fail "squid has tunnelled Signal traffic" "no CONNECT to chat.signal.org in squid's log.
        Either the JVM proxy settings are not taking effect, or signal-cli has
        not connected since the log rotated. Check the unit above first"
fi

# ---------------------------------------------------------------------------
section "Nothing else was widened"

# An optional add-on that widens egress is changing the base system by the
# back door. Signal is reachable because squid already allows the public
# web on 443 -- no allowlist entry was needed, and none should have
# appeared. Read as root, the way the base suite does: an empty result
# because the file could not be read would otherwise pass.
active="$(groot 'cat /etc/agent-sandbox/allowlist.active 2>/dev/null')"
if [ -z "$(printf '%s' "$active" | tr -d '[:space:]')" ]; then
  skip "no Signal domain was added to the allowlist" "could not read allowlist.active"
else
  sdom="$(printf '%s\n' "$active" | grep -cE 'signal\.org|signal\.me|whispersystems' || true)"
  [ "${sdom:-0}" -eq 0 ] \
    && pass "no Signal domain was added to the allowlist" "none is needed; squid already allows public 443" \
    || fail "no Signal domain was added to the allowlist" "$sdom entries -- the add-on should
        not have widened egress"
fi

phase="$(g 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -dc 'a-z')"
[ "$phase" = "runtime" ] && pass "egress phase is still runtime" \
                         || fail "egress phase is still runtime" "phase: ${phase:-unknown}"

pcode="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://169.254.169.254/ 2>/dev/null')"
[ "$pcode" = "403" ] && pass "private network is still DENIED" "link-local -> 403" \
                     || fail "private network is still DENIED" "link-local -> ${pcode:-000}, expected 403"

# Telegram is not replaced by this add-on and must still be restricted.
# Worth one check: an add-on that quietly broke the other channel's
# allowlist would otherwise be invisible here.
if g 'grep -qE "^TELEGRAM_BOT_TOKEN=.+" ~/.hermes/.env' >/dev/null 2>&1; then
  he_alw="$(g 'grep -E "^TELEGRAM_ALLOWED_USERS=" ~/.hermes/.env | head -1 | cut -d= -f2-' | tr -d '\r ')"
  [ -n "$he_alw" ] && pass "Telegram is still restricted" "untouched by this add-on" \
                   || fail "Telegram is still restricted" "TELEGRAM_ALLOWED_USERS is now empty"
else
  skip "Telegram is still restricted" "no Telegram credentials configured"
fi

# ---------------------------------------------------------------------------
section "The vendors' own health checks"

# AGENTS.md requires this after any add-on, for every gateway it touched.
# Unlike the Google add-on, this one can touch BOTH. Exit codes are
# useless: hermes doctor exits 1 whenever any optional integration is
# absent, and openclaw doctor exits 0 even when ok:false. Parse the output
# against the base suite's exclusion list -- needing a NEW exclusion here
# means the add-on probably broke something.
DOCTOR_OK='DISCORD|XAI|GITHUB_TOKEN|system dependency not met|image generation unavailable|Nous Portal auth|OpenAI Codex auth|MiniMax OAuth|Docker/Podman not found|OpenRouter API'
doc_out="$(g 'hermes doctor 2>&1')"
if [ -z "$(printf '%s' "$doc_out" | tr -d '[:space:]')" ]; then
  skip "hermes doctor is still clean" "could not run hermes doctor"
else
  doc_bad="$(printf '%s\n' "$doc_out" | grep -E '^[[:space:]]*[✗✘×]' | head -5)"
  doc_warn="$(printf '%s\n' "$doc_out" | grep '⚠' | grep -viE "$DOCTOR_OK" | head -5)"
  n_filtered="$(printf '%s\n' "$doc_out" | grep -c '⚠' || true)"
  if [ -n "$doc_bad" ] || [ -n "$doc_warn" ]; then
    fail "hermes doctor is still clean" "$(printf '%s %s' "$doc_bad" "$doc_warn" | tr '\n' ' ' | cut -c1-200)"
  else
    pass "hermes doctor is still clean" "${n_filtered:-0} warnings, all on the known-optional list"
  fi
fi

case "$AGENTS" in
  *openclaw*)
    # --lint --all is not optional: a bare `openclaw doctor` selects 39 of
    # 69 checks and has reported ok:true findings:[] while the full run
    # found 33.
    oc_out="$(g 'openclaw doctor --lint --all --deep --json 2>/dev/null')"
    if [ -z "$(printf '%s' "$oc_out" | tr -d '[:space:]')" ]; then
      skip "openclaw doctor is still clean" "could not run openclaw doctor"
    else
      oc_bad="$(printf '%s' "$oc_out" | jq -r '[.findings // [] | .[] | select(.severity=="error")] | length' 2>/dev/null | tr -dc '0-9')"
      [ "${oc_bad:-0}" -eq 0 ] \
        && pass "openclaw doctor is still clean" "no error-severity findings across all checks" \
        || fail "openclaw doctor is still clean" "${oc_bad} error finding(s)"
    fi ;;
  *)
    skip "openclaw doctor is still clean" "OpenClaw has no Signal channel in this install" ;;
esac

# ---------------------------------------------------------------------------
section "Live Signal message"

if [ "$DO_LIVE" -eq 0 ]; then
  skip "a real Signal message is delivered" "re-run with --live; nothing above proves the link works"
elif [ -z "$want" ]; then
  skip "a real Signal message is delivered" "no allowed number configured"
else
  # Send to the allowed number through the running daemon. This is the
  # only check that exercises the link end to end: the daemon can be up,
  # the config right and every number valid over a link that was revoked
  # from the phone an hour ago.
  #
  # In note-to-self mode this is a message to yourself, which is exactly
  # how the user will talk to the agent anyway.
  first="$(printf '%s' "$want" | cut -d, -f1 | tr -d '[:space:]')"
  out="$(g "timeout 90 signal-cli send -m 'agent-sandbox: verify.sh test, no reply needed' '$first' 2>&1 | tail -3")"
  case "$out" in
    *[Ee]rror*|*xception*|*ailed*)
      fail "a real Signal message is delivered" "$(printf '%s' "$out" | tr -d '\r' | tail -1 | cut -c1-160)" ;;
    "")
      fail "a real Signal message is delivered" "no output from signal-cli send" ;;
    *)
      pass "a real Signal message is delivered" "sent to the allowed number -- check your phone" ;;
  esac
fi

# ---------------------------------------------------------------------------
section "Base build"

if [ "$DO_BASE" -eq 0 ]; then
  skip "the base system still verifies" "re-run with --base"
else
  BASELOG="$(mktemp -t signal-base-verify.XXXXXX)"
  printf '        %sthis takes 3-6 minutes%s -- tail -f %s\n' "$Y" "$Z" "$BASELOG"
  if ./verify/verify.sh >"$BASELOG" 2>&1; then
    pass "the base system still verifies" "$(grep -oE "[0-9]+ passed, [0-9]+ failed" "$BASELOG" | tail -1)"
  else
    fail "the base system still verifies" "see $BASELOG -- the add-on must not break the base build"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%s== Summary ==%s\n' "$B" "$Z"
printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$SKIP" "$Z"
if [ "$FAIL" -eq 0 ] && [ "$DO_LIVE" -eq 0 ]; then
  printf '\n  The wiring looks right, but NO SIGNAL MESSAGE WAS SENT. A link can be\n'
  printf '  configured, correctly scoped, and revoked from the phone an hour ago.\n'
  printf '  Run with --live before reporting this add-on as working.\n'
fi
if [ "$FAIL" -eq 0 ]; then
  if [ "$MODE" = "note-to-self" ]; then
    printf '\n  Last check is yours: message YOURSELF on Signal (Note to Self) and\n'
    printf '  ask the agent to fetch a web page. No script can do that one.\n'
  else
    printf '\n  Last check is yours: message the agent on Signal and ask it to fetch\n'
    printf '  a web page. No script can do that one.\n'
  fi
fi
exit $(( FAIL > 0 ? 1 : 0 ))
