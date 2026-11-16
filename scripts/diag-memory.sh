#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Is OpenClaw's memory actually working, or only configured?
#
#   ./scripts/diag-memory.sh [instance]      (default instance: agents)
#
# OpenClaw's memory fails silently, and has done so repeatedly: a provider
# with no key, an index that stops while the session hook keeps writing
# files, a setting reverted by an old script. Every one of those leaves the
# configuration looking plausible. This asks the product itself, the way
# its documentation says to:
#
#   openclaw memory status --deep   "Check vector-store, embedding-provider,
#                                    and semantic-search readiness"
#   openclaw memory search --json   reports stale/warning/action when the
#                                   results cannot be trusted
#
# Read-only. --deep makes a provider call, so it costs one embedding.
#
# It prints the SHAPE of the answers and their counts, never the contents:
# what an agent remembers is the user's, and this output gets pasted into
# reports. Search results are reduced to how many there were.
# ---------------------------------------------------------------------------
set -uo pipefail

VM="${1:-${AGENTS_VM:-agents}}"
g() { limactl shell "$VM" -- bash -lc "$1" 2>&1; }

[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null | head -1 || true)" = "Running" ] \
  || { echo "instance '$VM' is not running." >&2; exit 1; }

id="$(g 'openclaw agents list --json 2>/dev/null | jq -r ".[0].id // empty"' | tr -dc 'A-Za-z0-9._-')"
[ -n "$id" ] || { echo "could not read the agent id from openclaw agents list." >&2; exit 1; }
echo "agent: $id"

echo
echo "== configured (openclaw.json) =="
g 'jq -c "{provider: .memory.search.provider, model: (.memory.search.remote.model // .memory.search.model // null), baseUrl: (.memory.search.remote.baseUrl // null), apiKeyIsRef: ((.memory.search.remote.apiKey|type) == \"object\")}" ~/.openclaw/openclaw.json'

echo
echo "== openclaw memory status --deep --json (strings over 120 chars cut) =="
g "openclaw memory status --deep --json --agent '$id' 2>&1" | python3 -c '
import json, sys
raw = sys.stdin.read()
start = min([i for i in (raw.find("["), raw.find("{")) if i >= 0] or [-1])
if start < 0:
    print("(not JSON) " + raw.strip()[:600]); sys.exit(0)
try:
    d = json.loads(raw[start:])
except Exception as e:
    print("(could not parse: %s) %s" % (e, raw.strip()[:600])); sys.exit(0)
def cut(x):
    if isinstance(x, dict):  return {k: cut(v) for k, v in x.items()}
    if isinstance(x, list):  return [cut(v) for v in x[:5]] + (["... %d more" % (len(x) - 5)] if len(x) > 5 else [])
    if isinstance(x, str) and len(x) > 120: return x[:120] + "..."
    return x
print(json.dumps(cut(d), indent=2))
'

echo
echo "== openclaw memory search --json (counts and flags only) =="
for q in "the" "meeting"; do
  g "openclaw memory search --json --max-results 5 --agent '$id' --query '$q' 2>&1" | python3 -c '
import json, sys
q = sys.argv[1]
raw = sys.stdin.read()
start = min([i for i in (raw.find("["), raw.find("{")) if i >= 0] or [-1])
try:
    d = json.loads(raw[start:]) if start >= 0 else None
except Exception:
    d = None
if d is None:
    print("  %-10s (not JSON) %s" % (q, raw.strip()[:200])); sys.exit(0)
res = d.get("results", d) if isinstance(d, dict) else d
n = len(res) if isinstance(res, list) else "?"
flags = {k: d.get(k) for k in ("stale", "warning", "action", "mode", "provider") if isinstance(d, dict) and k in d}
keys = sorted(res[0].keys()) if isinstance(res, list) and res and isinstance(res[0], dict) else []
scores = [round(r.get("score", 0), 3) for r in res[:5]] if keys and "score" in keys else []
print("  %-10s results=%s flags=%s result_keys=%s scores=%s" % (q, n, flags, keys, scores))
' "$q"
done
