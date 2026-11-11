#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Evidence for the OpenClaw Google add-on.
#
#   ./scripts/addon-google-openclaw.sh verify [instance] [--live] [--base]
#
# Same contract as verify/verify.sh: assert the limits hold, not just that
# the happy path works. Pi's summary is a claim; this is the measurement.
#
#   --live   also make a real Google API call through gog. Without it the
#            credential path is never exercised, and a dead token looks
#            exactly like a live one.
#   --base   also re-run the base verify/verify.sh and require it clean.
#
# Every check traces to something that can actually go wrong. AGENTS.md: a
# suite that checks two hundred possible problems becomes the thing you
# debug.
#
# NO CREDENTIAL, TOKEN OR KEYRING PASSWORD IS EVER PRINTED. Email
# addresses are treated the same way -- compared inside the guest, never
# echoed, because this output gets pasted into chats and issues.
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
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# gog needs its keyring environment on every invocation; the MCP server
# re-opens the keyring per call rather than unlocking once, so this prefix
# is what the real runtime looks like too.
GOGENV='set -a; . "$HOME/.config/agent-sandbox/openclaw-google.env" 2>/dev/null; set +a; export GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD="${GOOGLE_KEYRING_PASSWORD:-}" DBUS_SESSION_BUS_ADDRESS=disabled:;'

[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null | head -1 || true)" = "Running" ] || {
  echo "instance '$VM' is not running." >&2; exit 1; }

ENVFILE="config/openclaw-google.env"
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

WANT_SEND="$(envval GOOGLE_ALLOW_SEND)"

# ---------------------------------------------------------------------------
section "Config stays private"

mode="$(stat -c '%a' "$ENVFILE" 2>/dev/null || stat -f '%Lp' "$ENVFILE" 2>/dev/null)"
[ "$mode" = "600" ] && pass "$ENVFILE is 0600" || fail "$ENVFILE is 0600" "mode $mode"
git check-ignore -q "$ENVFILE" \
  && pass "$ENVFILE is invisible to git" \
  || fail "$ENVFILE is invisible to git" "it would be committed -- fix .gitignore"

exposed="$( { git ls-files -- config/
              git status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
[ -z "$exposed" ] && pass "nothing under config/ is visible to git" \
                  || fail "nothing under config/ is visible to git" "$(printf '%s' "$exposed" | tr '\n' ' ')"

# The consent handshake writes two URL files into config/. They are
# single-use and short-lived, and a leftover one means an interrupted run.
leftover="$(ls config/.openclaw-google-*-url.txt 2>/dev/null | tr '\n' ' ')"
[ -z "$(printf '%s' "$leftover" | tr -d '[:space:]')" ] \
  && pass "no consent URL files left behind" \
  || fail "no consent URL files left behind" "$leftover -- an auth run did not finish"

# ---------------------------------------------------------------------------
section "gog is installed and runs"

ver="$(g 'gog --version 2>&1' | head -1 | tr -d '\r')"
case "$ver" in
  *[0-9]*[.][0-9]*) pass "gog runs" "$ver" ;;
  *"not found"*|"") fail "gog runs" "not installed in the VM" ;;
  *exec\ format*)   fail "gog runs" "wrong architecture for this VM" ;;
  *) fail "gog runs" "$(printf '%s' "$ver" | cut -c1-120)" ;;
esac

# The binary must be the one we installed, not something that drifted in.
gmode="$(g 'stat -c %a /usr/local/bin/gog 2>/dev/null' | tr -dc '0-7')"
case "$gmode" in
  755) pass "gog is installed at 0755" ;;
  "")  skip "gog is installed at 0755" "not found at /usr/local/bin/gog" ;;
  *)   fail "gog is installed at 0755" "mode $gmode" ;;
esac

# ---------------------------------------------------------------------------
section "Credentials"

# auth doctor, judged on its JSON. The vendor is explicit that the exit
# code is useless: it "exits successfully when it emits a diagnostic
# report, even if that report has failed checks".
if g "$GOGENV gog --no-input --json auth doctor --check 2>/dev/null | jq -se 'length == 1 and .[0].status == \"ok\"'" | grep -q true; then
  pass "gog auth doctor reports ok" "judged on parsed JSON, not exit code"
else
  fail "gog auth doctor reports ok" "not authenticated, or the keyring environment is
        missing. Check GOG_KEYRING_BACKEND and that GOG_KEYRING_PASSWORD
        reached the process -- a working login shell proves nothing about a service"
fi

# The keyring IS the authorisation. Its own docs say to protect it like a
# password.
kmode="$(g 'stat -c %a "$HOME/.local/share/gogcli/keyring" 2>/dev/null || stat -c %a "$HOME/.config/gogcli/keyring" 2>/dev/null' | tr -dc '0-7' | head -3)"
case "$kmode" in
  700) pass "the keyring directory is 0700" ;;
  "")  skip "the keyring directory is 0700" "not found -- gog may store it elsewhere on this version" ;;
  *)   fail "the keyring directory is 0700" "mode $kmode" ;;
esac

emode="$(g 'stat -c %a "$HOME/.config/agent-sandbox/openclaw-google.env" 2>/dev/null' | tr -dc '0-7')"
case "$emode" in
  600) pass "the keyring password file is 0600" ;;
  "")  fail "the keyring password file is 0600" "missing from the VM" ;;
  *)   fail "the keyring password file is 0600" "mode $emode -- it holds the keyring password" ;;
esac

# The password must not be inlined into a unit, where `systemctl show`
# would print it. EnvironmentFile is the sanctioned route.
if g 'systemctl --user cat openclaw-gateway.service 2>/dev/null | grep -q "GOG_KEYRING_PASSWORD="'; then
  fail "the keyring password is not inlined in a unit" "it appears in a unit file, so
        systemctl show will print it. Use EnvironmentFile= instead"
else
  pass "the keyring password is not inlined in a unit"
fi

# ---------------------------------------------------------------------------
section "Wired into OpenClaw, and reachable"

mcp="$(g 'jq -r "(.mcp.servers // {}) | keys | join(\",\")" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
case "$mcp" in
  *gog*|*google*) pass "a gog MCP server is registered" "$mcp" ;;
  "") fail "a gog MCP server is registered" "no mcp.servers in openclaw.json" ;;
  *)  fail "a gog MCP server is registered" "servers present but none named for gog: $mcp" ;;
esac

# Registered is not reachable. OpenClaw's own words: "Saving a definition
# proves nothing about reachability -- the check does."
name="$(g 'jq -r "(.mcp.servers // {}) | keys[]" ~/.openclaw/openclaw.json 2>/dev/null | grep -iE "gog|google" | head -1' | tr -d '\r')"
if [ -n "$name" ]; then
  if g "openclaw mcp doctor '$name' --probe 2>&1" | grep -qiE '\bok\b|healthy|success'; then
    pass "the MCP server answers a probe" "openclaw mcp doctor --probe"
  else
    fail "the MCP server answers a probe" "defined but not reachable -- usually the
        keyring environment, because the server re-opens the keyring per call
        in a subprocess rather than unlocking once at startup"
  fi
else
  skip "the MCP server answers a probe" "no gog server found to probe"
fi

# ---------------------------------------------------------------------------
section "Only the access that was asked for"

args="$(g 'jq -r "(.mcp.servers // {}) | to_entries[] | select(.key|test(\"gog|google\";\"i\")) | (.value.args // []) | join(\" \")" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"

# The one scope that can put mail in front of a stranger. Checked against
# what the user actually asked for, in both directions -- a grant nobody
# requested is the failure, and so is a missing grant they did request.
case "$WANT_SEND:$args" in
  no:*--allow-gmail-send*|:*--allow-gmail-send*)
    fail "Gmail send matches what was configured" "the MCP server is started with
        --allow-gmail-send, but GOOGLE_ALLOW_SEND is '${WANT_SEND:-no}'. This agent
        can email anyone" ;;
  yes:*--allow-gmail-send*)
    pass "Gmail send matches what was configured" "granted, as requested" ;;
  yes:*)
    fail "Gmail send matches what was configured" "GOOGLE_ALLOW_SEND=yes but the server
        is not started with --allow-gmail-send, so the agent cannot send" ;;
  *)
    pass "Gmail send matches what was configured" "not granted; the agent can draft, not send" ;;
esac

# Permanent deletion is never wanted here and gog gates it behind an
# explicit flag. Its presence would be deliberate and wrong.
case "$args" in
  *--allow-gmail-delete*)
    fail "permanent Gmail deletion is NOT granted" "--allow-gmail-delete is set" ;;
  *)
    pass "permanent Gmail deletion is NOT granted" ;;
esac

# ---------------------------------------------------------------------------
section "The Hermes agent is untouched"

# This add-on must not reach into the other agent's account. Both agents
# run as one Unix user, so nothing PREVENTS it -- which is exactly why it
# is worth asserting.
hermes_acct="$(awk -v k="GOOGLE_ACCOUNT_EMAIL" '
  index($0, k "=") == 1 { v = substr($0, length(k) + 2)
    gsub(/^[ \t"'"'"']+|[ \t\r"'"'"']+$/, "", v); print v; exit }' config/google.env 2>/dev/null)"
oc_acct="$(envval GOOGLE_ACCOUNT)"
if [ -n "$hermes_acct" ] && [ -n "$oc_acct" ]; then
  [ "$hermes_acct" != "$oc_acct" ] \
    && pass "the two agents use different Google accounts" \
    || fail "the two agents use different Google accounts" "both are configured with the
        same address -- they would act as one identity"
else
  skip "the two agents use different Google accounts" "one of them is not configured"
fi

# gog must not have been pointed at Hermes' credential files.
if g 'test -f "$HOME/.hermes/google_token.json"' >/dev/null 2>&1; then
  hmode="$(g 'stat -c %a "$HOME/.hermes/google_token.json" 2>/dev/null' | tr -dc '0-7')"
  [ "$hmode" = "600" ] \
    && pass "Hermes' Google token is still 0600 and in place" \
    || fail "Hermes' Google token is still 0600 and in place" "mode $hmode"
else
  skip "Hermes' Google token is still 0600 and in place" "the Hermes add-on is not installed"
fi

# ---------------------------------------------------------------------------
section "The scheduler is alive"

# Not a feature test -- a silent scheduler means every recurring duty this
# agent is given later stops without anything failing.
sched="$(g 'openclaw automations status 2>&1 | head -5')"
case "$sched" in
  *[Dd]isabled*) fail "the automations scheduler is enabled" "reported disabled" ;;
  "")            skip "the automations scheduler is enabled" "could not read status" ;;
  *)             pass "the automations scheduler is enabled" "$(printf '%s' "$sched" | head -1 | cut -c1-80)" ;;
esac

# Default is false, which replays overdue slots on startup. That is the
# same failure the Hermes side hit -- a burst of stale messages after a
# suspend, each one delivered to a human.
skipmissed="$(g 'jq -r ".cron.skipMissedJobs // \"unset\"" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
case "$skipmissed" in
  true)  pass "missed schedules are skipped, not replayed" ;;
  *)     fail "missed schedules are skipped, not replayed" "cron.skipMissedJobs=$skipmissed.
        The default replays overdue slots at startup, so a suspend or restart
        delivers a burst of stale messages" ;;
esac

# ---------------------------------------------------------------------------
section "Sandbox unchanged"

phase="$(g 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -dc 'a-z')"
[ "$phase" = "runtime" ] && pass "egress phase is still runtime" \
                         || fail "egress phase is still runtime" "phase: ${phase:-unknown}"

# Google is reachable because squid already allows the public web on 443.
# An allowlist entry would mean this add-on widened egress by the back
# door. Read as root, the way the base suite does: an empty result because
# the file could not be read would otherwise pass.
active="$(groot 'cat /etc/agent-sandbox/allowlist.active 2>/dev/null')"
if [ -z "$(printf '%s' "$active" | tr -d '[:space:]')" ]; then
  skip "no Google domain was added to the allowlist" "could not read allowlist.active"
else
  gdom="$(printf '%s\n' "$active" | grep -cE 'googleapis|google\.com|gmail' || true)"
  [ "${gdom:-0}" -eq 0 ] \
    && pass "no Google domain was added to the allowlist" "none is needed; squid already allows public 443" \
    || fail "no Google domain was added to the allowlist" "$gdom entries"
fi

pcode="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://169.254.169.254/ 2>/dev/null')"
[ "$pcode" = "403" ] && pass "private network is still DENIED" "link-local -> 403" \
                     || fail "private network is still DENIED" "link-local -> ${pcode:-000}, expected 403"

# ---------------------------------------------------------------------------
section "The vendors' own health checks"

# Required after any add-on, for every gateway it touched. This one is
# OpenClaw's, but both gateways share a machine, so both doctors run.
# --lint --all is not optional: a bare `openclaw doctor` selects 39 of 69
# checks and has reported ok:true findings:[] while the full run found 33.
oc_out="$(g 'openclaw doctor --lint --all --json 2>/dev/null')"
if [ -z "$(printf '%s' "$oc_out" | tr -d '[:space:]')" ]; then
  skip "openclaw doctor is still clean" "could not run openclaw doctor"
else
  oc_bad="$(printf '%s' "$oc_out" | jq -r '[.findings // [] | .[] | select(.severity=="error")] | length' 2>/dev/null | tr -dc '0-9')"
  [ "${oc_bad:-0}" -eq 0 ] \
    && pass "openclaw doctor is still clean" "no error-severity findings across all checks" \
    || fail "openclaw doctor is still clean" "${oc_bad} error finding(s)"
fi

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

# ---------------------------------------------------------------------------
section "Live Google call"

if [ "$DO_LIVE" -eq 0 ]; then
  skip "a real Google API call succeeds" "re-run with --live; nothing above proves the token works"
else
  # A read, through gog, with the same environment the MCP server uses.
  # Writes nothing. Everything above can pass over a revoked token.
  live="$(g "$GOGENV timeout 90 gog --no-input --json calendar list 2>&1 | tail -3")"
  case "$live" in
    *invalid_grant*)
      fail "a real Google API call succeeds" "invalid_grant -- the refresh token is dead.
        The usual cause is an OAuth consent screen left in Testing, which expires
        tokens after 7 days. Publish it, then re-run auth" ;;
    *[Ee]rror*|*xception*)
      fail "a real Google API call succeeds" "$(printf '%s' "$live" | tail -1 | cut -c1-160)" ;;
    "")
      fail "a real Google API call succeeds" "no output from gog" ;;
    *)
      pass "a real Google API call succeeds" "a read reached Google and returned" ;;
  esac
fi

# ---------------------------------------------------------------------------
section "Base build"

if [ "$DO_BASE" -eq 0 ]; then
  skip "the base system still verifies" "re-run with --base"
else
  BASELOG="$(mktemp -t ocg-base-verify.XXXXXX)"
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
  printf '\n  The wiring looks right, but NO GOOGLE CALL WAS MADE. Credentials can\n'
  printf '  be in place, correctly scoped, and revoked an hour ago. Run with\n'
  printf '  --live before reporting this add-on as working.\n'
fi
if [ "$FAIL" -eq 0 ]; then
  printf '\n  Last check is yours: ask the agent to read something from Google --\n'
  printf '  a calendar, a sheet, a form response. No script proves the agent\n'
  printf '  reaches for the tool when asked; one has picked an unrelated tool\n'
  printf '  before and never called Google at all.\n'
fi
exit $(( FAIL > 0 ? 1 : 0 ))
