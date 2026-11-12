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
# Rules for anything added here:
#
#   * Assert the negative. A check that only exercises the allowed path
#     proves nothing about the boundary. The boundary here is the private
#     network, not the internet: agents are meant to browse the web.
#   * Only a completion proves the model path. /health and /v1/models
#     answer 200 from local state with a dead upstream.
#   * Negative egress tests use PLAIN HTTP. Over HTTPS a refusal reports
#     curl 000, indistinguishable from the network being down.
#   * Assert what the system does, not what its output looks like. Several
#     checks here have failed correct builds by matching on wording.
#
# Nothing mutates the VM except --reboot. No secret is ever printed.
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

# The egress lockdown keys off this uid, so an empty file here means the
# agents are unconfined. Do not infer the uid from a range: Lima gives the
# guest the host's uid, which on macOS is 502.
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

# Pi's own provider is the supervision channel -- pi-session.sh passes
# `--provider argo`, so if that id stops resolving there is no way left to
# ask Pi to repair anything. Pi has renamed it before.
#
# Accept either shape and report which: providers is normally an object
# keyed by id, but a rewrite can turn it into an array of objects, and an
# array counted as an object reads as empty.
pi_shape="$(g 'jq -r ".providers | type" $HOME/.pi/agent/models.json 2>/dev/null' | tr -d '\r')"
pi_prov="$(g 'jq -r "[(.providers // empty) | if type == \"object\" then keys[] else .[].id // empty end] | join(\",\")" $HOME/.pi/agent/models.json 2>/dev/null' | tr -d '\r')"
case ",$pi_prov," in
  *,argo,*) pass "Pi provider id is 'argo'" "providers ($pi_shape): $pi_prov" ;;
  *)        fail "Pi provider id is 'argo'" "providers (${pi_shape:-missing}): ${pi_prov:-none} -- scripts/pi-session.sh passes --provider argo and will abort with Unknown provider" ;;
esac

# Both agents must be on the model this build promises -- "the same models
# your coding agent already uses", per README.md. Nothing checked this, and
# a build silently shipped both agents on argo:gpt-4o: an installer default
# Pi carried forward, never chosen by anyone. It passed every check here for
# weeks, because --models only asks whether a completion succeeds and gpt-4o
# completes perfectly well. The user found it after an agent spent an
# evening fabricating claims about files it had not written. (2026-11-06)
#
# These checks also exist to DISCLOSE. Before this, nothing ever told the
# user which model their agents were running -- the detection script
# prints the host's names at detection time, and after that the answer
# lived only inside the VM. A user talked to an agent for weeks without
# knowing, and found out only by reading a transcript that smelled wrong.
# Whatever these report, pass or fail, the name is printed.
WANT_MODEL="argo:claude-5-opus"

he_model="$(g 'hermes config get model.default 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'a-zA-Z0-9.:_/-')"
case "$he_model" in
  "")            skip "Hermes runs $WANT_MODEL" "could not read hermes config get model.default" ;;
  *claude-5-opus*|*claude-opus-5*|*claudeopus5*) pass "Hermes runs $WANT_MODEL" "$he_model" ;;
  *)             fail "Hermes runs $WANT_MODEL" "running '$he_model' -- the spec names $WANT_MODEL; an installer default is not a choice" ;;
esac

# Read the configured model, not every argo: string in the file --
# openclaw.json also lists the provider's whole model catalogue, so a grep
# returns a dozen ids that have nothing to do with what the agent runs.
# The first draft of this check did exactly that and failed a correct
# build, which is the mistake this file's own header warns about.
oc_model="$(g 'jq -r ".agents.defaults.model.primary // empty" $HOME/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
case "$oc_model" in
  "")            skip "OpenClaw runs $WANT_MODEL" "no argo: model id found in openclaw.json" ;;
  *claude-5-opus*|*claude-opus-5*|*claudeopus5*) pass "OpenClaw runs $WANT_MODEL" "$oc_model" ;;
  *)             fail "OpenClaw runs $WANT_MODEL" "found '$oc_model' -- the spec names $WANT_MODEL" ;;
esac

# The gateway caps generation at 4096 tokens when the client sends none,
# and Hermes sends none to a custom OpenAI-compatible endpoint by design.
# Compressing at the default half-window means summarizing ~150k tokens
# into 4096, which truncates -- and a truncated summary aborts compression,
# arms a 60s/300s/900s cooldown, and warns the user three times, forever.
# The symptom reaches the user as chat noise rather than a failed check,
# which is why it ran for weeks before anyone traced it.
thr="$(g 'hermes config get compression.threshold_tokens 2>/dev/null | tr -dc "0-9"')"
if [ -z "$thr" ] || [ "$thr" = 0 ]; then
  fail "Hermes compresses before the summary outgrows 4096 tokens" \
       "compression.threshold_tokens is unset, so compression fires at half the
        context window and the summary cannot fit in the endpoint's 4096-token cap"
elif [ "$thr" -le 80000 ]; then
  pass "Hermes compresses before the summary outgrows 4096 tokens" "threshold_tokens=$thr"
else
  fail "Hermes compresses before the summary outgrows 4096 tokens" \
       "threshold_tokens=$thr is too high for a 4096-token output cap"
fi

# Compression is mechanical work; running it on the main Opus model is
# slow and expensive for no gain.
cmod="$(g 'hermes config get auxiliary.compression.model 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'a-zA-Z0-9.:_/-')"
case "$cmod" in
  "")      fail "compression runs on a cheap fast model" \
                "auxiliary.compression.model is empty, so compression runs on the main model" ;;
  *flash*|*mini*|*nano*|*lite*) pass "compression runs on a cheap fast model" "$cmod" ;;
  *)       fail "compression runs on a cheap fast model" "$cmod" ;;
esac

# The agent's clock. Decides what "2pm today" means, when cron fires, and
# the time Hermes stamps into the prompt. Unset means "whatever zone the
# host happens to have" -- which is not an error anywhere, just a meeting
# on the wrong day. Compare against what the user asked for rather than
# merely checking it is non-empty: inheriting the right answer by luck is
# the thing being fixed.
want_tz="$( set -a; . config/agents.env 2>/dev/null; set +a; printf %s "${AGENT_TIMEZONE:-}" )"
he_tz="$(g 'hermes config get timezone 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'A-Za-z0-9/_+-')"
# A blank AGENT_TIMEZONE fails rather than skips. Skipping would mean the
# one deployment most likely to be on the wrong zone -- a clone whose
# agents.env predates this setting -- is also the one that never gets
# checked, which is the failure mode this whole section exists to close.
if [ -z "$want_tz" ]; then
  fail "Hermes runs on the configured timezone" \
       "AGENT_TIMEZONE is blank in config/agents.env, so nothing pins the agents'
        clock and they inherit the host zone. Set it (see agents.env.example)"
elif [ "$he_tz" = "$want_tz" ]; then
  pass "Hermes runs on the configured timezone" "$he_tz"
elif [ -z "$he_tz" ]; then
  fail "Hermes runs on the configured timezone" \
       "timezone is unset, so the agent uses the host zone -- right only by luck,
        and wrong by a whole zone on a clone built elsewhere. Want $want_tz"
else
  fail "Hermes runs on the configured timezone" "set to '$he_tz', want '$want_tz'"
fi

# ---------------------------------------------------------------------------
# Settings nobody chose. Each of these sat at a vendor default that is
# wrong for this deployment, and not one of them fails loudly -- they
# surface as the agent being slow, forgetful, truncated or chatty. The
# 2026-11-09 audit (docs/config-audit-2026-11-09.md) is the reasoning;
# these are the assertions.

# OpenClaw's custom-provider wizard pins maxTokens on every model row.
# 4096 is its value, OpenClaw's own default for an unpinned model is
# 32768, and the endpoint imposes nothing -- measured, it returned 14,606
# tokens in one response. So this caps replies for no reason, with no
# error, and bounds the compaction summary too.
oc_cap="$(g 'jq -r "[.models.providers[\"argo-gateway\"].models[]? | select(.maxTokens != null and .maxTokens < 16000)] | length" $HOME/.openclaw/openclaw.json 2>/dev/null' | tr -dc '0-9')"
case "${oc_cap:-x}" in
  0) pass "OpenClaw does not cap its own output" "no model row pinned below 16000" ;;
  x) skip "OpenClaw does not cap its own output" "could not read openclaw.json" ;;
  *) fail "OpenClaw does not cap its own output" \
          "${oc_cap} model row(s) pin maxTokens below 16000 -- wizard residue. Long
        replies truncate silently and compaction summaries are bounded too" ;;
esac

# Compaction on the main model, with thinking on, is how OpenClaw
# reproduces the Hermes chat-spam loop: a summary whose allowance goes to
# reasoning tokens is rejected, history stays uncompacted, and safeguard
# mode warns the user even when notifyUser is false.
oc_cmod="$(g 'jq -r ".agents.defaults.compaction.model // empty" $HOME/.openclaw/openclaw.json 2>/dev/null' | tr -dc 'a-zA-Z0-9.:_/-')"
case "$oc_cmod" in
  *flash*|*mini*|*nano*|*lite*) pass "OpenClaw compacts on a cheap fast model" "$oc_cmod" ;;
  "") fail "OpenClaw compacts on a cheap fast model" \
           "compaction.model is unset, so compaction runs on the session model (Opus)" ;;
  *)  fail "OpenClaw compacts on a cheap fast model" "$oc_cmod" ;;
esac

# Unset means OpenAI embeddings, and there is no OpenAI key here. Memory
# indexing stops while the session-memory hook keeps writing files, so
# the agent accumulates memories it can never search and appears to
# forget things over weeks. Nothing errors.
oc_mem="$(g 'jq -r ".memory.search.provider // empty" $HOME/.openclaw/openclaw.json 2>/dev/null' | tr -dc 'a-z-')"
case "$oc_mem" in
  "") fail "OpenClaw memory search has a provider that exists" \
           "memory.search.provider is unset, so it defaults to OpenAI embeddings and
        there is no key -- indexing silently stops while memories keep being written" ;;
  openai) fail "OpenClaw memory search has a provider that exists" \
               "set to openai with no key configured" ;;
  none) fail "OpenClaw memory search has a provider that exists" \
             "set to 'none', which is keyword-only. That was correct while no embedding
        model was reachable, and is not any more: the gateway serves
        /v1/embeddings (argo:text-embedding-3-small, 1536 dims, measured
        2026-11-12). It also leaves memory-core's nightly dreaming sweep
        failing with MCP_AUTHORIZATION_RETIRED, an error that names neither
        memory nor embeddings" ;;
  *) pass "OpenClaw memory search has a provider that exists" "$oc_mem" ;;
esac

# Dreaming is memory-core's 03:00 consolidation sweep, promoting short-term
# entries into MEMORY.md. It auto-manages its own cron job, so it exists
# whether or not anyone configured it -- and with no embedding provider it
# fails every night, silently, because delivery is "not requested".
#
# This earns its place by having failed every run since the agent was
# built, unnoticed, until the agent itself mentioned it in passing. The
# error text points at MCP, which cost an hour of looking in the wrong
# place: disabling the only MCP server changed nothing, which is what
# proved the connection false.
dream="$(g 'openclaw automations list 2>/dev/null | grep -i "dream" | head -1')"
case "$dream" in
  "")      skip "the nightly memory sweep is not failing" "no dreaming job found" ;;
  *error*) fail "the nightly memory sweep is not failing" \
                "memory-core's dreaming job is in error. Usual cause is the embedding
        provider above, not whatever its error text names. Reproduce on demand:
        openclaw automations run <id> --wait" ;;
  *)       pass "the nightly memory sweep is not failing" ;;
esac

# Without pruning the vendor reports multi-GB state.db within weeks on
# exactly this shape of install (gateway + cron). The first symptom the
# user sees is the bot asking about disk pruning over Telegram.
hp="$(g 'hermes config get sessions.auto_prune 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'a-z')"
case "$hp" in
  true) pass "Hermes prunes ended sessions" ;;
  *)    fail "Hermes prunes ended sessions" \
             "sessions.auto_prune is '${hp:-unset}' -- state.db grows without bound on a
        gateway+cron install, and the VM disk is finite" ;;
esac

# A 192.168.x.x endpoint is auto-classified LAN, which relaxes four
# timeouts (socket read 120s -> 1800s). Meant for a slow local GPU; ours
# is a shim in front of a remote service, so a wedged upstream would hang
# a Telegram turn for half an hour. An explicit value is honoured anyway.
hs="$(g 'hermes config get providers.argo-gateway.stale_timeout_seconds 2>/dev/null | tr -d "\r" | tail -1' | tr -dc '0-9')"
if [ -n "$hs" ] && [ "$hs" -le 300 ]; then
  pass "Hermes fails fast on a wedged upstream" "stale_timeout_seconds=$hs"
else
  fail "Hermes fails fast on a wedged upstream" \
       "stale_timeout_seconds is '${hs:-unset}' -- our LAN-address endpoint gets the
        relaxed local-endpoint timeouts, so a silent upstream hangs a turn for ~30min"
fi

# After any suspend or restart, every missed slot fires on return, each
# delivering to Telegram: a burst of stale briefs.
hc="$(g 'hermes config get cron.catch_up_missed 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'a-z')"
case "$hc" in
  false) pass "cron does not replay every missed slot" ;;
  *)     fail "cron does not replay every missed slot" \
              "cron.catch_up_missed is '${hc:-unset}' -- after a suspend or restart each
        missed schedule fires once on return, all delivering to Telegram" ;;
esac

# Who may message the bot is the only access control on an agent with
# shell access, a mailbox and the user's Drive. The default hands an
# unknown DM a pairing code.
hu="$(g 'hermes config get unauthorized_dm_behavior 2>/dev/null | tr -d "\r" | tail -1' | tr -dc 'a-z')"
case "$hu" in
  ignore|decline) pass "strangers are not offered a pairing code" "$hu" ;;
  *) fail "strangers are not offered a pairing code" \
          "unauthorized_dm_behavior is '${hu:-unset}' -- the default sends an unknown
        Telegram user a pairing code, and the allowlist is the only control here" ;;
esac

oc_tz="$(g 'jq -r ".agents.defaults.userTimezone // empty" $HOME/.openclaw/openclaw.json 2>/dev/null' | tr -dc 'A-Za-z0-9/_+-')"
if [ -z "$want_tz" ]; then
  fail "OpenClaw runs on the configured timezone" \
       "AGENT_TIMEZONE is blank in config/agents.env -- see the Hermes check above"
elif [ "$oc_tz" = "$want_tz" ]; then
  pass "OpenClaw runs on the configured timezone" "$oc_tz"
elif [ -z "$oc_tz" ]; then
  fail "OpenClaw runs on the configured timezone" \
       "agents.defaults.userTimezone is unset -- the agent uses the host zone. Want $want_tz"
else
  fail "OpenClaw runs on the configured timezone" "set to '$oc_tz', want '$want_tz'"
fi

# ---------------------------------------------------------------------------
section "Egress policy"

# --idempotence needs the bootstrap allowlist (Pi's setup.sh fetches from
# pypi.org), so for that run 'bootstrap' is the correct phase. A plain run
# still requires runtime: a finished build must be narrowed.
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
section "Egress enforcement: public web yes, private network no"

# 1. The public web is REACHABLE. An agent limited to its training data
#    cannot answer a question about today, so this is a feature test: the
#    boundary is the private network, not the internet.
code="$(g 'curl -sS -m 20 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://example.com/ 2>/dev/null')"
case "$code" in
  200|30*) pass "public web is reachable through squid" "http://example.com -> $code" ;;
  403)     fail "public web is reachable through squid" "squid returned 403 -- it is still running an allowlist-only policy. The agents cannot browse." ;;
  *)       fail "public web is reachable through squid" "got '${code:-no response}'. Is squid listening on 127.0.0.1:3128?" ;;
esac

# 2. The private network is DENIED. This is the boundary that matters: the
#    threat is an agent harming the host it depends on, not an agent
#    reading the news. 403 is self-validating -- only squid sends it.
#
#    Hits the host's own gateway address, which is the most consequential
#    thing in reach and the one a confused agent is most likely to find.
hostip="$(g 'ip route show default 2>/dev/null' | sed -nE 's/^default via ([0-9.]+).*/\1/p' | head -1)"
if [ -n "$hostip" ]; then
  pcode="$(g "curl -sS -m 15 -o /dev/null -w '%{http_code}' --proxy http://127.0.0.1:3128 http://$hostip/ 2>/dev/null")"
  case "$pcode" in
    403)     pass "private network is DENIED by squid" "http://$hostip (the host) -> 403" ;;
    # 000 means the connection failed before squid ruled on it -- nothing is
    # listening there. That is not a denial, and reporting it as one would
    # be a green light for a policy that was never exercised.
    000|'')  skip "private network is DENIED by squid" "http://$hostip -> no response; nothing is listening, so squid never ruled on it. Inconclusive, not a pass." ;;
    *)       fail "private network is DENIED by squid" "http://$hostip -> $pcode, expected 403. An agent can reach the host and whatever else runs on this LAN." ;;
  esac
else
  skip "private network is DENIED by squid" "could not read the guest's default route"
fi

# 3. Around the proxy entirely; the iptables chain rejects it. This is what
#    makes the proxy policy binding rather than advisory -- an agent that
#    ignores http_proxy reaches nothing. The reject is
#    icmp-admin-prohibited, so it fails fast; a timeout means something
#    else is wrong.
t0=$SECONDS
direct="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --noproxy "*" http://1.1.1.1/ 2>/dev/null')"
dt=$((SECONDS - t0))
if [ "$direct" = "000" ]; then
  pass "direct bypass is BLOCKED by iptables" "http://1.1.1.1 (no proxy) -> no connection, ${dt}s"
else
  fail "direct bypass is BLOCKED by iptables" "got HTTP $direct -- the agent can reach the internet without the proxy"
fi

# 4. The control for test 3, which would pass equally well if the VM had no
#    network at all. The rule is uid-scoped, so root must SUCCEED here.
rootdirect="$(groot 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --noproxy "*" http://1.1.1.1/ 2>/dev/null')"
if [ "$rootdirect" != "000" ] && [ -n "$rootdirect" ]; then
  pass "lockdown is scoped to the agent uid" "same request as root -> HTTP $rootdirect (the VM does have egress)"
elif [ "$direct" = "000" ]; then
  skip "lockdown is scoped to the agent uid" "root is blocked too (HTTP ${rootdirect:-000}). Either the rule is not uid-scoped, or this host has no route to 1.1.1.1 -- in which case test 2 above proved nothing. Check manually."
else
  fail "lockdown is scoped to the agent uid" "root -> ${rootdirect:-000}"
fi

# 5. Positive control: the model gateway bypasses squid by design, via one
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
section "The vendors' own health checks"

# `hermes doctor` ships with the product and reports config version,
# deprecated keys, credential resolution, SQLite health and per-tool
# readiness. It was not run once across three days of building this repo,
# while four configuration gaps shipped past the rest of this suite. One
# command. Run it.
#
# Its exit code is 1 whenever any optional integration is unconfigured, so
# it cannot be used directly -- this deployment deliberately has no
# Discord, no xAI, no Docker, no browser and one custom endpoint. Filter
# those, fail on anything left, and print what was filtered so the
# exclusion list stays honest rather than quietly swallowing a real
# finding.
#
# KNOWN-OPTIONAL, deliberately not used here. Shrink this list, never grow
# it without a reason written beside it.
DOCTOR_OK='DISCORD|XAI|GITHUB_TOKEN|system dependency not met|image generation unavailable|Nous Portal auth|OpenAI Codex auth|MiniMax OAuth|Docker/Podman not found|OpenRouter API'

doc_out="$(g 'hermes doctor 2>&1')"
if [ -z "$(printf '%s' "$doc_out" | tr -d '[:space:]')" ]; then
  skip "hermes doctor reports nothing actionable" "could not run hermes doctor"
else
  # A hard failure marker is actionable whatever it says.
  doc_bad="$(printf '%s\n' "$doc_out" | grep -E '^[[:space:]]*[✗✘×]' | head -5)"
  doc_warn="$(printf '%s\n' "$doc_out" | grep '⚠' | grep -viE "$DOCTOR_OK" | head -5)"
  n_filtered="$(printf '%s\n' "$doc_out" | grep -c '⚠' || true)"
  if [ -n "$doc_bad" ] || [ -n "$doc_warn" ]; then
    fail "hermes doctor reports nothing actionable" \
         "$(printf '%s %s' "$doc_bad" "$doc_warn" | tr '\n' ' ' | cut -c1-200)"
  else
    pass "hermes doctor reports nothing actionable" \
         "${n_filtered:-0} warnings, all on the known-optional list"
  fi
fi

# OpenClaw ships a richer doctor than Hermes, and a trap with it: the
# default lint run selects 39 of 69 checks and reported ok:true with an
# empty findings list while --all found 33. A bare `openclaw doctor` in
# this suite would be a false green, which is the exact class of mistake
# this section exists to stop.
#
# It also exits 0 even when ok:false, so the JSON has to be parsed rather
# than the exit code trusted.
#
# KNOWN-OPTIONAL, deliberately tolerated here. Shrink this, never grow it
# without writing why beside it.
#   skills-readiness -- ~30 catalogue skills whose binaries are absent
#     (github, 1password, obsidian...). None are wanted in this sandbox.
OC_DOCTOR_OK='core/doctor/skills-readiness'

oc_doc="$(g 'openclaw doctor --lint --all --deep --json 2>/dev/null')"
if [ -z "$(printf '%s' "$oc_doc" | tr -d '[:space:]')" ]; then
  skip "openclaw doctor reports nothing actionable" "could not run openclaw doctor"
else
  oc_left="$(printf '%s' "$oc_doc" | python3 -c "
import json,sys,re
try: d=json.load(sys.stdin)
except Exception: print('PARSE_FAIL'); raise SystemExit
ok=re.compile(r'''$OC_DOCTOR_OK''')
bad=[f for f in d.get('findings',[]) if not ok.search(f.get('checkId',''))]
print('CHECKS=%s' % d.get('checksRun',0))
for f in bad[:5]: print('%s: %s' % (f.get('checkId'), f.get('message','')[:90]))
" 2>/dev/null)"
  case "$oc_left" in
    PARSE_FAIL|"") fail "openclaw doctor reports nothing actionable" "could not parse its JSON" ;;
    *)
      n_checks="$(printf '%s' "$oc_left" | sed -n 's/^CHECKS=//p')"
      rest="$(printf '%s\n' "$oc_left" | grep -v '^CHECKS=' | head -3)"
      # --all is 69 checks here; anything near 39 means the filtered
      # default run was used and the result cannot be trusted.
      if [ "${n_checks:-0}" -lt 60 ]; then
        fail "openclaw doctor reports nothing actionable" \
             "only ${n_checks} checks ran -- --all was not honoured, so this would be a false green"
      elif [ -n "$rest" ]; then
        fail "openclaw doctor reports nothing actionable" "$(printf '%s' "$rest" | tr '\n' ' ' | cut -c1-200)"
      else
        pass "openclaw doctor reports nothing actionable" "${n_checks} checks, only known-optional findings"
      fi ;;
  esac
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

# A systemd user service does not read ~/.profile, so the gateway needs a
# proxy route to the allowlist from somewhere. There are two working
# designs and this accepts either:
#
#   env vars in the unit  -- http_proxy/https_proxy plus NODE_USE_ENV_PROXY,
#                            which Node ignores the proxy without
#   per-channel proxy     -- channels.<name>.proxy in openclaw.json
#
# The second exists because Node 24's undici proxied the MODEL gateway too,
# ignoring NO_PROXY, which killed completions while channels worked. Env
# vars are not therefore wrong -- they were right on Node 22 -- so assert
# that a route exists, not which one.
#
# Neither covers web_fetch: see the managed-proxy check below.
gwenv="$(g "systemctl --user show openclaw-gateway.service -p Environment --value" | tr ' ' '\n')"
gwproxy="$(printf '%s' "$gwenv" | grep -c -iE '^(https?_proxy|NODE_USE_ENV_PROXY)=')"
chproxy="$(g 'jq -r "[(.channels // {}) | to_entries[] | select(.value.proxy != null)] | length" ~/.openclaw/openclaw.json 2>/dev/null' | tr -dc '0-9')"
if [ "${gwproxy:-0}" -ge 3 ]; then
  pass "gateway can reach the allowlist" "$gwproxy proxy vars in the unit"
elif [ "${chproxy:-0}" -ge 1 ]; then
  pass "gateway can reach the allowlist" "$chproxy channel(s) carry an explicit proxy; the model path goes direct"
else
  fail "gateway can reach the allowlist" "no proxy env in openclaw-gateway.service and no channels.<name>.proxy in openclaw.json -- channels will fail EHOSTUNREACH even though the model path works"
fi

# OpenClaw's HTTP tools read a managed proxy from config and ignore the
# environment, so web_fetch goes direct into the uid lockdown while every
# other check above passes. The agent then reports the block as a transient
# upstream error and may route around it.
ocproxy="$(g 'jq -r ".proxy.proxyUrl // empty" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
if [ -n "$ocproxy" ]; then
  pass "OpenClaw web tools use the proxy" "proxy.proxyUrl=$ocproxy"
else
  fail "OpenClaw web tools use the proxy" "proxy.proxyUrl unset -- web_fetch will fail EHOSTUNREACH though channels and completions work. Run: openclaw config set proxy.proxyUrl http://127.0.0.1:3128"
fi

# Keyed on ~/.hermes/.env, which is also where the spec requires Hermes'
# credentials to live. Do not key this on channel_directory.json: Hermes
# never writes it, so the check would pass unconditionally.
hactive="$(g "systemctl --user is-active hermes-gateway.service" | tr -d '\r')"
if g 'grep -qE "^TELEGRAM_BOT_TOKEN=.+" ~/.hermes/.env' >/dev/null 2>&1; then
  if [ "$hactive" = "active" ]; then
    pass "hermes-gateway" "active (Telegram credentials are configured)"
  else
    fail "hermes-gateway" "Telegram is configured but the gateway is $hactive -- run: hermes gateway install"
  fi

  # A running service is not a working adapter: the plugin ships disabled
  # and its dependency comes from pypi.org, allowlisted only in bootstrap.
  # Miss either and the service sits active reporting "No adapter
  # available for telegram".
  #
  # Scope to the CURRENT service start and take the last adapter event, not
  # the last *connect* -- otherwise one historical success reports
  # "connected" forever, including while the adapter is failing to
  # reconnect. A drop it never recovers from is what this catches.
  #
  # A long-poll drops and reconnects routinely, so a lone network error is
  # only a failure if it persists: re-read after a pause and judge the
  # second sample. Without that this check flapped PASS/FAIL/SKIP between
  # runs minutes apart and failed whole builds over a transient.
  #
  # The flapping is damped, not cured: on 2026-11-02 this reported FAIL
  # under finish-build.sh and SKIP minutes later, on an adapter the user
  # then found answering on Telegram. Two causes are in play and neither
  # is the agent being broken -- a reconnect this samples mid-drop, and
  # the Conflict branch below, which names check-telegram-polling.sh as
  # the rival getUpdates consumer while verify.sh runs that very script
  # later in this same file. Treat a FAIL or SKIP here as "unproven, go
  # message the bot", never as "the agent is down".
  adapter_event() {
    g 'journalctl --user -u hermes-gateway.service --no-pager _SYSTEMD_INVOCATION_ID="$(systemctl --user show -p InvocationID --value hermes-gateway.service)" 2>/dev/null | grep -iE "\[Telegram\] Connected|No adapter available for telegram|adapter creation failed|Telegram network error|Conflict: terminated" | tail -1'
  }
  # A transient needs a long enough window to recover in, and 20s was not
  # it. This check has claimed "not reconnecting on its own" three times
  # about an adapter that was reconnecting: twice on Linux, once on macOS
  # right after a reboot, where the very next run 18 seconds later read
  # PASS. Sample for up to two minutes and stop at the first success.
  jr="$(adapter_event)"
  case "$jr" in
    *"network error"*)
      for _ in 1 2 3 4 5 6; do
        sleep 20
        jr="$(adapter_event)"
        case "$jr" in *"Connected to Telegram"*) break ;; esac
      done ;;
  esac
  # `sed 's/.*: //'` renders "httpx.ConnectError: " as nothing at all, which
  # printed a failure message with an empty reason. Keep the whole line.
  jr_msg="$(printf '%s' "$jr" | sed 's/^.*\] //')"
  case "$jr" in
    *"Connected to Telegram"*) pass "Hermes Telegram adapter" "connected (polling), this service start" ;;
    "")                        skip "Hermes Telegram adapter" "no adapter activity since the service started" ;;
    *"Conflict: terminated"*)  skip "Hermes Telegram adapter" "another getUpdates consumer took the poll -- usually check-telegram-polling.sh, or two gateway restarts inside Telegram's session-expiry window; the adapter reconnects on its own" ;;
    *"network error"*)         skip "Hermes Telegram adapter" "${jr_msg:-network error} -- still down after 2 minutes. Long-polls drop and reconnect, and this check has been wrong about it before, so: message the bot. That settles it and nothing here can." ;;
    *)                         fail "Hermes Telegram adapter" "${jr_msg:-unrecognised adapter state} -- check: hermes plugins enable telegram-platform, and that pypi was reachable when it first started" ;;
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

# No plaintext secrets, and no SecretRef the CLI cannot resolve. Run from a
# plain login shell: sourcing agents.env first hides a missing export, which
# is the failure this catches. The gateway resolves refs from its own
# EnvironmentFile, so an unresolved one breaks only the CLI and leaves the
# service looking healthy.
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

# That audit only sees OpenClaw's own config. On 2026-11-04 Pi fixed a mute
# adapter by inventing ~/.config/agent-sandbox/openclaw.env holding a second
# plaintext copy of the bot token, and the audit reported plaintext=0 while
# it sat there. Count the copies directly. agents.env is the sanctioned one;
# anything else beside it is a footprint nobody decided to add.
#
# Search the agents' own directories too, not just agent-sandbox/. On
# 2026-11-09 Pi resolved a gateway-token conflict by writing
# ~/.openclaw/gateway.env -- agents.env minus one variable, both bot tokens
# in plaintext -- and this check looked in the wrong directory and passed.
# A scan that only covers the place the last offender chose will keep
# finding the last offender.
#
# Three exclusions, each deliberate:
#   agent-sandbox/agents.env  the sanctioned copy, 0600
#   .hermes/.env              where the spec *requires* Hermes' credentials
#   hermes-agent/tests/       vendor test fixtures carrying dummy tokens
# OpenClaw's state DB is excluded by searching text files only: it stores
# channel config as a matter of course and is not a copy anyone wrote.
tokdup="$(g 'grep -rlE "[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}" \
    $HOME/.config/agent-sandbox/ $HOME/.openclaw/ $HOME/.hermes/ 2>/dev/null \
  | grep -v "/agent-sandbox/agents.env$" \
  | grep -v "/\.hermes/\.env$" \
  | grep -v "/hermes-agent/tests/" \
  | while read -r f; do [ -f "$f" ] && file -b "$f" | grep -qi text && printf "%s " "$f"; done')"
if [ -z "$(printf '%s' "$tokdup" | tr -d '[:space:]')" ]; then
  pass "bot tokens live in one file only" "nothing beside agents.env carries a bot token"
else
  fail "bot tokens live in one file only" "also in: $tokdup -- a second plaintext copy the secrets audit cannot see. Give the service the variable name it wants without duplicating the value."
fi

# The agent must carry the configured name, and its SOUL.md must be the
# seed rather than a vendor default. Checking only that some SOUL.md
# exists passes a build where the seed landed in an unused directory and
# Hermes kept the stock Nous persona.
want_oc="$(g 'set -a; . $HOME/.config/agent-sandbox/agents.env 2>/dev/null; set +a; printf %s "$OPENCLAW_AGENT_NAME"' | tr -d '\r')"
want_he="$(g 'set -a; . $HOME/.config/agent-sandbox/agents.env 2>/dev/null; set +a; printf %s "$HERMES_AGENT_NAME"' | tr -d '\r')"

# Assert the *identity*, never the directory name. OpenClaw's agent id is
# fixed by onboard and cannot be renamed; the identity is the display name
# and is what the user chose. Requiring the directory to match the name
# fails a correct build.
agents_out="$(g 'openclaw agents list 2>/dev/null')"
live_identity="$(printf '%s' "$agents_out" | grep -m1 'Identity:' | sed 's/.*Identity: *//; s/ *(.*//' | tr -d '\r')"
# Match on CONTAINMENT, not equality. OpenClaw composes the displayed
# identity from IDENTITY.md, so an agent that fills in an Emoji or Theme
# shows up as "🜂 LuoJi" -- the configured name correctly applied, plus
# decoration the agent chose for itself. Requiring equality failed a
# correct build the first time an agent edited its own identity file,
# which is a thing this repo explicitly invites it to do.
if [ -n "$want_oc" ] && [ -n "$live_identity" ]; then
  case "$live_identity" in
    *"$want_oc"*)
      if [ "$live_identity" = "$want_oc" ]; then
        pass "OpenClaw agent identity is as configured" "$live_identity"
      else
        pass "OpenClaw agent identity is as configured" \
             "$live_identity -- name applied, the rest is from IDENTITY.md"
      fi ;;
    *)
      fail "OpenClaw agent identity is as configured" \
           "identity is '$live_identity', expected it to contain '$want_oc' -- OPENCLAW_AGENT_NAME was not applied" ;;
  esac
else
  skip "OpenClaw agent identity is as configured" "could not read the configured name or the live identity"
fi

# OpenClaw keeps SOUL.md in the agent's WORKSPACE, not under
# agents/<id>/. That directory is state -- openclaw-agent.sqlite,
# sessions/, recovery/ -- and nothing in it is ever loaded as identity.
# The vendor: "Save this file at the workspace root as SOUL.md", and
# "These live in the agent workspace, not ~/.openclaw."
#
# This check used to derive the path from `Agent dir:` and so validated a
# file the gateway never reads, which is how a seed sat in the wrong place
# for days while this suite passed. Resolve the workspace from the config
# the way OpenClaw does: the agent's own entry, then the default.
live_dir="$(g 'id=$(openclaw agents list --json 2>/dev/null | jq -r ".[0].id // empty");
  jq -r --arg id "$id" "(.agents.entries[\$id].workspace // .agents.defaults.workspace // empty)" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r' | head -1)"
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
if [ -n "$live_dir" ]; then
  check_soul "OpenClaw" "$live_dir/SOUL.md" "$want_oc"
else
  skip "OpenClaw SOUL.md" "could not resolve the agent workspace from openclaw.json, so there is nothing to check -- absent, not passing"
fi
check_soul "Hermes" '$HOME/.hermes/SOUL.md' "$want_he"

# A SOUL.md anywhere the gateway does not read is a trap, and the agents
# write to one unprompted: Hermes has twice created ~/SOUL.md, and an
# OpenClaw agent edited a second copy for days while the live file sat
# untouched. Nothing fails when it happens -- the user sees an identity
# that never changes and an agent insisting it saved the change -- so this
# is exactly the defect a suite should catch and a human cannot.
#
# Known-good paths only: the two live files, plus the vendors' own
# bundled templates and docs, which are theirs and not ours to police.
# Trash is excluded too -- a deleted file is already the right outcome,
# and leaving it in scope means this check fails forever over something
# the user has thrown away.
strays="$(g "find \$HOME -maxdepth 6 -name SOUL.md \
    ! -path '$live_dir/SOUL.md' \
    ! -path \"\$HOME/.hermes/SOUL.md\" \
    ! -path '*/node_modules/*' \
    ! -path \"\$HOME/.hermes/hermes-agent/*\" \
    ! -path \"\$HOME/.local/share/Trash/*\" \
    2>/dev/null | head -5 | tr '\n' ' '")"
if [ -z "$(printf '%s' "$strays" | tr -d '[:space:]')" ]; then
  pass "no stray SOUL.md outside the loaded paths"
else
  fail "no stray SOUL.md outside the loaded paths" \
       "$strays-- a file here is never loaded, but an agent asked to change its
        personality may edit it and report success. Have the agent delete it and
        re-apply the change to the live path above"
fi

# ---------------------------------------------------------------------------
section "Channels: never reachable without an allowlist"

# WHO MAY TALK TO THE BOT IS THE CHECK THAT MATTERS.
#
# Egress policy does not help here: it governs outbound traffic, while
# Telegram DELIVERS inbound to whoever messages the bot. The only thing
# between a stranger and an agent with shell access and no permission
# prompts is the agent's own allowlist -- OpenClaw's dmPolicy/allowFrom,
# Hermes' TELEGRAM_ALLOWED_USERS. Empty means it answers anybody.
#
# Checking whether a channel is enabled, or whether a bot is polling, both
# pass while the restriction is absent. Assert the restriction itself.
want_id="$(grep -E '^TELEGRAM_ALLOWED_USER_ID=' "$REPO_DIR/config/agents.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -dc '0-9')"

oc_has_tg="$(g 'jq -e ".channels.telegram" ~/.openclaw/openclaw.json >/dev/null 2>&1 && echo yes' | tr -d '\r')"
if [ "$oc_has_tg" = "yes" ]; then
  oc_pol="$(g 'jq -r ".channels.telegram.dmPolicy // \"unset\"" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
  oc_alw="$(g 'jq -r "(.channels.telegram.allowFrom // []) | join(\",\")" ~/.openclaw/openclaw.json 2>/dev/null' | tr -d '\r')"
  if [ "$oc_pol" = "allowlist" ] && [ -n "$oc_alw" ]; then
    pass "OpenClaw Telegram is restricted" "dmPolicy=allowlist, allowFrom=$oc_alw"
  else
    fail "OpenClaw Telegram is restricted" "dmPolicy=$oc_pol allowFrom=${oc_alw:-empty} -- anyone who finds this bot could talk to an agent with shell access"
  fi
  # `case`, not `[ ... != *glob* ]` -- inside `[ ]` the pattern is compared
  # literally and reports a mismatch every time.
  if [ -n "$want_id" ]; then
    case ",$oc_alw," in
      *",$want_id,"*) : ;;
      *) fail "OpenClaw allowFrom matches the configured user" "allowFrom=$oc_alw does not contain TELEGRAM_ALLOWED_USER_ID -- you would not be able to talk to it, and someone else might" ;;
    esac
  fi
else
  skip "OpenClaw Telegram is restricted" "no telegram channel configured"
fi

if g 'grep -qE "^TELEGRAM_BOT_TOKEN=.+" ~/.hermes/.env' >/dev/null 2>&1; then
  he_alw="$(g 'grep -E "^TELEGRAM_ALLOWED_USERS=" ~/.hermes/.env | head -1 | cut -d= -f2-' | tr -d '\r ')"
  if [ -n "$he_alw" ]; then
    he_ok=1
    if [ -n "$want_id" ]; then
      case ",$he_alw," in
        *",$want_id,"*) : ;;
        *) he_ok=0 ;;
      esac
    fi
    if [ "$he_ok" = "1" ]; then
      pass "Hermes Telegram is restricted" "TELEGRAM_ALLOWED_USERS=$he_alw"
    else
      fail "Hermes Telegram is restricted" "TELEGRAM_ALLOWED_USERS=$he_alw does not contain the configured user id"
    fi
  else
    fail "Hermes Telegram is restricted" "TELEGRAM_ALLOWED_USERS is empty or absent -- an unrestricted bot answers anyone who finds it"
  fi
else
  skip "Hermes Telegram is restricted" "no Telegram credentials configured"
fi

# A safety assertion, not a feature test. An enabled channel is fine and
# is the intended end state; enabled WITHOUT a restriction is the failure,
# and this makes that fatal rather than merely noted.
oc_ch="$(g 'jq -r "(.channels // {}) | to_entries | map(select(.value.enabled != false)) | length" ~/.openclaw/openclaw.json 2>/dev/null' | tr -dc '0-9')"
if [ "${oc_ch:-0}" = "0" ]; then
  pass "OpenClaw channel safety" "no channel enabled (restriction not load-bearing yet)"
elif [ "${oc_pol:-}" = "allowlist" ] && [ -n "${oc_alw:-}" ]; then
  pass "OpenClaw channel safety" "$oc_ch channel(s) enabled, restricted to $oc_alw"
else
  fail "OpenClaw channel safety" "$oc_ch channel(s) enabled with dmPolicy=${oc_pol:-unset} allowFrom=${oc_alw:-empty} -- a reachable agent with shell access that anyone could message. Disable it: openclaw config set channels.telegram.enabled false"
fi

# Hermes has no enable flag: the adapter polls from the moment the gateway
# starts. Its safety therefore rests entirely on TELEGRAM_ALLOWED_USERS,
# asserted above. This check stays as a backstop for anything that *does*
# write an enabled entry into the channel directory.
if g 'ls ~/.hermes/channel_directory.json' >/dev/null 2>&1; then
  he_ch="$(g 'jq -r "[.. | objects | select(.enabled == true)] | length" ~/.hermes/channel_directory.json 2>/dev/null' | tr -dc '0-9')"
  if [ "${he_ch:-0}" = "0" ]; then
    pass "Hermes channel safety" "channel directory lists none enabled; reachability is the adapter's, restriction asserted above"
  elif [ -n "${he_alw:-}" ]; then
    pass "Hermes channel safety" "$he_ch enabled, restricted to $he_alw"
  else
    fail "Hermes channel safety" "$he_ch enabled with no TELEGRAM_ALLOWED_USERS"
  fi
else
  pass "Hermes channel safety" "no channel directory"
fi

# Informational: which bots are being polled. Do NOT fail on this.
# Reachable agents are the intended end state, and what protects the user
# is the allowlist asserted above, not silence. Asserting silence here
# marked a correct build as bad.
#
# Polling is not answering. This check reads the Telegram API, not the
# agent behind it: on 2026-11-02 a bot polled, took delivery of a message
# (two blue ticks) and never replied, while this line passed. Only a human
# messaging the bot closes that gap -- say so rather than implying it.
if [ -f "$REPO_DIR/config/agents.env" ]; then
  poll_out="$("$REPO_DIR/scripts/check-telegram-polling.sh" 2>&1)"
  live="$(grep -cE 'POLLING' <<<"$poll_out")"
  if [ "${live:-0}" = "0" ]; then
    # Not a pass. On 2026-11-04 an OpenClaw adapter never started -- its
    # unit carried OPENCLAW_TELEGRAM_BOT_TOKEN while --use-env reads
    # TELEGRAM_BOT_TOKEN -- and the agent was mute while the suite read
    # 37 passed, 0 failed. Still not a fail: tokens may be deliberately
    # blank, and this probe steals the poll it measures, so a live
    # adapter can read as absent. Skip is the honest verdict.
    skip "Telegram reachability is known" "no bot is being polled -- if you configured tokens, no agent will answer a message. A mute agent has read as 37 passed, 0 failed here before: message one and see."
  else
    pass "Telegram reachability is known" "$live bot(s) polling -- NOT proof any of them answers. Message one and watch it fetch a web page; nothing automated covers that."
  fi
else
  skip "Telegram reachability is known" "config/agents.env not present"
fi

# ---------------------------------------------------------------------------
section "Idempotence of Pi's setup.sh"

# setup.sh is the deliverable and a second run must change nothing. Pi
# self-reports this and has been wrong. Opt-in: it re-runs the script
# against a live VM.
if [ "$DO_IDEM" -eq 0 ]; then
  skip "setup.sh is idempotent" "re-run with --idempotence (re-runs Pi's script against this VM)"
else
  if ! g 'test -x ~/agent-bootstrap/setup.sh' >/dev/null 2>&1; then
    skip "setup.sh is idempotent" "~/agent-bootstrap/setup.sh not found"
  elif [ "$phase" != "bootstrap" ]; then
    skip "setup.sh is idempotent" "needs the bootstrap allowlist; currently '$phase'. To re-check after a fix: ./scripts/install-config.sh (returns the VM to the bootstrap phase), then ./verify/verify.sh --idempotence, then ./scripts/finish-build.sh to narrow egress again."
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

# Confirm the configured gateway address is the guest's real default route,
# so an unrelated failure cannot be blamed on it. Costs nothing.
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
  # Reassemble the text_delta fragments first: a stream splits "SSE_OK"
  # across deltas, so grepping the raw SSE for it never matches.
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

  # The proxy check above reads a config value, and stayed green for a whole
  # build while web_fetch returned nothing. Fetch something instead.
  out="$(g "timeout 180 openclaw agent --model '$ocmodel' --message 'Use web_fetch on https://tpc25.org and reply with exactly: FETCH_OK if you got page text' 2>&1")"
  if grep -q 'FETCH_OK' <<<"$out"; then
    pass "OpenClaw can fetch a web page" "web_fetch reached https://tpc25.org"
  else
    fail "OpenClaw can fetch a web page" "$(tr -d '\r' <<<"$out" | grep -viE 'key|token|secret' | tail -2 | paste -sd' | ' -)"
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
    # because everything else still looks healthy. Test the boundary that
    # exists -- the private network -- not the public web, which the agents
    # are meant to reach.
    rcode="$(g 'curl -sS -m 15 -o /dev/null -w "%{http_code}" --proxy http://127.0.0.1:3128 http://169.254.169.254/ 2>/dev/null')"
    [ "$rcode" = "403" ] && pass "egress still enforced after reboot" "link-local -> 403" \
                         || fail "egress still enforced after reboot" "link-local -> ${rcode:-000}, expected squid's 403"
  fi
fi

# ---------------------------------------------------------------------------
printf '\n%s== Summary ==%s\n' "$B" "$Z"
printf '  %s%d passed%s, %s%d failed%s, %s%d skipped%s\n' "$G" "$PASS" "$Z" "$R" "$FAIL" "$Z" "$Y" "$SKIP" "$Z"

# Say which models are running, every time, in the part people read. A
# build shipped both agents on an obsolete model for weeks because this
# line did not exist: the information was inside the VM and nowhere else.
printf '\n  %sModels%s  Hermes: %s\n' "$B" "$Z" "${he_model:-unknown}"
printf '          OpenClaw: %s\n' "${oc_model:-unknown}"
printf '          To change one, tell your coding agent which model you want;\n'
printf '          it edits spec/pi-target-state.md and has Pi re-apply it.\n'
if [ "$FAIL" -eq 0 ] && [ "$DO_MODELS" -eq 0 ]; then
  printf '\n  Structure and egress look right, but NO COMPLETION WAS MADE.\n'
  printf '  A gateway can be up and still have a dead model path. Run with\n'
  printf '  --models before reporting this build as working.\n'
fi
[ "$FAIL" -eq 0 ] || printf '\n  %sVerification failed.%s If a channel is live, confirm its allowlist or disable it.\n' "$R" "$Z"
exit $(( FAIL > 0 ? 1 : 0 ))
