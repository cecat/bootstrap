#!/usr/bin/env bash
# ===========================================================================
# verify.sh -- prove the sandbox is actually a sandbox and the agents work.
#
#   ./verify/verify.sh              structure, policy and egress (no cost)
#   ./verify/verify.sh --models     + one real completion per agent
#   ./verify/verify.sh --reboot     + reboot and re-check persistence
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
DO_MODELS=0 DO_REBOOT=0
for a in "$@"; do
  case "$a" in
    --models) DO_MODELS=1 ;;
    --reboot) DO_REBOOT=1 ;;
    --all)    DO_MODELS=1; DO_REBOOT=1 ;;
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

phase="$(groot 'cat /etc/agent-sandbox/phase 2>/dev/null' | tr -d '\r')"
case "$phase" in
  runtime)   pass "egress phase" "runtime (steady state)" ;;
  bootstrap) fail "egress phase" "still 'bootstrap' (wide allowlist). Run: limactl shell $VM -- sudo agent-egress runtime" ;;
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

for unit in openclaw-gateway hermes-gateway; do
  active="$(g "systemctl --user is-active $unit.service" | tr -d '\r')"
  enabled="$(g "systemctl --user is-enabled $unit.service" | tr -d '\r')"
  if [ "$active" = "active" ] && [ "$enabled" = "enabled" ]; then
    since="$(g "systemctl --user show -p ActiveEnterTimestamp --value $unit.service" | tr -d '\r')"
    pass "$unit" "active, enabled at boot (since $since)"
  else
    fail "$unit" "active=$active enabled=$enabled"
  fi
done

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

for f in .openclaw/agents/*/SOUL.md .hermes/SOUL.md; do
  found="$(g "ls $f 2>/dev/null | head -1" | tr -d '\r')"
  [ -n "$found" ] && pass "SOUL.md present" "$found" || fail "SOUL.md present" "$f missing -- the agent has no personality seed"
done

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

# ---------------------------------------------------------------------------
section "Model path"

if [ "$DO_MODELS" -eq 0 ]; then
  skip "OpenClaw answers a completion" "re-run with --models (sends a real request; uses your model quota)"
  skip "Hermes answers a completion"   "re-run with --models"
else
  echo "        (these send real requests through your model endpoint)"

  out="$(g "timeout 180 openclaw gateway call cli.chat.one-shot --params '{\"message\":\"Reply with exactly: OC_OK\"}' 2>&1")"
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
    rhe="$(g 'systemctl --user is-active hermes-gateway.service' | tr -d '\r')"
    if [ "$rphase" = "$phase" ] && [ "$rlock" = "active" ] && [ "$roc" = "active" ] && [ "$rhe" = "active" ]; then
      pass "survives a reboot" "phase=$rphase lockdown=$rlock gateways=up"
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
