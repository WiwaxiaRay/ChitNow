#!/bin/bash
# ChitNow uninstaller
set -euo pipefail

PLIST_LABEL="com.wangyang.thenow-broker"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
HOOKS_DIR="$HOME/.claude/scripts"

echo "==> Uninstalling ChitNow..."

if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "    Broker stopped."
fi
[ -f "$PLIST_DST" ] && rm "$PLIST_DST" && echo "    Removed plist."
[ -f "$HOOKS_DIR/thenow_hook.py" ] && rm "$HOOKS_DIR/thenow_hook.py" && echo "    Removed hook."

echo "==> Done. Repo files untouched — delete the repo folder manually if needed."
