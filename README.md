# ChitNow

Approve AI agent shell commands from your Apple Watch before they execute.

When Claude Code or Codex wants to run a high-risk command (`rm -rf`, `git push --force`, `sudo`, etc.), a hook pauses execution and sends a notification to your Apple Watch. You tap Approve or Deny — then the agent proceeds or stops.

## Requirements

- macOS (tested on Sequoia / Ventura)
- Python 3.11+
- iPhone with iOS 26.5+
- Apple Watch with watchOS 26.5+
- Same Wi-Fi network as your Mac (LAN-only — no cloud relay)
- **Optional:** [codexbar](https://github.com/steipete/codexbar) for token/cost display on Watch

> **Note:** When the Watch app is open, ChitNow checks for approval requests approximately every 5 seconds. Reliable background alerts require APNs — see [APNs Setup](#apns-setup) to configure your own Apple Developer account.

## Install

```bash
git clone https://github.com/WiwaxiaRay/thenow
cd thenow
bash install.sh
```

`install.sh` does the following:
1. Creates Python venv and installs broker dependencies
2. Installs and starts the broker as a launchd agent (auto-starts on login)
3. Copies the hook script to `~/.claude/scripts/`
4. Adds the PreToolUse hook entry to `~/.claude/settings.json`

After installation, install the iPhone app via Xcode, then pair:

```
Open in browser on your Mac: https://localhost:8000/pair
```

> Your browser will show a certificate warning — this is expected. The certificate is self-signed and generated locally on your Mac. Click **Advanced → Proceed to localhost** (Chrome) or **Show Details → visit this website** (Safari).

Scan the QR code in the ChitNow iPhone app to complete pairing.

## Codex hook

Add to `~/.codex/config.toml`, then re-trust in the Codex TUI (`/hooks`):

Run `bash install.sh` — it prints the exact config snippet with absolute paths for your system. Paste the output into `~/.codex/config.toml`, then run `/hooks` in the Codex TUI to re-trust.

```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
# Replace /ABSOLUTE/PATH with your actual clone path (install.sh prints this for you)
command = "env THENOW_CONFIG_PATH=/ABSOLUTE/PATH/thenow/broker/config.json /ABSOLUTE/PATH/thenow/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```

## Uninstall

```bash
bash uninstall.sh
```

## APNs Setup

Without APNs, approvals arrive within 5 seconds via polling — fully functional, just not instant.

For instant vibration push notifications, you need an Apple Developer account:

1. Create an APNs key in [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Keys → Keys → + → Apple Push Notifications service (APNs)
2. Download the `.p8` key file, note the Key ID and Team ID
3. Place the key at `broker/AuthKey_<KEYID>.p8`
4. Update `broker/main.py`:
   ```python
   APNS_KEY_ID  = "<your-key-id>"
   APNS_TEAM_ID = "<your-team-id>"
   APNS_KEY_PATH = os.path.join(_DIR, "AuthKey_<your-key-id>.p8")
   ```
5. Update `thenow.xcodeproj`: set your Development Team and Bundle ID throughout
6. Rebuild and reinstall the app

## Limitations

- **LAN only.** Mac and iPhone/Watch must be on the same network. IP changes (switching Wi-Fi, VPN) may require re-pairing.
- **Single user.** The broker uses one API key shared across all clients. No per-device revocation.
- **APNs push body contains command summaries.** If APNs is configured, the command title and summary pass through Apple's APNs servers. The broker and all decisions remain local.
- **codexbar is optional.** Token usage, daily cost, and quota rings on the Watch require codexbar running on your Mac. The approval system works without it.

## Broker API

All endpoints except `/health` require `X-API-Key` header.

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness probe |
| POST | `/register-device` | Store iPhone APNs token |
| POST | `/approval-requests` | Create request, send push |
| GET | `/wait/{id}` | SSE — blocks until decision or 180s |
| POST | `/decision/{id}` | Record approve/deny |
| GET | `/pending-requests` | List non-expired pending requests |
| GET | `/usage` | Claude + GPT token/cost summary (requires codexbar) |
| GET | `/broker-ip` | Returns current HTTPS broker URL |
| GET | `/pair` | Pairing page (localhost only) |
| GET | `/audit` | Last 100 audit entries |

## Logs

```bash
tail -f broker/broker.log
```
