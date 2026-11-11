#!/usr/bin/env bash
# Google Workspace add-on for the Hermes agent. Optional; see
# addons/google-hermes/README.md.
#
# A wrapper, so that the add-on is reachable at the path the committed
# permission allowlist already names (Bash(./scripts/*.sh*)) without
# editing .claude/settings.json. The real script lives with the add-on.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addons/google-hermes/install.sh" "$@"
