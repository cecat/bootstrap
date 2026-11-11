#!/usr/bin/env bash
# Google access for the OpenClaw agent. Optional; see
# addons/google-openclaw/README.md.
#
# A wrapper, so that the add-on is reachable at the path the committed
# permission allowlist already names (Bash(./scripts/*.sh*)) without
# editing .claude/settings.json. The real script lives with the add-on.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addons/google-openclaw/install.sh" "$@"
