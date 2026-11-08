#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Evidence for the Google Workspace add-on.
#
#   ./scripts/addon-google-workspace.sh verify [instance]
#
# Same contract as verify/verify.sh: asserts the limits hold, not just that
# the happy path works. Pi's summary is a claim; this is the measurement.
#
#   --live   also make a real Google API call (lists calendars; writes
#            nothing). Without it the credential path is never exercised,
#            and a wrong refresh token looks exactly like a right one.
#   --base   also re-run the base verify/verify.sh and require it clean.
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
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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

# The eight scopes Hermes' bundled skill checks for. Its setup.py compares
# the token's recorded scopes against its own list and reports
# "AUTHENTICATED (partial)" for any it cannot find -- which does not stop
# the gateway starting, so nothing surfaces until a call fails. Keep this
# list identical to SKILL_SCOPES in auth/google-oauth.py.
SKILL_SCOPES="gmail.readonly gmail.send gmail.modify calendar drive contacts.readonly spreadsheets documents"

# Where the skill looks for its credentials. $HERMES_HOME if set, else
# ~/.hermes -- resolved as the GATEWAY sees it, not as an interactive
# shell does, because a user service does not read ~/.profile and the two
# disagreeing is a documented way for a check to pass while the agent is
# broken.
HHOME="$(g 'systemctl --user show-environment 2>/dev/null | sed -n "s/^HERMES_HOME=//p" | head -1' | tr -d '[:space:]')"
[ -n "$HHOME" ] || HHOME='$HOME/.hermes'
SKILLDIR="$HHOME/skills/productivity/google-workspace"

# ---------------------------------------------------------------------------
section "Credentials stay secret"

for f in config/google.env config/google_token.json config/google_client_secret.json; do
  if [ -f "$f" ]; then
    mode="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null)"
    [ "$mode" = "600" ] && pass "$f is 0600" \
                        || fail "$f is 0600" "mode $mode"
    if git check-ignore -q "$f"; then
      pass "$f is invisible to git"
    else
      fail "$f is invisible to git" "it would be committed -- fix .gitignore and rotate the token"
    fi
  else
    skip "$f is 0600" "not present on the host"
  fi
done

# Anything under config/ that is not an example must stay out of git. The
# base preflight checks this too; repeated here because this add-on is what
# adds new files there.
exposed="$( { git ls-files -- config/
              git status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
[ -z "$exposed" ] && pass "nothing under config/ is visible to git" \
                  || fail "nothing under config/ is visible to git" "$(printf '%s' "$exposed" | tr '\n' ' ')"

# A refresh token in any file but the sanctioned one is a copy nobody
# decided to make. This is the shape of check the base suite already runs
# for Telegram bot tokens, for the same reason. google_token.json is the
# sanctioned home and is excluded; node_modules and lock files are excluded
# because "1//" followed by base64-ish characters occurs in minified JS and
# integrity hashes, which was a false alarm rather than a leak.
if ! g "test -f $HHOME/google_token.json" >/dev/null 2>&1; then
  skip "the refresh token lives in one file only" "no credentials installed in the VM yet"
else
  dup="$(g "grep -rlE '1//[A-Za-z0-9_-]{20,}' $HHOME/ \$HOME/.config/agent-sandbox/ \$HOME/.openclaw/ \$HOME/google-skill-push/ 2>/dev/null | grep -vE '/google_token\.json$|/node_modules/|package-lock\.json$' | tr '\n' ' '")"
  [ -z "$(printf '%s' "$dup" | tr -d '[:space:]')" ] \
    && pass "the refresh token lives in one file only" \
    || fail "the refresh token lives in one file only" "also in: $dup"
fi

# ---------------------------------------------------------------------------
section "The skill has what it needs"

# Hermes refuses to start a cron job whose attached skill is missing a
# declared credential file -- it reports blocked_config and alerts once.
# That refusal, on exactly these two names, is what broke the first inbox
# digest. Check them by the names the skill declares, in the home the
# gateway resolves.
for f in google_token.json google_client_secret.json; do
  mode="$(g "stat -c %a $HHOME/$f 2>/dev/null" | tr -dc '0-7')"
  if [ -z "$mode" ]; then
    fail "$f is in place for the skill" \
         "missing from $HHOME -- this is the exact condition that blocks a cron job
        with: attached skill 'google-workspace' is not ready"
  elif [ "$mode" != "600" ]; then
    fail "$f is in place for the skill" "mode $mode, want 600"
  else
    pass "$f is in place for the skill" "0600 in the home the gateway resolves"
  fi
done

# google_client_secret.json is never read at runtime -- the skill's
# google_api.py assigns its path and never opens it. It exists solely
# because the preflight above demands it. Say so, so nobody "tidies" it
# away and re-creates the failure.
pass "the client-secret file is present for the preflight, not for use" \
     "nothing reads it at runtime; Hermes requires it to exist"

# A token short of a scope does not fail loudly. setup.py prints
# "AUTHENTICATED (partial)" and carries on, so the first symptom is a call
# failing much later.
if ! g "test -f $HHOME/google_token.json" >/dev/null 2>&1; then
  skip "the token carries all eight scopes the skill wants" "no token in the VM"
else
  missing=""
  for s in $SKILL_SCOPES; do
    g "grep -q 'auth/$s\"' $HHOME/google_token.json" >/dev/null 2>&1 || missing="$missing $s"
  done
  [ -z "$missing" ] \
    && pass "the token carries all eight scopes the skill wants" \
    || fail "the token carries all eight scopes the skill wants" \
            "missing:$missing -- re-consent host-side: addon-google-workspace.sh auth --force"
fi

# Gmail stops at modify, and Google enforces it: under this scope the API
# refuses messages.delete, so trashed mail stays recoverable for 30 days.
# This limit survived the move off the MCP server because it was never
# ours -- it is Google's.
if ! g "test -f $HHOME/google_token.json" >/dev/null 2>&1; then
  skip "Gmail stops at gmail.modify" "no token in the VM"
elif g "grep -q 'https://mail.google.com/' $HHOME/google_token.json" >/dev/null 2>&1; then
  fail "Gmail stops at gmail.modify" \
       "the token carries the full-mailbox scope -- permanent deletion becomes possible"
else
  pass "Gmail stops at gmail.modify" "Google refuses permanent deletion under it"
fi

# The bundled skill must be present and not switched off. It ships with
# Hermes, so absence means something removed it rather than something
# needing installing.
skills="$(g 'hermes skills list 2>/dev/null')"
case "$skills" in
  *google-workspace*) pass "the bundled google-workspace skill is present" ;;
  "") skip "the bundled google-workspace skill is present" "could not read hermes skills list" ;;
  *) fail "the bundled google-workspace skill is present" \
          "not in hermes skills list -- it is bundled, so investigate rather than installing one" ;;
esac

disabled="$(g 'hermes config get skills.disabled 2>/dev/null; hermes config get skills.platform_disabled 2>/dev/null')"
case "$disabled" in
  *google-workspace*) fail "the skill is not disabled" \
                           "named in skills.disabled or skills.platform_disabled" ;;
  *) pass "the skill is not disabled" ;;
esac

# ---------------------------------------------------------------------------
section "It can reach Google through squid"

# httplib2 does `try: import socks / except ImportError: socks = None`, and
# its isgood() is false when socks is None -- at which point the HTTPS path
# opens a DIRECT socket and never says so. Under this VM's uid lockdown
# that hangs or is refused, with no proxy error anywhere, because httplib2
# never believed it had a proxy. PySocks is not a Hermes dependency, so
# nothing else installs it.
#
# Ask the interpreter the gateway actually runs, not python3 on $PATH.
#
# Three ways, because the first two can both miss. Hermes' launcher is a
# /bin/sh wrapper, so the unit's ExecStart names no python at all, and
# reading the wrapper's shebang yields /bin/sh -- which imports nothing and
# would report a real failure for an entirely wrong reason. The wrapper
# does name its interpreter in the body, so grep that; fall back to
# whatever the gateway process is actually executing.
HPY="$(g 'systemctl --user show hermes-gateway.service -p ExecStart --value 2>/dev/null | grep -oE "/[^ ]*/bin/python[0-9.]*" | head -1' | tr -d '[:space:]')"
if [ -z "$HPY" ]; then
  HPY="$(g 'h="$(systemctl --user show hermes-gateway.service -p ExecStart --value 2>/dev/null | sed -n "s/.*path=\([^ ;]*\).*/\1/p" | head -1)"; [ -n "$h" ] || h="$(command -v hermes)"; grep -ohE "/[^ \"'\'']*/python[0-9.]*" "$h" 2>/dev/null | sort -u | head -1' | tr -d '[:space:]')"
fi
if [ -z "$HPY" ]; then
  HPY="$(g 'pid="$(systemctl --user show hermes-gateway.service -p MainPID --value 2>/dev/null)"; [ -n "$pid" ] && [ "$pid" != 0 ] && readlink -f "/proc/$pid/exe" 2>/dev/null' | tr -d '[:space:]')"
fi
case "$HPY" in */python*) ;; *) HPY="" ;; esac
if [ -z "$HPY" ]; then
  skip "PySocks is installed where Hermes will load it" "could not find the gateway interpreter"
else
  case "$(g "$HPY -c 'import socks; print(\"SOCKS_OK\")' 2>&1")" in
    *SOCKS_OK*) pass "PySocks is installed where Hermes will load it" "$HPY" ;;
    *) fail "PySocks is installed where Hermes will load it" \
            "import socks failed in $HPY -- httplib2 will silently bypass the proxy
        and every Google call will hang at the uid lockdown with no error" ;;
  esac
fi

# Hermes strips most variables from the children of its terminal and
# execute_code tools, and http_proxy/https_proxy match none of its safe
# prefixes. The skill's scripts run as exactly such a child, so without
# this they get no proxy at all. The value is cached per home, so an edit
# without a gateway restart looks applied and does nothing.
ept="$(g 'hermes config get terminal.env_passthrough 2>/dev/null')"
case "$ept" in
  *https_proxy*|*HTTPS_PROXY*)
    pass "the skill's subprocesses are given the proxy" "terminal.env_passthrough names it" ;;
  "") fail "the skill's subprocesses are given the proxy" \
           "terminal.env_passthrough is unset -- Hermes strips http_proxy/https_proxy
        from skill subprocesses, so Google calls never reach squid" ;;
  *)  fail "the skill's subprocesses are given the proxy" \
           "terminal.env_passthrough exists but does not name https_proxy" ;;
esac

# ---------------------------------------------------------------------------
section "Nothing else was widened"

# A token in a config file is a token in a backup. Only meaningful once
# the home exists -- grepping a directory that is not there finds nothing
# and would otherwise read as a clean bill of health.
if ! g "test -d $HHOME" >/dev/null 2>&1; then
  skip "no credential written into Hermes config" "$HHOME does not exist -- nothing was checked"
else
  leak="$(g "grep -rlE 'GOOGLE_(CLIENT_SECRET|REFRESH_TOKEN)=.?[A-Za-z0-9/_-]{10,}' $HHOME/ 2>/dev/null | tr '\n' ' '")"
  [ -z "$(printf '%s' "$leak" | tr -d '[:space:]')" ] \
    && pass "no credential written into Hermes config" \
    || fail "no credential written into Hermes config" "found in: $leak"
fi

# This add-on is for one agent. OpenClaw getting Google access would be a
# quiet expansion of what the other agent can reach.
#
# Read the config file directly and require that we actually read it: a
# negative claim backed by a command that returned nothing is not evidence.
if ! g 'test -s $HOME/.openclaw/openclaw.json' >/dev/null 2>&1; then
  skip "OpenClaw has NO Google access" "openclaw.json not readable -- nothing was checked"
else
  oc="$(g 'cat $HOME/.openclaw/openclaw.json 2>/dev/null')"
  case "$oc" in
    *google*)
      fail "OpenClaw has NO Google access" "openclaw.json mentions google -- this add-on is meant to be Hermes-only" ;;
    *) pass "OpenClaw has NO Google access" "this add-on is Hermes-only" ;;
  esac
fi

# The MCP server this add-on used to install. A machine upgraded in place
# should have none of it left: a parked server and a stale systemd drop-in
# would otherwise survive, invisible, alongside the working skill.
leftover="$(g 'ls -d $HOME/google-mcp-src $HOME/.local/share/agent-sandbox/google-mcp $HOME/.config/agent-sandbox/google-creds $HOME/.config/systemd/user/hermes-gateway.service.d/20-google.conf 2>/dev/null | tr "\n" " "')"
[ -z "$(printf '%s' "$leftover" | tr -d '[:space:]')" ] \
  && pass "no leftovers from the old MCP server" \
  || fail "no leftovers from the old MCP server" \
          "still present: $leftover -- run: addon-google-workspace.sh remove, then install again"

mcpref="$(g 'hermes config get mcp_servers 2>/dev/null')"
case "$mcpref" in
  *google*) fail "no google-workspace mcp_servers entry remains" \
                 "the Hermes config still registers the old server" ;;
  *) pass "no google-workspace mcp_servers entry remains" ;;
esac

# ---------------------------------------------------------------------------
section "Sandbox unchanged"

# An optional add-on that widens egress would be changing the base system
# by the back door. Google is reachable because squid already allows the
# public web on 443 -- no allowlist entry was needed, and none should
# have appeared.
phase="$(g 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -dc 'a-z')"
[ "$phase" = "runtime" ] && pass "egress phase is still runtime" \
                         || fail "egress phase is still runtime" "phase: ${phase:-unknown}"

# Read it as root, the way the base suite reads egress state: an empty
# result because the file could not be read would otherwise count as
# "no Google domains found" and pass.
active="$(groot 'cat /etc/agent-sandbox/allowlist.active 2>/dev/null')"
if [ -z "$(printf '%s' "$active" | tr -d '[:space:]')" ]; then
  skip "no Google domain was added to the allowlist" "could not read allowlist.active -- nothing was checked"
else
  gdom="$(printf '%s\n' "$active" | grep -cE 'googleapis|google\.com|gmail' || true)"
  [ "${gdom:-0}" -eq 0 ] \
    && pass "no Google domain was added to the allowlist" "none is needed; squid already allows public 443" \
    || fail "no Google domain was added to the allowlist" "$gdom entries -- the add-on should not have widened egress"
fi

pcode="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://169.254.169.254/ 2>/dev/null')"
[ "$pcode" = "403" ] && pass "private network is still DENIED" "link-local -> 403" \
                     || fail "private network is still DENIED" "link-local -> ${pcode:-000}, expected 403"

# ---------------------------------------------------------------------------
section "Live Google call"

if [ "$DO_LIVE" -eq 0 ]; then
  skip "a real Google API call succeeds" "re-run with --live; nothing above proves the token works"
elif [ -z "$HPY" ]; then
  skip "a real Google API call succeeds" "could not find the gateway interpreter to run it with"
else
  # The skill's own --check-live, which lists calendars. Writes nothing.
  #
  # --check is NOT good enough and must not be substituted: it only
  # refreshes the token, and refreshing goes through `requests`, which
  # honours proxy variables natively. So --check can pass while every real
  # API call fails on the httplib2 path above. --check-live makes an actual
  # API call and is the only thing that exercises it.
  # The skill's scripts import `pm`, which only resolves inside Hermes'
  # own environment -- plain python3 answers "Run this script in the
  # Hermes environment" and proves nothing. Rebuild that environment the
  # way Hermes' launcher does: its interpreter, plus the installed venv's
  # site-packages and the hermes-agent tree on PYTHONPATH. The venv hash
  # is per-install, so find it rather than hard-coding one.
  # `pm` itself lives in the hermes-agent tree; site-packages supplies the
  # dependencies it imports. Several environments sit side by side (an
  # upgrade leaves the old generations in place), so pick by content --
  # googleapiclient is the one the skill cannot run without -- rather than
  # taking whichever the shell globs first. Newest first.
  SITEPKGS="$(g 'for d in $(ls -1dt $HOME/.hermes/installs/*/environments/*/venv/lib/python*/site-packages 2>/dev/null); do if [ -d "$d/googleapiclient" ]; then printf %s "$d"; break; fi; done' | tr -d '[:space:]')"
  # $HHOME and $SKILLDIR may still contain a literal $HOME for the guest
  # shell to expand, so they are deliberately left unquoted here.
  live="$(g "export HERMES_HOME=$HHOME PYTHONPATH=\"$SITEPKGS:\$HOME/.hermes/hermes-agent\" http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128; '$HPY' $SKILLDIR/scripts/setup.py --check-live 2>&1 | tail -5")"
  case "$live" in
    *LIVE_CHECK_OK*)
      pass "a real Google API call succeeds" "setup.py --check-live reached Google" ;;
    *"AUTHENTICATED (partial)"*)
      fail "a real Google API call succeeds" \
           "the token is missing scopes the skill wants. Re-consent host-side:
        addon-google-workspace.sh auth --force" ;;
    *AUTHENTICATED*)
      pass "a real Google API call succeeds" "setup.py --check-live reached Google" ;;
    *invalid_grant*)
      fail "a real Google API call succeeds" \
           "invalid_grant -- the refresh token is dead. The usual cause is an OAuth
        consent screen left in Testing, which expires tokens after 7 days.
        Publish it, then re-run: addon-google-workspace.sh auth --force" ;;
    *"No route to host"*|*Errno\ 113*)
      fail "a real Google API call succeeds" \
           "no route -- something is not using the proxy. Check PySocks and
        terminal.env_passthrough above, in that order" ;;
    *) fail "a real Google API call succeeds" "$(printf '%s' "$live" | tail -1)" ;;
  esac
fi

# A blocked cron job is the failure that prompted this whole add-on being
# rebuilt: the scheduler refused to run the inbox digest because an
# attached skill was missing its credential files. Assert the condition
# directly rather than inferring it from the files above.
doctor="$(g 'hermes cron doctor 2>&1 | tail -20')"
case "$doctor" in
  "") skip "no cron job is blocked" "could not run hermes cron doctor" ;;
  *blocked_config*|*"is not ready"*|*"missing credential file"*)
    fail "no cron job is blocked" \
         "$(printf '%s' "$doctor" | grep -m1 -E 'blocked_config|is not ready|missing credential file')" ;;
  *) pass "no cron job is blocked" ;;
esac

# ---------------------------------------------------------------------------
section "Base build"

if [ "$DO_BASE" -eq 0 ]; then
  skip "the base system still verifies" "re-run with --base"
else
  BASELOG="$(mktemp -t gw-base-verify.XXXXXX)"
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
  printf '  be in place, correctly scoped, and still dead. Run with --live before\n'
  printf '  reporting this add-on as working.\n'
fi
if [ "$FAIL" -eq 0 ]; then
  printf '\n  Last check is yours: message the Hermes bot and ask it what is on\n'
  printf '  your calendar today. No script can do that one.\n'
fi
exit $(( FAIL > 0 ? 1 : 0 ))
