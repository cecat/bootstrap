#!/usr/bin/env bash
# ===========================================================================
# verify.sh -- prove the sandbox is actually a sandbox and the agents work.
#
#   ./verify/verify.sh              structure, policy and egress (no cost)
#   ./verify/verify.sh --models     + one real completion per agent
#   ./verify/verify.sh --reboot     + reboot and re-check persistence
#   ./verify/verify.sh --idempotence  + re-run Pi's setup.sh, assert no change
#   ./verify/verify.sh --all        everything
#
# Design rules, learned the hard way during the first build:
#
#   * A verification that only checks the allowed path proves nothing. The
#     egress section asserts that a NON-allowed destination is BLOCKED, at
#     both layers, and that the block is scoped to the agent uid.
#   * /health and /v1/models are false greens -- they answer 200 from local
#     state with a dead upstream. Only a completion proves the model path,
#     which is why --models exists and why it is honest about costing quota.
#   * Negative tests must not use a host the network itself blocks. We use
#     example.com over PLAIN HTTP: squid returns a clean 403. Over HTTPS
#     squid denies CONNECT and curl reports 000, which is indistinguishable
#     from the network simply being down.
#
# Nothing here mutates the VM except --reboot. No secret is ever printed.
# ===========================================================================
set -uo pipefail

VM="${AGENTS_VM:-agents}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DO_MODELS=0 DO_REBOOT=0 DO_IDEM=0
for a in "$@"; do
  case "$a" in
    --models) DO_MODELS=1 ;;
    --reboot) DO_REBOOT=1 ;;
    --idempotence) DO_IDEM=1 ;;
    --all)    DO_MODELS=1; DO_REBOOT=1; DO_IDEM=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a (try --help)" >&2; exit 2 ;;
  esac
done

PASS=0; FAIL=0; SKIP=0
if [ -t 1 ]; then R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; B=$'\033[1m'; Z=$'\033[0m'
else R=''; G=''; Y=''; B=''; Z=''; fi

section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$Z"; }
pass() { PASS=$((PASS+1)); printf '  %sPASS%s  %s\n' "$G" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
fail() { FAIL=$((FAIL+1)); printf '  %sFAIL%s  %s\n' "$R" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP+1)); printf '  %sSKIP%s  %s\n' "$Y" "$Z" "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; return 0; }

# Run a command in the guest as the agent user. Everything we check runs
# through a login shell so it sees the same .profile the agents see --
# PATH, the proxy variables and NODE_USE_ENV_PROXY all live there.
g()     { limactl shell "$VM" -- bash -lc "$1" 2>&1; }
groot() { limactl shell "$VM" -- sudo bash -c "$1" 2>&1; }

# ---------------------------------------------------------------------------
section "Host and VM"

if ! command -v limactl >/dev/null 2>&1; then
  fail "limactl on PATH" "install Lima first; see docs/spark-handoff.md on Linux"
  echo; echo "Cannot continue without limactl."; exit 1
fi
pass "limactl on PATH" "$(limactl --version 2>&1 | head -1)"

vm_status="$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null | head -1)"
if [ "$vm_status" = "Running" ]; then
  pass "VM '$VM' is running" "$(limactl list --format '{{.VMType}} {{.Arch}} {{.CPUs}}cpu {{.Memory}}' "$VM" 2>/dev/null | head -1)"
else
  fail "VM '$VM' is running" "status: ${vm_status:-not found}. Start it: limactl start $VM"
  echo; echo "Cannot continue with the VM down."; exit 1
fi

# ---------------------------------------------------------------------------
section "Substrate"

node_major="$(g 'node -p "process.versions.node.split(\".\")[0]" 2>/dev/null' | tr -dc '0-9')"
if [ -n "$node_major" ] && [ "$node_major" -ge 22 ]; then
  pass "Node 22+" "$(g 'node --version')"
else
  fail "Node 22+" "got: ${node_major:-none}"
fi

pi_v="$(g 'pi --version 2>/dev/null' | head -1)"
[ -n "$pi_v" ] && pass "Pi installed" "$pi_v" || fail "Pi installed" "pi not found on PATH"

# The egress lockdown keys off this uid. Lima gives the guest the HOST's uid,
# so an empty file here means provisioning guessed and gave up -- which would
# leave the agents completely unconfined.
au="$(groot 'cat /etc/agent-sandbox/agent-user 2>/dev/null' | tr -d '\r')"
if [ -n "$au" ]; then
  pass "agent user resolved" "$au (uid $(g "id -u $au" | tr -dc '0-9'))"
else
  fail "agent user resolved" "/etc/agent-sandbox/agent-user is empty -- the sandbox is NOT enforced"
fi

if [ -n "$au" ] && [ "$(groot "loginctl show-user $au -p Linger --value" | tr -d '\r')" = "yes" ]; then
  pass "linger enabled" "user services survive logout and reboot"
else
  fail "linger enabled" "gateways will die when the login session ends"
fi

# ---------------------------------------------------------------------------
section "Config (presence and permissions only -- no values read)"

for f in .config/agent-sandbox/agents.env .config/agent-sandbox/model-access.env .pi/agent/models.json; do
  mode="$(g "stat -c '%a' \$HOME/$f 2>/dev/null" | tr -dc '0-7')"
  if [ -z "$mode" ]; then
    fail "$f present"
  elif [ "$mode" = "600" ]; then
    pass "$f present" "mode $mode"
  else
    fail "$f permissions" "mode $mode, expected 600 -- it holds a credential"
  fi
done

# ---------------------------------------------------------------------------
section "Egress policy"

# --idempotence requires the bootstrap allowlist: Pi's setup.sh fetches from
# pypi.org, which runtime does not permit. So a run that asks for it is
# deliberately mid-build and 'bootstrap' is the correct phase -- failing on
# it would make --all unsatisfiable in either phase, which is what used to
# happen. A plain run still fails: a finished build must be on runtime.
phase="$(groot 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -d '\r')"
case "$phase" in
  runtime)   pass "egress phase" "runtime (steady state)" ;;
  bootstrap)
    if [ "$DO_IDEM" -eq 1 ]; then
      pass "egress phase" "bootstrap (wide) -- expected during --idempotence; narrow to runtime when done"
    else
      fail "egress phase" "still 'bootstrap' (wide allowlist). Run: limactl shell $VM -- sudo agent-egress runtime"
    fi
    ;;
  *)         fail "egress phase" "'${phase:-none}' -- no policy has been applied" ;;
esac

st="$(groot 'agent-egress status 2>&1')"
grep -q '^squid: *active'    <<<"$st" && pass "squid running"      || fail "squid running"      "$(grep '^squid:' <<<"$st")"
grep -q '^lockdown: *active' <<<"$st" && pass "iptables lockdown"  || fail "iptables lockdown"  "the uid filter is NOT installed -- egress is unrestricted"

n_allowed="$(groot "grep -cvE '^[[:space:]]*(#|\$)' /etc/agent-sandbox/allowlist.active 2>/dev/null" | tr -dc '0-9')"
if [ -n "$n_allowed" ] && [ "$n_allowed" -gt 0 ]; then
  pass "allowlist non-empty" "$n_allowed domain(s): $(groot "grep -vE '^[[:space:]]*(#|\$)' /etc/agent-sandbox/allowlist.active" | tr -d '\r' | paste -sd' ' -)"
else
  fail "allowlist non-empty" "no active allowlist"
fi

# ---------------------------------------------------------------------------
section "Egress enforcement (the part that actually proves something)"

# 1. Through the proxy, to a destination that is NOT on the allowlist.
#    A 403 is self-validating: it can only come from squid, so it proves at
#    once that squid is reachable AND that it is denying. A connection error
#    would mean squid is down, which is a different failure.
code="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://example.com/ 2>/dev/null')"
case "$code" in
  403) pass "non-allowed domain is DENIED by squid" "http://example.com -> 403" ;;
  200) fail "non-allowed domain is DENIED by squid" "got 200 -- example.com is reachable. The allowlist is not being enforced." ;;
  *)   fail "non-allowed domain is DENIED by squid" "got '${code:-no response}', expected 403. Is squid listening on 127.0.0.1:3128?" ;;
esac

# 2. Around the proxy entirely. The iptables chain should reject this.
#    --reject-with icmp-admin-prohibited makes it fail fast rather than hang,
#    so a timeout here is itself a signal that something else is wrong.
t0=$SECONDS
direct="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --noproxy "*" http://1.1.1.1/ 2>/dev/null')"
dt=$((SECONDS - t0))
if [ "$direct" = "000" ]; then
  pass "direct bypass is BLOCKED by iptables" "http://1.1.1.1 (no proxy) -> no connection, ${dt}s"
else
  fail "direct bypass is BLOCKED by iptables" "got HTTP $direct -- the agent can reach the internet without the proxy"
fi

# 3. Scope check. The same request as root must SUCCEED, because the rule is
#    matched on the agent's uid. If root is blocked too, the rule is wrong
#    even though test 2 passed -- and test 2 would pass just as well if the
#    VM simply had no network at all. This is the control.
rootdirect="$(groot 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --noproxy "*" http://1.1.1.1/ 2>/dev/null')"
if [ "$rootdirect" != "000" ] && [ -n "$rootdirect" ]; then
  pass "lockdown is scoped to the agent uid" "same request as root -> HTTP $rootdirect (the VM does have egress)"
elif [ "$direct" = "000" ]; then
  skip "lockdown is scoped to the agent uid" "root is blocked too (HTTP ${rootdirect:-000}). Either the rule is not uid-scoped, or this host has no route to 1.1.1.1 -- in which case test 2 above proved nothing. Check manually."
else
  fail "lockdown is scoped to the agent uid" "root -> ${rootdirect:-000}"
fi

# 4. Positive control: the model gateway bypasses squid by design, via one
#    narrow ACCEPT rule. It must still be reachable.
gw="$(groot 'cat /etc/agent-sandbox/model-gateway 2>/dev/null' | tr -d '\r')"
if [ -n "$gw" ]; then
  gwcode="$(g "curl -sS -m 15 -o /dev/null -w '%{http_code}' --noproxy '*' http://$gw/health 2>/dev/null")"
  if [ -n "$gwcode" ] && [ "$gwcode" != "000" ]; then
    pass "model gateway reachable" "$gw/health -> $gwcode (NB: a 200 here does not prove the upstream is alive -- see --models)"
  else
    fail "model gateway reachable" "$gw unreachable. Off-site this is an SSH tunnel on the host; check it is still up."
  fi
else
  skip "model gateway reachable" "no /etc/agent-sandbox/model-gateway -- the model path does not cross the host boundary"
fi

# ---------------------------------------------------------------------------
section "Gateways"

active="$(g "systemctl --user is-active openclaw-gateway.service" | tr -d '\r')"
enabled="$(g "systemctl --user is-enabled openclaw-gateway.service" | tr -d '\r')"
if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
  since="$(g "systemctl --user show -p ActiveEnterTimestamp --value openclaw-gateway.service" | tr -d '\r')"
  pass "openclaw-gateway" "active, enabled at boot (since $since)"
else
  fail "openclaw-gateway" "active=$active enabled=$enabled"
fi

# A systemd user service does not read ~/.profile, so the gateway can end up
# with no proxy env -- at which point every allowlisted destination fails
# EHOSTUNREACH while the model path stays green (the model gateway is in
# NO_PROXY and allowed by uid). That combination passes --models and still
# cannot reach a single chat channel, so check the unit directly.
gwproxy="$(g "systemctl --user show openclaw-gateway.service -p Environment --value" | tr ' ' '\n' | grep -c -iE '^(https?_proxy|NODE_USE_ENV_PROXY)=')"
if [ -n "$gwproxy" ] && [ "$gwproxy" -ge 3 ]; then
  pass "gateway has proxy env" "$gwproxy proxy vars in the unit (channels can reach the allowlist)"
else
  fail "gateway has proxy env" "only $gwproxy proxy vars in openclaw-gateway.service -- channels will fail EHOSTUNREACH even though the model path works"
fi

# Hermes' gateway serves messaging channels. If Telegram credentials are in
# ~/.hermes/.env then the gateway must be installed and running -- installing
# it is not the same as enabling a channel, and the build is required to
# prove the path works before a human switches the channel on.
#
# Keyed on .env, not on channel_directory.json: Hermes never writes that
# file, so an earlier version of this check passed unconditionally and hid a
# Hermes that could not reach Telegram at all.
hactive="$(g "systemctl --user is-active hermes-gateway.service" | tr -d '\r')"
if g 'grep -qE "^TELEGRAM_BOT_TOKEN=.+" ~/.hermes/.env' >/dev/null 2>&1; then
  if [ "$hactive" = "active" ]; then
    pass "hermes-gateway" "active (Telegram credentials are configured)"
  else
    fail "hermes-gateway" "Telegram is configured but the gateway is $hactive -- run: hermes gateway install"
  fi

  # A running service is not a working adapter. The plugin ships disabled and
  # its python-telegram-bot dependency comes from pypi.org, which is only
  # allowlisted during bootstrap -- miss either and the service stays active
  # while the journal reports "No adapter available for telegram".
  jr="$(g 'journalctl --user -u hermes-gateway.service --no-pager 2>/dev/null | grep -iE "\[Telegram\] Connected|No adapter available for telegram|adapter creation failed" | tail -1')"
  case "$jr" in
    *"Connected to Telegram"*) pass "Hermes Telegram adapter" "connected (polling)" ;;
    "")                        skip "Hermes Telegram adapter" "no adapter activity in the journal yet" ;;
    *)                         fail "Hermes Telegram adapter" "$(printf '%s' "$jr" | sed 's/.*: //') -- check: hermes plugins enable telegram-platform, and that pypi was reachable when it first started" ;;
  esac
else
  pass "hermes-gateway" "no Telegram credentials in ~/.hermes/.env; gateway not required"
fi

ocport="$(g 'ss -lnt 2>/dev/null | grep -c "127.0.0.1:18789"' | tr -dc '0-9')"
if [ -n "$ocport" ] && [ "$ocport" -ge 1 ]; then
  pass "OpenClaw gateway listening" "127.0.0.1:18789, loopback only (not reachable from the host or LAN)"
else
  fail "OpenClaw gateway listening" "nothing on 127.0.0.1:18789"
fi

if g 'ss -lnt 2>/dev/null' | grep -qE '0\.0\.0\.0:(18789|3128)|\*:(18789|3128)'; then
  fail "no gateway bound to a wildcard address" "a gateway or the proxy is listening on 0.0.0.0 -- it should be loopback only"
else
  pass "no gateway bound to a wildcard address" "only sshd listens beyond loopback"
fi

# No plaintext secrets, and no SecretRef the CLI cannot resolve. Deliberately
# run in a plain login shell: sourcing agents.env first would hide a missing
# export, which is the exact failure this catches. The gateway resolves refs
# from its own EnvironmentFile, so an unresolved ref leaves the service
# healthy and only breaks the CLI -- invisible without this check.
sec="$(g 'openclaw secrets audit --json 2>/dev/null' | tr -d '\r')"
plain="$(printf '%s' "$sec" | jq -r '.summary.plaintextCount // empty' 2>/dev/null)"
unres="$(printf '%s' "$sec" | jq -r '.summary.unresolvedRefCount // empty' 2>/dev/null)"
if [ "$plain" = "0" ] && [ "$unres" = "0" ]; then
  pass "no plaintext or unresolved secrets" "openclaw secrets audit: plaintext=0 unresolved=0"
elif [ -z "$plain" ]; then
  skip "no plaintext or unresolved secrets" "could not parse openclaw secrets audit --json"
else
  fail "no plaintext or unresolved secrets" "plaintext=$plain unresolved=$unres (see: openclaw secrets audit)"
fi

# The agent must carry the name the user chose, and its SOUL.md must be the
# seed rather than a vendor default. Checking only that some SOUL.md exists
# passes a build where `openclaw onboard` left the agent called "main", the
# seed landed in an unused agents/<other>/ directory, and Hermes kept the
# stock Nous persona -- all three happened on one run.
want_oc="$(g 'set -a; . $HOME/.config/agent-sandbox/agents.env 2>/dev/null; set +a; printf %s "$OPENCLAW_AGENT_NAME"' | tr -d '\r')"
want_he="$(g 'set -a; . $HOME/.config/agent-sandbox/agents.env 2>/dev/null; set +a; printf %s "$HERMES_AGENT_NAME"' | tr -d '\r')"

# Assert the *identity*, not the directory. OpenClaw separates an immutable
# agent id (`main`, set by onboard -- `openclaw agents` offers add/delete/
# set-identity but no rename) from the display identity, which is what
# `set-identity` changes and what the user actually sees. An earlier version
# of this check demanded the directory be named LuoJi, which OpenClaw cannot
# do, and so failed a correct build.
agents_out="$(g 'openclaw agents list 2>/dev/null')"
live_identity="$(printf '%s' "$agents_out" | grep -m1 'Identity:' | sed 's/.*Identity: *//; s/ *(.*//' | tr -d '\r')"
if [ -n "$want_oc" ] && [ -n "$live_identity" ]; then
  if [ "$live_identity" = "$want_oc" ]; then
    pass "OpenClaw agent identity is as configured" "$live_identity"
  else
    fail "OpenClaw agent identity is as configured" "identity is '$live_identity', expected '$want_oc' -- OPENCLAW_AGENT_NAME was not applied"
  fi
else
  skip "OpenClaw agent identity is as configured" "could not read the configured name or the live identity"
fi

# `Agent dir:` reports the *agent state* directory and carries a trailing
# /agent -- SOUL.md sits one level above it. It may also be printed with a
# literal ~, which no shell expands when it arrives as data.
live_dir="$(printf '%s' "$agents_out" | grep -m1 'Agent dir:' | sed 's/.*Agent dir: *//; s#/agent/*$##' | tr -d '\r')"
case "$live_dir" in "~"*) live_dir="\$HOME${live_dir#\~}" ;; esac

check_soul() {
  local label="$1" path="$2" want="$3"
  local body; body="$(g "cat $path 2>/dev/null" | tr -d '\r')"
  if [ -z "$body" ]; then
    fail "$label SOUL.md" "$path missing or empty -- the agent has no personality"
  elif [ -n "$want" ] && ! printf '%s' "$body" | grep -qi "$want"; then
    fail "$label SOUL.md" "$path does not mention '$want' -- looks like a vendor default, not the seed"
  else
    pass "$label SOUL.md" "present and names $want"
  fi
}
[ -n "$live_dir" ] && check_soul "OpenClaw" "$live_dir/SOUL.md" "$want_oc"
check_soul "Hermes" '$HOME/.hermes/SOUL.md' "$want_he"

# ---------------------------------------------------------------------------
section "Channels are off"

# Safety assertion, not a feature test. AGENTS.md forbids enabling any chat
# channel before this suite passes, so finding one enabled here is a failure
# regardless of whether it works.
oc_ch="$(g 'jq -r "(.channels // {}) | to_entries | map(select(.value.enabled != false)) | length" ~/.openclaw/openclaw.json 2>/dev/null' | tr -dc '0-9')"
if [ "${oc_ch:-0}" = "0" ]; then
  pass "OpenClaw has no channel enabled" "no Telegram or other channel is live"
else
  fail "OpenClaw has no channel enabled" "$oc_ch channel(s) enabled -- AGENTS.md Step 9 says a channel must not be on before verification passes"
fi

if g 'ls ~/.hermes/channel_directory.json' >/dev/null 2>&1; then
  he_ch="$(g 'jq -r "[.. | objects | select(.enabled == true)] | length" ~/.hermes/channel_directory.json 2>/dev/null' | tr -dc '0-9')"
  if [ "${he_ch:-0}" = "0" ]; then
    pass "Hermes has no channel enabled" "channel directory lists none enabled"
  else
    fail "Hermes has no channel enabled" "$he_ch enabled"
  fi
else
  pass "Hermes has no channel enabled" "no channel directory"
fi

# Both checks above read CONFIG. Config cannot distinguish "disabled" from
# "disabled in the file, but a gateway already opened a long-poll and is
# answering anyway" -- and the 2026-10-28 build reported Hermes' adapter as
# "connected and polling" while its channel was nominally off. Ask Telegram
# instead: it permits exactly one getUpdates consumer per bot, so a 409
# Conflict means something is holding the poll open and the bot is live.
#
# Run from the HOST, not the guest: the question is whether the bot is being
# polled at all, by anything, which is a fact about Telegram's side.
if [ -f "$REPO_DIR/config/agents.env" ]; then
  # Capture the status on the same line as the call: a bare `$?` after an
  # assignment reports the assignment's status, which is always 0, and the
  # check could never fail.
  poll_rc=0
  poll_out="$("$REPO_DIR/scripts/check-telegram-polling.sh" 2>&1)" || poll_rc=$?
  if [ "$poll_rc" -eq 0 ]; then
    pass "no Telegram bot is being polled" "$(grep -c 'idle' <<<"$poll_out") bot(s) idle; nothing would answer a message"
  else
    fail "no Telegram bot is being polled" \
         "$(grep -E 'POLLING|rejected|UNREACHABLE' <<<"$poll_out" | sed 's/^ *//' | paste -sd' | ' -)"
  fi
else
  skip "no Telegram bot is being polled" "config/agents.env not present"
fi

# ---------------------------------------------------------------------------
section "Idempotence of Pi's setup.sh"

# The spec makes setup.sh the deliverable and requires a second run to change
# nothing. Pi self-reports this, and has been wrong: a guard grepping
# multi-line JSON with a single-line pattern never matches, so its step runs
# every time while still looking guarded. Opt-in because it re-runs the
# script against a live VM.
if [ "$DO_IDEM" -eq 0 ]; then
  skip "setup.sh is idempotent" "re-run with --idempotence (re-runs Pi's script against this VM)"
else
  if ! g 'test -x ~/agent-bootstrap/setup.sh' >/dev/null 2>&1; then
    skip "setup.sh is idempotent" "~/agent-bootstrap/setup.sh not found"
  elif [ "$phase" != "bootstrap" ]; then
    skip "setup.sh is idempotent" "needs the bootstrap allowlist; currently '$phase'"
  else
    idem="$(g 'cd ~/agent-bootstrap && ./setup.sh 2>&1')"
    # Count announced actions that are NOT immediately retracted by an
    # "already ..." line. Two refinements, both learned from false positives:
    # anchor on the script's own [HH:MM:SS] prefix, because installer banners
    # are full of prose and box-drawing characters; and drop any announcement
    # whose very next line reports the work was skipped, because a function
    # that logs "Installing X..." before testing for X is noisy, not
    # non-idempotent. What matters is whether state changed.
    changed="$(printf '%s' "$idem" | awk '
      /^\[[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\] +(Creating|Setting|Installing|Migrating|Writing|Enabling|Adding) / { pending++; last=NR; next }
      /already|up to date|unchanged|Skipping|skip/ { if (last == NR-1 && pending) pending-- }
      END { print pending+0 }')"
    if [ "${changed:-0}" = "0" ]; then
      pass "setup.sh is idempotent" "second run reported no changes"
    else
      fail "setup.sh is idempotent" "$changed step(s) acted on a second run -- look for a guard that never matches: $(printf '%s' "$idem" | grep -E '^\[[0-9]{2}:[0-9]{2}:[0-9]{2}\] +(Creating|Setting|Installing|Migrating|Writing|Enabling|Adding) ' | head -3 | sed 's/^\[[0-9:]*\] *//' | paste -sd' | ' -)"
    fi
  fi
fi

# ---------------------------------------------------------------------------
section "Model path"

# The VM-facing gateway address used to be hardcoded to Lima's macOS value
# and carried onto Linux unverified. It happened to be right -- Lima uses the
# same user-mode subnet under QEMU slirp -- but nothing checked, and when a
# build later failed for an unrelated reason the address was the first thing
# blamed, costing a session. These two checks cost nothing and settle it.
gw="$(groot 'cat /etc/agent-sandbox/model-gateway 2>/dev/null' | tr -d '\r')"
if [ -z "$gw" ]; then
  skip "VM gateway address is the guest's real default route" "no model-gateway configured"
else
  gw_host="${gw%%:*}"
  guest_gw="$(g 'ip route show default 2>/dev/null' | sed -nE 's/^default via ([0-9.]+).*/\1/p' | head -1)"
  if [ "$gw_host" = "$guest_gw" ]; then
    pass "VM gateway address matches the guest's default route" "$gw_host"
  else
    fail "VM gateway address matches the guest's default route" \
         "configured $gw_host, guest routes via ${guest_gw:-unknown} -- the VM cannot reach the host"
  fi

  # Streaming specifically: Pi, OpenClaw and Hermes all stream, and a
  # non-streaming check passes on a path whose SSE is broken.
  sse="$(g "curl -sN --noproxy '*' --max-time 60 -X POST http://$gw/v1/messages \
           -H 'content-type: application/json' \
           -d '{\"model\":\"argo:claude-4.5-sonnet\",\"max_tokens\":16,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: SSE_OK\"}]}' 2>&1")"
  # Reassemble the text_delta fragments before looking for the marker: a
  # stream splits "SSE_OK" across deltas ("SS" + "E_OK"), so grepping the
  # raw SSE for it never matches. This check failed on a working gateway
  # until that was fixed -- the same "assert against what output looks like
  # rather than what the system does" mistake this file warns about.
  sse_text="$(grep -o '"text": *"[^"]*"' <<<"$sse" | sed 's/.*: *"//; s/"$//' | tr -d '\n')"
  if [ "$sse_text" = "SSE_OK" ] && grep -q message_stop <<<"$sse"; then
    pass "gateway streams to the guest" "SSE completed through $gw"
  else
    fail "gateway streams to the guest" \
         "no complete SSE stream from $gw -- agents will die mid-request: $(tr -d '\r' <<<"$sse" | grep -viE 'key|token|secret' | tail -2 | paste -sd' | ' -)"
  fi
fi

if [ "$DO_MODELS" -eq 0 ]; then
  skip "OpenClaw answers a completion" "re-run with --models (sends a real request; uses your model quota)"
  skip "Hermes answers a completion"   "re-run with --models"
else
  echo "        (these send real requests through your model endpoint)"

  # `openclaw agent --message` is the one-shot path. The older
  # `gateway call cli.chat.one-shot` method was removed in OpenClaw 2026.10.5
  # and now answers "unknown method", which reads as a dead model path.
  ocid="$(g 'openclaw config get models.providers.argo-gateway.models 2>/dev/null | jq -r ".[0].id // empty" 2>/dev/null' | tr -dc 'a-zA-Z0-9.:_-')"
  ocmodel="argo-gateway/${ocid:-claude-sonnet-5}"
  out="$(g "timeout 180 openclaw agent --model '$ocmodel' --message 'Reply with exactly: OC_OK' 2>&1")"
  if grep -q 'OC_OK' <<<"$out"; then
    pass "OpenClaw answers a completion" "model path verified end to end"
  else
    fail "OpenClaw answers a completion" "$(tr -d '\r' <<<"$out" | grep -viE 'key|token|secret' | tail -3 | paste -sd' | ' -)"
  fi

  out="$(g "timeout 180 hermes -z 'Reply with exactly: TRAV_OK' 2>&1")"
  if grep -q 'TRAV_OK' <<<"$out"; then
    pass "Hermes answers a completion" "model path verified end to end"
  else
    fail "Hermes answers a completion" "$(tr -d '\r' <<<"$out" | grep -viE 'key|token|secret' | tail -3 | paste -sd' | ' -)"
  fi
fi

# ---------------------------------------------------------------------------
section "Persistence across reboot"

if [ "$DO_REBOOT" -eq 0 ]; then
  skip "survives a reboot" "re-run with --reboot (takes a couple of minutes)"
else
  echo "        rebooting $VM ..."
  limactl stop "$VM" >/dev/null 2>&1
  if ! limactl start "$VM" >/dev/null 2>&1; then
    fail "survives a reboot" "the VM did not come back up"
  else
    for _ in $(seq 1 30); do g 'true' >/dev/null 2>&1 && break; sleep 5; done
    rphase="$(groot 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -d '\r')"
    rlock="$(groot 'agent-egress status 2>&1' | grep '^lockdown:' | awk '{print $2}')"
    roc="$(g 'systemctl --user is-active openclaw-gateway.service' | tr -d '\r')"
    # Same reasoning as the Gateways section: only require hermes-gateway back
    # if a channel is configured, since otherwise it is never installed.
    if g 'ls ~/.hermes/channel_directory.json' >/dev/null 2>&1; then
      rhe="$(g 'systemctl --user is-active hermes-gateway.service' | tr -d '\r')"
    else
      rhe="n/a"
    fi
    if [ "$rphase" = "$phase" ] && [ "$rlock" = "active" ] && [ "$roc" = "active" ] \
       && { [ "$rhe" = "active" ] || [ "$rhe" = "n/a" ]; }; then
      pass "survives a reboot" "phase=$rphase lockdown=$rlock openclaw=up hermes=$rhe"
    else
      fail "survives a reboot" "phase=$rphase lockdown=$rlock openclaw=$roc hermes=$rhe"
    fi
    # iptables rules are not persistent on their own; agent-egress.service
    # re-applies them. A reboot that comes back unlocked is the worst case,
    # because everything else still looks healthy.
    rcode="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://example.com/ 2>/dev/null')"
    [ "$rcode" = "403" ] && pass "egress still enforced after reboot" "example.com -> 403" \
                         || fail "egress still enforced after reboot" "example.com -> ${rcode:-000}, expected 403"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%s== Summary ==%s\n' "$B" "$Z"
printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$SKIP" "$Z"
if [ "$FAIL" -eq 0 ] && [ "$DO_MODELS" -eq 0 ]; then
  printf '\n  Structure and egress look right, but NO COMPLETION WAS MADE.\n'
  printf '  A gateway can be up and still have a dead model path. Run with\n'
  printf '  --models before reporting this build as working.\n'
fi
[ "$FAIL" -eq 0 ] || printf '\n  %sVerification failed.%s Do not enable a chat channel.\n' "$R" "$Z"
exit $(( FAIL > 0 ? 1 : 0 ))
