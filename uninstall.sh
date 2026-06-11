#!/bin/bash
# ChitNow uninstaller
set -euo pipefail

PLIST_LABEL="com.wangyang.thenow-broker"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
HOOKS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"
PURGE_DATA=0

for arg in "$@"; do
    [ "$arg" = "--purge-data" ] && PURGE_DATA=1
done

echo "==> Uninstalling ChitNow..."

# ── Stop and remove launchd agent ─────────────────────────────────────────────
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
    echo "    Broker stopped."
fi
[ -f "$PLIST_DST" ] && rm "$PLIST_DST" && echo "    Removed plist."

# ── Remove hook script ────────────────────────────────────────────────────────
[ -f "$HOOKS_DIR/thenow_hook.py" ] && rm "$HOOKS_DIR/thenow_hook.py" && echo "    Removed hook script."

# ── Remove ChitNow entry from Claude settings.json ────────────────────────────
if [ -f "$SETTINGS" ]; then
    cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"
    python3 - "$SETTINGS" <<'PYEOF'
import json, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
hooks = cfg.get("hooks", {})
if isinstance(hooks, dict):
    ptu = hooks.get("PreToolUse", [])
    before = len(ptu)
    hooks["PreToolUse"] = [h for h in ptu if "thenow_hook" not in str(h)]
    if len(hooks["PreToolUse"]) < before:
        cfg["hooks"] = hooks
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
        print(f"    Removed ChitNow hook from {path}")
    else:
        print(f"    No ChitNow hook found in {path}")
elif isinstance(hooks, list):
    before = len(hooks)
    cfg["hooks"] = [h for h in hooks if "thenow_hook" not in str(h)]
    if len(cfg["hooks"]) < before:
        with open(path, "w") as f:
            json.dump(cfg, f, indent=2)
        print(f"    Removed ChitNow hook from {path}")
PYEOF
fi

# ── Codex config (manual) ─────────────────────────────────────────────────────
echo ""
echo "    Codex hook must be removed manually from ~/.codex/config.toml"
echo "    Remove the [[hooks.PermissionRequest]] block containing thenow_hook.py"

# ── Purge run data (opt-in) ───────────────────────────────────────────────────
if [ "$PURGE_DATA" = "1" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/broker"
    [ -f "$SCRIPT_DIR/broker.db"              ] && rm "$SCRIPT_DIR/broker.db"              && echo "    Removed broker.db"
    [ -f "$SCRIPT_DIR/broker.log"             ] && rm "$SCRIPT_DIR/broker.log"             && echo "    Removed broker.log"
    [ -f "$SCRIPT_DIR/relay_credentials.json" ] && rm "$SCRIPT_DIR/relay_credentials.json" && echo "    Removed relay_credentials.json"
    [ -f "$SCRIPT_DIR/config.json"             ] && rm "$SCRIPT_DIR/config.json"             && echo "    Removed config.json"
    [ -d "$SCRIPT_DIR/certs"                   ] && rm -rf "$SCRIPT_DIR/certs"                && echo "    Removed TLS certificates"
    for legacy_key in "$SCRIPT_DIR"/AuthKey_*.p8; do
        [ -f "$legacy_key" ] && rm "$legacy_key" && echo "    Removed legacy APNs private key"
    done
    echo "    Run data and local credentials purged."
else
    echo ""
    echo "    Run data (broker.db, broker.log) kept."
    echo "    Use --purge-data to delete them and local credentials."
fi

echo ""
echo "==> Done. Repo files untouched — delete the repo folder manually if needed."
