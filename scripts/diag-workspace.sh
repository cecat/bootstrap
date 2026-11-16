#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Did anything touch the agents' identity files, and when?
#
#   ./scripts/diag-workspace.sh [instance]      (default instance: agents)
#
# Each agent owns its SOUL.md and the files beside it; this repo seeds them
# once and must never write them again. When something might have -- an old
# setup.sh re-run on 2026-11-16 wrote a SOUL.md into a directory nothing
# loads -- this answers from two sources that do not depend on anyone's
# account of what they did:
#
#   file times   size and last-modified for every identity file
#   git          OpenClaw's workspace is a git repo it initialises itself,
#                so its log and status say exactly what changed and when
#
# Read-only. Names, sizes, dates and commit subjects -- never contents.
# ---------------------------------------------------------------------------
set -uo pipefail
VM="${1:-${AGENTS_VM:-agents}}"
g() { limactl shell "$VM" -- bash -lc "$1" 2>&1; }
[ "$(limactl list --format '{{.Status}}' "$VM" 2>/dev/null | head -1 || true)" = "Running" ] \
  || { echo "instance '$VM' is not running." >&2; exit 1; }

g '
id=$(openclaw agents list --json 2>/dev/null | jq -r ".[0].id // empty")
ws=$(jq -r --arg id "$id" "(.agents.entries[\$id].workspace // .agents.defaults.workspace // empty)" ~/.openclaw/openclaw.json 2>/dev/null)
ws="${ws/#\~/$HOME}"
echo "now:       $(date "+%F %T %Z")"
echo "agent:     $id"
echo "workspace: $ws"
echo
echo "== OpenClaw identity files (size, last modified) =="
for f in SOUL.md IDENTITY.md USER.md AGENTS.md MEMORY.md TOOLS.md HEARTBEAT.md; do
  [ -e "$ws/$f" ] && stat -c "  %-14n %7s bytes  %y" "$ws/$f" | sed "s|$ws/||; s/\.[0-9]* / /"
done
echo
echo "== Hermes identity files =="
for f in ~/.hermes/SOUL.md ~/.hermes/memories/MEMORY.md ~/.hermes/memories/USER.md; do
  [ -e "$f" ] && stat -c "  %-34n %7s bytes  %y" "$f" | sed "s|$HOME|~|; s/\.[0-9]* / /"
done
echo
echo "== SOUL.md anywhere else under home (vendor templates excluded) =="
find ~ -maxdepth 6 -name SOUL.md ! -path "$ws/SOUL.md" ! -path "$HOME/.hermes/SOUL.md" ! -path "*/node_modules/*" ! -path "$HOME/.hermes/hermes-agent/*" 2>/dev/null | sed "s|$HOME|  ~|" || true
echo
if git -C "$ws" rev-parse --git-dir >/dev/null 2>&1; then
  echo "== workspace git: last 8 commits (date, subject) =="
  git -C "$ws" log -8 --date=format:"%F %T" --format="  %ad  %s" 2>/dev/null | cut -c1-110
  echo
  echo "== workspace git: uncommitted changes to identity files =="
  git -C "$ws" status --porcelain -- SOUL.md IDENTITY.md USER.md AGENTS.md MEMORY.md 2>/dev/null | sed "s/^/  /"
  echo "  (end)"
  echo
  echo "== workspace git: commits touching SOUL.md or IDENTITY.md =="
  git -C "$ws" log -6 --date=format:"%F %T" --format="  %ad  %s" -- SOUL.md IDENTITY.md 2>/dev/null | cut -c1-110
else
  echo "(the workspace is not a git repository)"
fi
'
