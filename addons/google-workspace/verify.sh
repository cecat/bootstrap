#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Evidence for the Google Workspace add-on.
#
#   ./scripts/addon-google-workspace.sh verify [instance]
#
# Same contract as verify/verify.sh: asserts the limits hold, not just that
# the happy path works. Pi's summary is a claim; this is the measurement.
#
#   --live   also make a real Google API call (reads one label; writes
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

# The spec says "create ~/.local/share/agent-sandbox/google-mcp/ and make
# a venv there", which reads two ways: the venv AT that path, or inside
# it. Pi chose the first and was not wrong. Accept either rather than
# failing a sound build on a layout detail -- what matters is that the
# venv is under the add-on's own directory, not Hermes'.
GMCP='$HOME/.local/share/agent-sandbox/google-mcp'
if g "test -x $GMCP/bin/python" >/dev/null 2>&1; then
  VENV="$GMCP"
else
  VENV="$GMCP/venv"
fi

# ---------------------------------------------------------------------------
section "Credentials stay secret"

if [ -f config/google.env ]; then
  mode="$(stat -c '%a' config/google.env 2>/dev/null || stat -f '%Lp' config/google.env 2>/dev/null)"
  [ "$mode" = "600" ] && pass "config/google.env is 0600" \
                      || fail "config/google.env is 0600" "mode $mode"
  if git check-ignore -q config/google.env; then
    pass "config/google.env is invisible to git"
  else
    fail "config/google.env is invisible to git" "it would be committed -- fix .gitignore and rotate the token"
  fi
else
  skip "config/google.env is 0600" "no host credentials file"
fi

# Anything under config/ that is not an example must stay out of git. The
# base preflight checks this too; repeated here because this add-on is what
# adds a new file there.
exposed="$( { git ls-files -- config/
              git status --porcelain -uall -- config/ | cut -c4-
            } 2>/dev/null | sort -u | grep -vE '\.example$|^config/README\.md$' || true)"
[ -z "$exposed" ] && pass "nothing under config/ is visible to git" \
                  || fail "nothing under config/ is visible to git" "$(printf '%s' "$exposed" | tr '\n' ' ')"

mode="$(g 'stat -c %a "$HOME/.config/agent-sandbox/google.env" 2>/dev/null' | tr -dc '0-7')"
[ "$mode" = "600" ] && pass "VM credentials file is 0600" \
                    || fail "VM credentials file is 0600" "mode ${mode:-missing}"

# The credential store holds the refresh token in the clear, as the server
# requires. Its directory and files are the only thing guarding it.
dmode="$(g 'stat -c %a "$HOME/.config/agent-sandbox/google-creds" 2>/dev/null' | tr -dc '0-7')"
[ "$dmode" = "700" ] && pass "credential store directory is 0700" \
                     || fail "credential store directory is 0700" "mode ${dmode:-missing}"

loose="$(g 'find "$HOME/.config/agent-sandbox/google-creds" -type f ! -perm 600 2>/dev/null | tr "\n" " "')"
if ! g 'test -d $HOME/.config/agent-sandbox/google-creds' >/dev/null 2>&1; then
  skip "every credential file is 0600" "no credential store yet"
else
  [ -z "$(printf '%s' "$loose" | tr -d '[:space:]')" ] \
    && pass "every credential file is 0600" \
    || fail "every credential file is 0600" "too permissive: $loose"
fi

# A refresh token in any file but the sanctioned one is a copy nobody
# decided to make. This is the shape of check the base suite already runs
# for Telegram bot tokens, for the same reason.
if ! g 'test -f $HOME/.config/agent-sandbox/google.env' >/dev/null 2>&1; then
  skip "the refresh token lives in one file only" "no credentials installed in the VM yet"
else
  # The credential store file is a sanctioned second copy -- the server
  # reads the token from there, by design -- so it is excluded alongside
  # google.env. node_modules and lock files are excluded because "1//"
  # followed by base64-ish characters occurs in minified JS and integrity
  # hashes; matching those was a false alarm, not a leak.
  dup="$(g 'grep -rlE "1//[A-Za-z0-9_-]{20,}" $HOME/.config/agent-sandbox/ $HOME/.hermes/ $HOME/.openclaw/ 2>/dev/null | grep -vE "/agent-sandbox/google.env$|/agent-sandbox/google-creds/|/node_modules/|package-lock\.json$" | tr "\n" " "')"
  [ -z "$(printf '%s' "$dup" | tr -d '[:space:]')" ] \
    && pass "the refresh token lives in one file only" \
    || fail "the refresh token lives in one file only" "also in: $dup"
fi

# ---------------------------------------------------------------------------
section "Server installed"

g "test -x $VENV/bin/python" >/dev/null 2>&1 \
  && pass "add-on venv exists" "~/.local/share/agent-sandbox/google-mcp/venv" \
  || fail "add-on venv exists" "no python at $VENV/bin/python"

# The pin is the safety story: every claim below is about one reviewed
# version's tool surface. An unnoticed upgrade could widen it.
WANT_VERSION="$(sed -n 's/^workspace-mcp==//p' "$ADDON/requirements.txt" | tr -d '[:space:]')"
got="$(g "$VENV/bin/pip show workspace-mcp 2>/dev/null | sed -n 's/^Version: //p'" | tr -d '[:space:]')"
if [ -z "$got" ]; then
  fail "workspace-mcp is installed at the pinned version" "not installed in the add-on venv"
elif [ "$got" = "$WANT_VERSION" ]; then
  pass "workspace-mcp is installed at the pinned version" "$got"
else
  fail "workspace-mcp is installed at the pinned version" \
       "found $got, pinned $WANT_VERSION -- the tool-surface claims below were reviewed against the pin"
fi

# Its own venv, not Hermes'. The point of the separation is that removing
# this add-on cannot disturb the base build.
hv="$(g 'command -v hermes >/dev/null && readlink -f "$(command -v hermes)" 2>/dev/null')"
case "$hv" in
  "") skip "Hermes is not running out of the add-on venv" "could not locate the hermes binary -- nothing was checked" ;;
  *"/agent-sandbox/google-mcp/"*) fail "Hermes is not running out of the add-on venv" "$hv" ;;
  *) pass "Hermes is not running out of the add-on venv" "$hv" ;;
esac

# ---------------------------------------------------------------------------
section "Tool surface"

# Ask the server what it registers, with the same arguments the Hermes
# config uses. Re-derived from the running server rather than read from
# upstream docs: the restrictions below are the whole point of the add-on,
# and a release that added a delete tool must fail here, loudly.
#
# No credentials are needed to enumerate tools, and none are supplied --
# g() folds stderr into stdout, so a command that loads the token is a
# command whose output lands in this log.
TOOLS="$(g "cd \$HOME/.local/share/agent-sandbox/google-mcp 2>/dev/null && $VENV/bin/python -c '
import asyncio
from core.server import server
import gmail.gmail_tools, gdrive.drive_tools, gcalendar.calendar_tools, gforms.forms_tools
print(\"TOOLS:\" + \" \".join(sorted(t.name for t in asyncio.run(server.list_tools()))))
' 2>/dev/null | sed -n 's/^TOOLS://p' | tail -1")"

# A marker prefix, not just non-empty output: an SSH warning or a partial
# traceback would otherwise arrive here looking like a tool list, and the
# negative assertions below would then pass against garbage.
case " $TOOLS " in
  *" search_gmail_messages "*)
    n="$(printf '%s' "$TOOLS" | wc -w | tr -d ' ')"
    pass "MCP server lists its tools" "$n tools" ;;
  *)
    fail "MCP server lists its tools" "no usable tool list: ${TOOLS:-no output}"
    TOOLS="" ;;
esac

# Names are upstream's, and they change between releases -- which is what
# the version pin above is defending. If these start failing after a bump,
# read the changelog before editing the list.
for t in search_gmail_messages get_gmail_message_content send_gmail_message \
         draft_gmail_message modify_gmail_message_labels list_gmail_labels \
         get_events manage_event list_calendars \
         search_drive_files get_drive_file_content create_drive_file update_drive_file \
         create_form get_form list_form_responses; do
  case " $TOOLS " in
    *" $t "*) ;;
    *) fail "tool present: $t" "not registered"; continue ;;
  esac
  pass "tool present: $t"
done

# Everything above asks the SERVER what it registers, by running it
# directly. That passed 40 checks on 2026-11-06 while Hermes had parked
# the server after a bad path and the agent had no Google tools at all --
# the user found out by asking it, which is the one thing no script was
# doing. So ask the gateway what it actually holds.
# httplib2 proxies only when PySocks is importable: its isgood() is
# `return socks and ...`, so without it the Google client connects
# DIRECT and dies at the uid lockdown with Errno 113 -- while every
# proxy variable reads correctly and squid stays silent, because the
# request never arrives. Assert the condition, not the symptom.
pysocks="$(g "$VENV/bin/python -c 'import httplib2; print(\"SOCKS_OK\" if httplib2.socks else \"SOCKS_MISSING\")' 2>/dev/null | tail -1")"
case "$pysocks" in
  *SOCKS_OK*)      pass "httplib2 can actually use the proxy" "PySocks present, so isgood() is true" ;;
  *SOCKS_MISSING*) fail "httplib2 can actually use the proxy" \
                        "PySocks is missing, so httplib2 silently ignores the proxy and every Google call fails with Errno 113" ;;
  *)               skip "httplib2 can actually use the proxy" "could not import httplib2 in the add-on venv" ;;
esac

section "Hermes can actually see the tools"

park="$(g 'journalctl --user -u hermes-gateway.service --since "-24h" --no-pager 2>/dev/null | grep -icE "google-workspace.*(parked|permanent error|missing executable)"' | tr -dc '0-9')"
livetools="$(g 'hermes tools list 2>/dev/null | grep -ci "google_workspace\|google-workspace"' | tr -dc '0-9')"

if [ "${livetools:-0}" -gt 0 ]; then
  pass "the gateway lists the Google tools" "$livetools entries in hermes tools list"
elif [ "${park:-0}" -gt 0 ]; then
  fail "the gateway lists the Google tools" \
       "the MCP server is PARKED -- Hermes hit a permanent error (usually a wrong
        command path) and does not retry. The agent has no Google tools however
        healthy the server looks when run by hand. Fix the path, then restart:
        systemctl --user restart hermes-gateway.service"
else
  fail "the gateway lists the Google tools" \
       "hermes tools list shows none -- the agent cannot call them, whatever the server reports"
fi

# A parked server is invisible to every other check here, so say so even
# when the tools did show up: a park earlier in the same session means
# the gateway needed a restart to recover, which is worth knowing.
if [ "${park:-0}" -gt 0 ] && [ "${livetools:-0}" -gt 0 ]; then
  printf '        %s(the journal shows an earlier park; it recovered)%s\n' "$Y" "$Z"
fi

# The whole Drive promise in one assertion. If a later edit adds a delete
# tool back, this is what catches it.
#
# Both of these SKIP rather than pass when no tool list could be read. "No
# delete tool was found" is trivially true of a server that is not running,
# and a green line saying the central limit holds -- on the strength of
# having measured nothing -- is the exact failure this repo keeps hitting.
if [ -z "$TOOLS" ]; then
  skip "Drive has NO delete or trash tool" "no tool list to check -- not a pass"
  skip "Gmail has no permanent-delete tool" "no tool list to check -- not a pass"
else
  # Upstream names tools verb-first (delete_drive_file, not drive_delete),
  # so match the verb anywhere in a name mentioning the service.
  bad=""
  for t in $TOOLS; do
    case "$t" in
      *delete*drive*|*drive*delete*|*trash*drive*|*drive*trash*|\
      *delete*file*|*trash*file*|*remove*file*) bad="$bad $t" ;;
    esac
  done
  [ -z "$bad" ] && pass "Drive has NO delete or trash tool" "the add-on's central limit" \
                || fail "Drive has NO delete or trash tool" "found:$bad"

  bad=""
  for t in $TOOLS; do
    case "$t" in
      *delete*gmail*|*gmail*delete*|*delete*message*|*purge*|*empty*trash*) bad="$bad $t" ;;
    esac
  done
  [ -z "$bad" ] && pass "Gmail has no permanent-delete tool" "trash only, recoverable for 30 days" \
                || fail "Gmail has no permanent-delete tool" "found:$bad"
fi

# ---------------------------------------------------------------------------
section "Scopes"

# gmail.modify is what makes "cannot permanently delete" Google's rule
# rather than ours; https://mail.google.com/ would silently undo that.
# Check the token we actually hold, not what we meant to ask for.
SCOPES="$(g 'python3 -c "
import json, glob
for p in glob.glob(__import__(\"os\").path.expanduser(\"~/.config/agent-sandbox/google-creds/*.json\")):
    print(\"SCOPES:\" + \" \".join(json.load(open(p)).get(\"scopes\") or []))
    break
" 2>/dev/null | sed -n "s/^SCOPES://p" | tail -1')"

if [ -z "$(printf '%s' "$SCOPES" | tr -d '[:space:]')" ]; then
  skip "the granted Gmail scope is gmail.modify" "no credential file to read -- nothing was checked"
else
  case " $SCOPES " in
    *"https://mail.google.com/"*)
      fail "the granted Gmail scope is gmail.modify" \
           "full-mailbox scope granted -- permanent deletion would be possible" ;;
    *"gmail.modify"*)
      pass "the granted Gmail scope is gmail.modify" "Google refuses permanent deletion under it" ;;
    *)
      fail "the granted Gmail scope is gmail.modify" "unexpected scopes: $SCOPES" ;;
  esac
fi

# The upstream package must not be able to ask for more than we granted.
pkg_full="$(g "$VENV/bin/python -c 'import auth.scopes as s; print(\"MAILFULL\" if any(\"mail.google.com\" in x for x in dir(s) + [getattr(s, n) for n in dir(s) if n.endswith(\"_SCOPE\")]) else \"OK\")' 2>/dev/null | tail -1")"
case "$pkg_full" in
  *OK*)       pass "the installed server defines no full-mailbox scope" "gmail.modify is its ceiling" ;;
  *MAILFULL*) fail "the installed server defines no full-mailbox scope" "it can request https://mail.google.com/" ;;
  *)          skip "the installed server defines no full-mailbox scope" "could not read auth.scopes" ;;
esac

# ---------------------------------------------------------------------------
section "Wired into Hermes, and only Hermes"

# Read the config FILE, not `hermes config show` -- that prints a
# formatted summary (paths, API keys, models) which never mentions
# mcp_servers, so checking its output failed against a config that was
# perfectly correct. gotchas.md: assert what the system does, not what
# the output looks like.
cfg="$(g 'cat ~/.hermes/config.yaml 2>/dev/null')"
case "$cfg" in
  *google*workspace*|*google-workspace*|*google_workspace*)
    pass "Hermes config references the google-workspace server" ;;
  *)
    fail "Hermes config references the google-workspace server" \
         "no mcp_servers entry found in hermes config show" ;;
esac

# The MCP stdio client hands a child only HOME, LOGNAME, PATH, SHELL,
# TERM and USER, plus whatever the server's own env: block names. So the
# proxy cannot be inherited from the gateway however it is exported, and
# without it every Google call dies at the uid lockdown with "No route to
# host". Costing: one 17-minute Pi turn, 56 retries, and a confident
# wrong diagnosis blaming httplib2.
case "$cfg" in
  *proxy*) pass "the MCP server is given a proxy" "proxy named in the server config" ;;
  "")      skip "the MCP server is given a proxy" "could not read hermes config" ;;
  *)       fail "the MCP server is given a proxy" \
                "no http_proxy/https_proxy in the mcp_servers env block -- the server inherits none, so Google calls will fail with 'No route to host'" ;;
esac

# The credentials have to reach a *user* systemd service, which does not
# read ~/.profile. A drop-in is the only thing that gets them there.
drop="$(g 'cat $HOME/.config/systemd/user/hermes-gateway.service.d/*.conf 2>/dev/null')"
case "$drop" in
  *"agent-sandbox/google.env"*)
    pass "gateway drop-in supplies the credentials" "EnvironmentFile present" ;;
  *)
    fail "gateway drop-in supplies the credentials" \
         "no EnvironmentFile for google.env -- the server will start and then fail every call" ;;
esac

# systemd.exec(5): "Variable expansion is not performed" in Environment=.
# So Environment=FOO=${BAR} sets FOO to the literal seven characters
# "${BAR}". It looks plausible in systemctl show and fails only on a real
# Google call, as invalid_client. Pi wrote exactly this on 2026-11-06.
case "$drop" in
  *'Environment='*'${'*)
    fail "no unexpanded \${...} in the drop-in" \
         "systemd does not expand variables in Environment= -- the service gets the literal text" ;;
  *)
    pass "no unexpanded \${...} in the drop-in" ;;
esac

# What the service really has, as opposed to what the unit files say.
svcenv="$(g 'systemctl --user show hermes-gateway.service --property=Environment --value 2>/dev/null')"
case "$svcenv" in
  *'${'*)
    fail "gateway environment holds real values" "an unexpanded \${...} reached the service" ;;
  *GOOGLE_OAUTH_CLIENT_ID=*)
    pass "gateway environment holds real values" "GOOGLE_OAUTH_CLIENT_ID is set and expanded" ;;
  "")
    skip "gateway environment holds real values" "could not read the unit environment" ;;
  *)
    # EnvironmentFile contents do not show up in this property, so absence
    # here is not a failure on its own -- the live call settles it.
    skip "gateway environment holds real values" "not visible in Environment=; --live is the real test" ;;
esac

# A token in a config file is a token in a backup. Only meaningful once
# ~/.hermes exists -- grepping a directory that is not there finds nothing
# and would otherwise read as a clean bill of health.
if ! g 'test -d $HOME/.hermes' >/dev/null 2>&1; then
  skip "no credential written into Hermes config" "~/.hermes does not exist -- nothing was checked"
else
  leak="$(g 'grep -rlE "GOOGLE_(CLIENT_SECRET|REFRESH_TOKEN)=.?[A-Za-z0-9/_-]{10,}" $HOME/.hermes/ 2>/dev/null | tr "\n" " "')"
  [ -z "$(printf '%s' "$leak" | tr -d '[:space:]')" ] \
    && pass "no credential written into Hermes config" \
    || fail "no credential written into Hermes config" "found in: $leak"
fi

# This add-on is for one agent. OpenClaw getting Google tools would be a
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
else
  # Reads one label. Writes nothing, sends nothing, deletes nothing.
  # Goes through the server's own credential store, so this exercises the
  # exact path the agent uses -- including the refresh the store performs.
  # Give it the same proxy the mcp_servers env: block gives the real
  # server. Without it this test fails with "No route to host" at the uid
  # lockdown whatever the server config says -- which looked like the
  # add-on being broken when it was the harness.
  live="$(g "cd \$HOME/.local/share/agent-sandbox/google-mcp 2>/dev/null && http_proxy=http://127.0.0.1:3128 https_proxy=http://127.0.0.1:3128 WORKSPACE_MCP_CREDENTIALS_DIR=\$HOME/.config/agent-sandbox/google-creds $VENV/bin/python -c '
import os
from auth.credential_store import LocalDirectoryCredentialStore
from googleapiclient.discovery import build
store = LocalDirectoryCredentialStore(base_dir=os.environ[\"WORKSPACE_MCP_CREDENTIALS_DIR\"])
users = store.list_users()
creds = store.get_credential(users[0])
svc = build(\"gmail\", \"v1\", credentials=creds, cache_discovery=False)
print(\"LIVE_OK\", len(svc.users().labels().list(userId=\"me\").execute().get(\"labels\", [])))
' 2>&1 | tail -3")"
  case "$live" in
    *LIVE_OK*) pass "a real Google API call succeeds" "$(printf '%s' "$live" | grep -o 'LIVE_OK [0-9]*' | sed 's/LIVE_OK /Gmail labels read: /')" ;;
    *invalid_grant*)
      fail "a real Google API call succeeds" \
           "invalid_grant -- the refresh token is dead. The usual cause is an OAuth
        consent screen left in Testing, which expires tokens after 7 days.
        Publish it, then re-run: addon-google-workspace.sh auth --force" ;;
    *) fail "a real Google API call succeeds" "$(printf '%s' "$live" | tail -1)" ;;
  esac
fi

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
  printf '\n  The wiring looks right, but NO GOOGLE CALL WAS MADE. A server can\n'
  printf '  start, register every tool, and still hold a dead token. Run with\n'
  printf '  --live before reporting this add-on as working.\n'
fi
if [ "$FAIL" -eq 0 ]; then
  printf '\n  Last check is yours: message the Hermes bot and ask it what is on\n'
  printf '  your calendar today. No script can do that one.\n'
fi
exit $(( FAIL > 0 ? 1 : 0 ))
