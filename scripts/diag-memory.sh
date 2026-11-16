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

# Shared: pull the JSON out of output that starts with log lines such as
# "[proxy] routing process HTTP traffic ...", cut long strings, print it.
show_json() {
  python3 -c '
import json, re, sys
raw = sys.stdin.read()
m = re.search(r"(?m)^[\[{]", raw)
while m and raw[m.start():m.start()+7] == "[proxy]":
    m = re.compile(r"(?m)^[\[{]").search(raw, m.end())
if not m:
    print("(not JSON) " + raw.strip()[:500]); sys.exit(0)
try:
    d = json.loads(raw[m.start():])
except Exception as e:
    print("(could not parse: %s) %s" % (e, raw[m.start():].strip()[:500])); sys.exit(0)
mode = sys.argv[1] if len(sys.argv) > 1 else "full"
# Anything that carries what the agent remembers is reduced to a count.
# The gateway probe returns its short-term entries WITH snippets, and the
# first version of this script printed them.
PRIVATE = ("snippet", "text", "content")
def cut(x):
    if isinstance(x, dict):
        return {k: ("<%d entries, not shown>" % len(v) if isinstance(v, list) and k.lower().endswith("entries") else cut(v))
                for k, v in x.items() if k not in PRIVATE}
    if isinstance(x, list):  return [cut(v) for v in x[:4]] + (["... %d more" % (len(x) - 4)] if len(x) > 4 else [])
    if isinstance(x, str) and len(x) > 120: return x[:120] + "..."
    return x
if mode == "search":
    res = d.get("results", []) if isinstance(d, dict) else d
    flags = {k: d[k] for k in d if k != "results"} if isinstance(d, dict) else {}
    print("  results=%d  other_fields=%s" % (len(res), json.dumps(cut(flags))))
    for r in res[:5]:
        # where the hit is and how strong -- never the text itself
        print("    %s lines %s-%s score=%.3f keys=%s" % (r.get("path"), r.get("startLine"), r.get("endLine"), r.get("score", 0), sorted(k for k in r if k not in ("snippet","text","content"))))
else:
    print(json.dumps(cut(d), indent=2))
' "$@"
}

echo
echo "== openclaw memory status --json (no --deep: that needs the gateway stopped) =="
g "openclaw memory status --json --agent '$id' 2>&1" | show_json

echo
echo "== gateway probe: doctor.memory.status with probe:true =="
echo "   (the documented way to check the live embedding provider)"
g "openclaw gateway call doctor.memory.status --params '{\"probe\":true}' --json 2>&1" | show_json

echo
echo "== openclaw memory search --json (where the hits are and their scores, never the text) =="
for q in "the" "what does the user prefer" "zzqx-no-such-word-9173"; do
  echo "  query: $q"
  g "openclaw memory search --json --max-results 5 --agent '$id' --query '$q' 2>&1" | show_json search
done
