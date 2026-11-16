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
# NOT quite read-only, which is why this is a diagnostic and not part of
# verify.sh: OpenClaw records every search as a recall against the entries
# it returns, and the nightly sweep promotes on recall counts. Three
# queries here nudge a handful of entries. Run it when there is a question
# to answer, not on a schedule.
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

# ---------------------------------------------------------------------------
# Is anything being WRITTEN, and is consolidation doing anything?
#
# Search working says the index is alive. It does not say that new memories
# are being recorded, or that the nightly sweep ever promotes one. Names,
# sizes, dates and counters only.
# ---------------------------------------------------------------------------
echo
echo "== OpenClaw: memory files in the workspace (name, bytes, modified) =="
g '
id=$(openclaw agents list --json 2>/dev/null | jq -r ".[0].id // empty")
ws=$(jq -r --arg id "$id" "(.agents.entries[\$id].workspace // .agents.defaults.workspace // empty)" ~/.openclaw/openclaw.json 2>/dev/null); ws="${ws/#\~/$HOME}"
for f in MEMORY.md DREAMS.md; do
  if [ -e "$ws/$f" ]; then stat -c "  %-28n %7s bytes  %y" "$ws/$f" | sed "s|$ws/||; s/\.[0-9]* / /"; else echo "  $f  -- does not exist"; fi
done
if [ -d "$ws/memory" ]; then
  find "$ws/memory" -type f -printf "  %-44P %7s bytes  %TY-%Tm-%Td %TH:%TM\n" 2>/dev/null | sort -k4,5 | tail -25
  echo "  ($(find "$ws/memory" -type f | wc -l) file(s) under memory/)"
else
  echo "  memory/ -- does not exist"
fi
echo
echo "== OpenClaw: hooks that write memory =="
jq -c "{sessionMemoryHook: (.hooks.internal.entries[\"session-memory\"] // .hooks[\"session-memory\"] // \"(not in config: default)\"), memoryFlush: (.agents.defaults.compaction.memoryFlush // \"(default)\")}" ~/.openclaw/openclaw.json 2>/dev/null
openclaw hooks list 2>/dev/null | grep -iE "memory|session" | cut -c1-140 | sed "s/^/  /"
echo
echo "== OpenClaw: the dreaming job and its recent runs =="
row=$(openclaw automations list 2>/dev/null | grep -i dream | head -1); echo "  ${row:0:170}"
jid=$(openclaw automations list --json 2>/dev/null | jq -r "[.. | objects | select((.name // .id // \"\") | tostring | test(\"dream\"; \"i\"))][0].id // empty" 2>/dev/null)
[ -n "$jid" ] && openclaw automations runs "$jid" 2>&1 | head -12 | cut -c1-170 | sed "s/^/  /"
'

echo
echo "== OpenClaw: how close is anything to being promoted? =="
echo "   (deep phase promotes only when minScore, minRecallCount and minUniqueQueries ALL pass)"
g "openclaw gateway call doctor.memory.status --params '{\"probe\":false}' --json 2>&1" | python3 -c '
import json, re, sys, collections
raw = sys.stdin.read()
d = None
for m in re.finditer(r"(?m)^[\[{]", raw):
    if raw[m.start():m.start()+7] == "[proxy]": continue
    try: d = json.loads(raw[m.start():]); break
    except Exception: continue
if not d: print("  (could not read the gateway probe)"); sys.exit(0)
dr = d.get("dreaming", {})
deep = dr.get("phases", {}).get("deep", {})
print("  gates: minScore=%s minRecallCount=%s minUniqueQueries=%s maxAgeDays=%s" % (deep.get("minScore"), deep.get("minRecallCount"), deep.get("minUniqueQueries"), deep.get("maxAgeDays")))
print("  short-term entries=%s  recall signals=%s  daily signals=%s  promoted ever=%s" % (dr.get("shortTermCount"), dr.get("recallSignalCount"), dr.get("dailySignalCount"), dr.get("promotedTotal")))
ents = dr.get("shortTermEntries", [])
hist = collections.Counter(e.get("recallCount", 0) for e in ents)
print("  recallCount among the %d entries the probe returns: %s" % (len(ents), dict(sorted(hist.items()))))
if ents: print("  fields per entry: %s" % sorted(k for k in ents[0] if k != "snippet"))
'

echo
echo "== Hermes: memory files, against their character limits =="
g '
for f in MEMORY.md USER.md; do
  p=~/.hermes/memories/$f
  if [ -e "$p" ]; then printf "  %-10s %5s chars  modified %s\n" "$f" "$(wc -m < "$p")" "$(stat -c %y "$p" | cut -c1-16)"; else echo "  $f -- does not exist"; fi
done
echo "  limits: MEMORY.md 2200, USER.md 1375 (vendor defaults)"
echo
echo "== Hermes: settings that decide whether memory is written =="
for k in memory.memory_enabled memory.user_profile_enabled memory.write_approval memory.nudge_interval memory.provider auxiliary.background_review.enabled auxiliary.background_review.model auxiliary.background_review.max_input_tokens; do
  printf "  %-48s %s\n" "$k" "$(hermes config get $k 2>/dev/null | tr -d "\r" | tail -1 | cut -c1-60)"
done
echo
echo "== Hermes: memory status =="
hermes memory status 2>&1 | head -14 | cut -c1-150 | sed "s/^/  /"
echo
echo "== Hermes: is it being used, and does the background review run? (counts and error lines only) =="
printf "  state.db modified: %s\n" "$(stat -c %y ~/.hermes/state.db 2>/dev/null | cut -c1-16)"
J="journalctl --user -u hermes-gateway.service --no-pager --since -6days"
printf "  journal lines, last 6 days: %s\n" "$($J 2>/dev/null | wc -l)"
printf "  mentioning background review: %s\n" "$($J 2>/dev/null | grep -ciE "background.?review")"
printf "  mentioning the memory tool:   %s\n" "$($J 2>/dev/null | grep -ciE "memory (tool|saved|updated|write)|memory\.(add|replace|remove)")"
echo "  error or warning lines about either (last 6, cut):"
$J 2>/dev/null | grep -iE "background.?review|memory" | grep -iE "error|fail|warn|timeout|exceed|refus" | tail -6 | cut -c1-190 | sed "s/^/    /"
'
