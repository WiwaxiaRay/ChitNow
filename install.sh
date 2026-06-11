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

# ── 0. Python version check ────────────────────────────────────────────────────
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(python3 -c 'import sys; print(sys.version_info.major)')
PYTHON_MINOR=$(python3 -c 'import sys; print(sys.version_info.minor)')
if [ "$PYTHON_MAJOR" -lt 3 ] || { [ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 11 ]; }; then
    echo "ERROR: Python 3.11+ required (found $PYTHON_VERSION)"
    exit 1
fi
echo "    Python $PYTHON_VERSION OK"

# ── 1. Python venv ─────────────────────────────────────────────────────────────
echo "==> Setting up Python venv..."
cd "$REPO/broker"
python3 -m venv .venv
.venv/bin/pip install -q -r requirements.txt
echo "    Done."

# ── 2. Generate config + certs (idempotent) ───────────────────────────────────
echo "==> Generating broker config and TLS cert..."
.venv/bin/python generate_config.py
echo "    Done."

# ── 3. launchd plist ───────────────────────────────────────────────────────────
echo "==> Installing launchd plist..."
mkdir -p "$(dirname "$PLIST_DST")"   # ~/Library/LaunchAgents may not exist on fresh macOS
if launchctl list "$PLIST_LABEL" &>/dev/null; then
    launchctl unload "$PLIST_DST" 2>/dev/null || true
fi
sed "s|REPO_PATH|$REPO|g" "$REPO/broker/com.wangyang.thenow-broker.plist" > "$PLIST_DST"
launchctl load "$PLIST_DST"
echo "    Broker started. Logs: $REPO/broker/broker.log"

# ── 4. Health check ────────────────────────────────────────────────────────────
echo "==> Checking broker health..."
BROKER_HEALTHY=0
for _ in {1..10}; do
    if curl -sk --max-time 2 https://localhost:8000/health >/dev/null; then
        BROKER_HEALTHY=1
        break
    fi
    sleep 1
done
if [ "$BROKER_HEALTHY" -ne 1 ]; then
    echo "ERROR: Broker failed to start. Check: $REPO/broker/broker.log"
    exit 1
fi
echo "    Broker healthy."

# ── 5. Hook script ─────────────────────────────────────────────────────────────
echo "==> Installing hook script..."
mkdir -p "$HOOKS_DIR"
cp "$REPO/hooks/thenow_hook.py" "$HOOKS_DIR/thenow_hook.py"
chmod +x "$HOOKS_DIR/thenow_hook.py"
echo "    Hook installed at $HOOKS_DIR/thenow_hook.py"

# ── 6. Claude Code settings.json ──────────────────────────────────────────────
echo "==> Wiring Claude Code PreToolUse hook..."
CONFIG_PATH="$REPO/broker/config.json"
HOOK_CMD=$(python3 "$REPO/scripts/generate_hook_command.py" \
    "$CONFIG_PATH" "$REPO/broker/.venv/bin/python" "$HOOKS_DIR/thenow_hook.py")

if [ ! -f "$SETTINGS" ]; then
    mkdir -p "$(dirname "$SETTINGS")"
    echo '{}' > "$SETTINGS"
fi

# Validate existing settings.json is valid JSON before touching it
if ! python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$SETTINGS" 2>/dev/null; then
    echo "ERROR: $SETTINGS is not valid JSON. Aborting hook wiring."
    echo "       Fix or delete the file and re-run install.sh."
    exit 1
fi

# Backup settings.json before modification
cp "$SETTINGS" "${SETTINGS}.bak.$(date +%Y%m%d_%H%M%S)"

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
# Verify the result is valid JSON before writing
out = json.dumps(cfg, indent=2)
json.loads(out)   # parse check
with open(path, "w") as f:
    f.write(out)
print("    settings.json updated.")
PYEOF

# ── 7. Done ────────────────────────────────────────────────────────────────────
CODEX_HOOK_CMD_TOML=$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$HOOK_CMD")
PAIRING_BOOTSTRAP_SECRET=$(
    "$REPO/broker/.venv/bin/python" -c \
    'import json,sys; print(json.load(open(sys.argv[1]))["pairing_bootstrap_secret"])' \
    "$CONFIG_PATH"
)
RELAY_URL=$(
    "$REPO/broker/.venv/bin/python" -c \
    'import json,sys; print(json.load(open(sys.argv[1])).get("relay_url",""))' \
    "$CONFIG_PATH"
)

echo ""
echo "==> Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Open https://localhost:8000/pair?setup_token=$PAIRING_BOOTSTRAP_SECRET in your Mac browser."
echo "     (Accept the certificate warning — it is self-signed and local.)"
echo "  2. Scan the QR code in the ChitNow app to pair."
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "  Codex users: add the following to ~/.codex/config.toml"
echo "  then run /hooks in the Codex TUI to re-trust the hook."
echo "─────────────────────────────────────────────────────────────"
echo ""
echo "[[hooks.PermissionRequest]]"
echo "matcher = \"^Bash$\""
echo "[[hooks.PermissionRequest.hooks]]"
echo "type = \"command\""
echo "command = $CODEX_HOOK_CMD_TOML"
echo "timeout = 190"
echo "statusMessage = \"Waiting for Apple Watch approval...\""
echo ""
echo "[features]"
echo "hooks = true"
echo ""
echo "─────────────────────────────────────────────────────────────"
echo "  Codex high-risk rules (optional but recommended):"
echo "  Merge $REPO/codex/default.rules.example"
echo "  into ~/.codex/rules/default.rules, then run /hooks"
echo "  in the Codex TUI to re-trust."
echo "─────────────────────────────────────────────────────────────"
if [ -n "$RELAY_URL" ]; then
    echo "Relay configured: $RELAY_URL"
else
    echo "Relay not configured — foreground polling only."
fi
echo "To uninstall: bash uninstall.sh"
