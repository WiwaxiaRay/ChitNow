#!/bin/bash
# ChitNow installer — sets up the Mac broker and Claude Code hook.
# Run from the repo root: bash install.sh
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
PLIST_LABEL="com.wangyang.thenow-broker"
PLIST_DST="$HOME/Library/LaunchAgents/$PLIST_LABEL.plist"
HOOKS_DIR="$HOME/.claude/scripts"
SETTINGS="$HOME/.claude/settings.json"

echo "==> ChitNow installer"
echo "    Repo: $REPO"

# ── 1. Python venv ─────────────────────────────────────────────────────────────
echo "==> Setting up Python venv..."
cd "$REPO/broker"
python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
echo "    Done."

# ── 2. Generate config + certs (idempotent) ───────────────────────────────────
echo "==> Generating broker config and TLS cert..."
cd "$REPO/broker"
.venv/bin/python generate_config.py
echo "    Done."

# ── 3. launchd plist ───────────────────────────────────────────────────────────
echo "==> Installing launchd plist..."
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi
sed "s|REPO_PATH|$REPO|g" "$REPO/broker/com.wangyang.thenow-broker.plist" > "$PLIST_DST"
launchctl load "$PLIST_DST"
echo "    Broker started. Logs: $REPO/broker/broker.log"

# ── 4. Hook script ─────────────────────────────────────────────────────────────
echo "==> Installing hook script..."
mkdir -p "$HOOKS_DIR"
cp "$REPO/hooks/thenow_hook.py" "$HOOKS_DIR/thenow_hook.py"
chmod +x "$HOOKS_DIR/thenow_hook.py"
echo "    Hook installed at $HOOKS_DIR/thenow_hook.py"

# ── 5. Claude Code settings.json ──────────────────────────────────────────────
echo "==> Wiring Claude Code PreToolUse hook..."
CONFIG_PATH="$REPO/broker/config.json"
HOOK_CMD="env THENOW_CONFIG_PATH=$CONFIG_PATH $REPO/broker/.venv/bin/python $HOOKS_DIR/thenow_hook.py"

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

# Merge hook entry into settings.json using the correct dict format
python3 - "$SETTINGS" "$HOOK_CMD" <<'PYEOF'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f:
    cfg = json.load(f)
entry = {"matcher": "Bash", "hooks": [{"type": "command", "command": cmd}]}
hooks = cfg.setdefault("hooks", {})
if isinstance(hooks, dict):
    ptu = hooks.setdefault("PreToolUse", [])
    for i, h in enumerate(ptu):
        if "thenow_hook" in str(h):
            ptu[i] = entry
            break
    else:
        ptu.append(entry)
elif isinstance(hooks, list):
    # Legacy flat-list format
    for i, h in enumerate(hooks):
        if "thenow_hook" in str(h):
            hooks[i] = entry
            break
    else:
        hooks.append(entry)
with open(path, "w") as f:
    json.dump(cfg, f, indent=2)
print("    settings.json updated.")
PYEOF

# ── 5. Done ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Install the ChitNow iPhone app via TestFlight or Xcode."
echo "  2. Open https://localhost:8000/pair in your Mac browser."
echo "     (Accept the certificate warning — it is self-signed and local.)"
echo "  3. Scan the QR code in the ChitNow iPhone app to pair."
echo ""
echo "To uninstall: bash uninstall.sh"
