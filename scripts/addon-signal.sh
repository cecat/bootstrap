#!/usr/bin/env bash
# Signal chat channel for the agents. Optional; see addons/signal/README.md.
#
# A wrapper, so that the add-on is reachable at the path the committed
# permission allowlist already names (Bash(./scripts/*.sh*)) without
# editing .claude/settings.json. The real script lives with the add-on.
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/addons/signal/install.sh" "$@"
