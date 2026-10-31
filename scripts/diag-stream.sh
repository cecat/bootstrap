#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Run when an agent cannot reach the model but the gateway looks fine.
#
#   bash scripts/diag-stream.sh [instance]
#
# It varies one thing at a time -- stream length, the proxy setting, the
# model id, request size, which credential names resolve, and what a
# deliberately bad credential does -- so a failure lands on a specific
# cause instead of a theory.
#
# Test the agents' ACTUAL request, not a convenient approximation. Every
# probe that bypasses the proxy or omits the credential can pass while
# every real agent fails.
#
# Already ruled out on this host, do not re-litigate: QEMU slirp on long
# streams, squid (not in the model path at all), the egress phase, request
# size up to 90KB, and the model id form.
#
# Read-only. Prints no secret values, only lengths and whether a name
# resolves.
# ---------------------------------------------------------------------------
set -uo pipefail

INSTANCE="${1:-${AGENTS_VM:-agents}}"
say() { printf '\n\033[1m==>\033[0m %s\n' "$*"; }

gw="$(limactl shell "$INSTANCE" -- sudo cat /etc/agent-sandbox/model-gateway 2>/dev/null | tr -d '\r')"
[ -n "$gw" ] || { echo "no model gateway configured" >&2; exit 1; }

# The egress boundary, probed from the agent user through squid. The web
# must answer and the private network must not: 403 is squid refusing,
# which is the only self-validating answer here. A 000 means nothing was
# listening and proves nothing either way.
say "egress boundary: public web allowed, private network refused"
limactl shell "$INSTANCE" -- bash -lc '
  for t in http://example.com/ http://192.168.5.2/ http://10.0.0.1/ \
           http://172.16.0.1/ http://169.254.169.254/ http://127.0.0.1:8080/; do
    printf "    %-32s " "$t"
    curl -sS -m 8 -o /dev/null -w "%{http_code}\n" --proxy http://127.0.0.1:3128 "$t" 2>/dev/null \
      || echo "(no response)"
  done'

say "which credential names resolve in a plain login shell"
limactl shell "$INSTANCE" -- bash -lc '
  for v in CREDENTIAL ARGO_CREDENTIAL ANTHROPIC_API_KEY OPENROUTER_API_KEY OPENAI_API_KEY; do
    printf "    %-20s %s\n" "$v" "$(eval "printf %s \"\${$v:-}\"" | wc -c | tr -d " ") chars"
  done'

say "what Pi's models.json actually sends as its apiKey"
limactl shell "$INSTANCE" -- bash -lc '
  f=$HOME/.pi/agent/models.json
  raw=$(jq -r "(.providers.argo.apiKey // \"MISSING\")" "$f" 2>/dev/null)
  case "$raw" in
    MISSING) printf "    apiKey: MISSING from providers.argo\n" ;;
    \$*)     name=${raw#\$}; name=${name#\{}; name=${name%\}}
             len=$(eval "printf %s \"\${$name:-}\"" | wc -c | tr -d " ")
             printf "    apiKey is the reference %s\n" "$raw"
             printf "    %s resolves to %s chars in this shell\n" "$name" "$len"
             [ "$len" = "0" ] && printf "    ^^ UNRESOLVED: Pi sends an empty key, which argo-proxy reports as ArgoAuthWarning\n" ;;
    *)       printf "    apiKey is a literal value (%s chars) -- not a SecretRef\n" "$(printf %s "$raw" | wc -c | tr -d " ")" ;;
  esac'

say "does the gateway reject a BAD credential the way it rejected Pi?"
limactl shell "$INSTANCE" -- bash -lc "
  for key in '' 'not-a-real-user'; do
    printf '    x-api-key=%-16s ' \"\${key:-<empty>}\"
    curl -sS --noproxy '*' -m 60 -o /tmp/diag-auth.txt -w 'HTTP %{http_code} ' \
      http://$gw/v1/messages \
      -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
      -H \"x-api-key: \$key\" \
      -d '{\"model\":\"argo:claude-4.5-sonnet\",\"messages\":[{\"role\":\"user\",\"content\":\"say OK\"}],\"max_tokens\":16,\"stream\":true}'
    printf 'exit=%s %s\n' \"\$?\" \"\$(grep -oiE 'argoauthwarning|not registered|error' /tmp/diag-auth.txt | head -1)\"
  done"

say "a LARGE request, as Pi sends (system prompt + tools), not a 50-token one"
limactl shell "$INSTANCE" -- bash -lc "
  python3 -c \"
import json,sys
pad = 'The quick brown fox jumps over the lazy dog. ' * 2000
json.dump({'model':'argo:claude-4.5-sonnet','max_tokens':64,'stream':True,
           'messages':[{'role':'user','content':pad + ' Reply with exactly: BIG_OK'}]}, sys.stdout)
\" > /tmp/diag-big.json
  printf '    request bytes: %s\n' \"\$(wc -c </tmp/diag-big.json)\"
  curl -sS --noproxy '*' -m 180 -N -o /tmp/diag-big-out.txt \
    -w '    HTTP %{http_code} in %{time_total}s\n' \
    http://$gw/v1/messages \
    -H 'Content-Type: application/json' -H 'anthropic-version: 2023-06-01' \
    --data-binary @/tmp/diag-big.json
  printf '    curl exit: %s, message_stop: %s\n' \"\$?\" \"\$(grep -c message_stop /tmp/diag-big-out.txt)\"
  tail -c 200 /tmp/diag-big-out.txt | tr -d '\n'; echo"

say "Pi itself, smallest possible prompt, fresh session"
limactl shell "$INSTANCE" -- bash -lc '
  cd ~/agent-bootstrap 2>/dev/null || cd ~
  timeout 120 pi -p --session-id diag-probe --provider argo \
    --model argo:claude-4.5-sonnet -- "Reply with exactly: PI_OK" 2>&1 | tail -5'

say "done"
