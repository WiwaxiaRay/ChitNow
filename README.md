# ChitNow

Approve AI agent shell commands from your Apple Watch before they execute.

When Claude Code or Codex wants to run a high-risk command (`rm -rf`, `git push --force`, `sudo`, etc.), a hook pauses execution and sends a push notification to your Apple Watch. You tap Approve or Deny — then the agent proceeds or stops.

## How push notifications work

**LAN (always active):** The Mac broker stores requests locally. The iPhone app polls the broker every 5 seconds while foregrounded, and the Watch app polls every 5 seconds while open. No cloud involved.

**Cloudflare relay (recommended for reliability):** A Cloudflare Worker relays a generic wake-up push to your iPhone via Apple APNs. The relay sends only `{"event": "approval_pending"}` — it never receives commands, summaries, broker URLs, or approval decisions. The full command is fetched directly from the LAN broker after the iPhone wakes.

> **Important:** Watch background polling is not guaranteed by watchOS. Without the relay, the Watch app must be open to receive approval requests. With the relay, the iPhone is woken by push and relays the request to the Watch via WatchConnectivity.

> **Codex:** ChitNow only receives commands that Codex routes into PermissionRequest. Install or merge `codex/default.rules.example` to cover recommended high-risk commands. After a 15-second timeout with no Watch response, ChitNow cancels and falls back to Codex's native approval UI.

## Requirements

- macOS (tested on Sequoia / Ventura)
- Python 3.11+
- iPhone with iOS 26.5+
- Apple Watch with watchOS 26.5+
- Same Wi-Fi network as your Mac
- **Optional:** [codexbar](https://github.com/steipete/codexbar) for token/cost display on Watch
- **Optional:** Cloudflare account for relay push delivery

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

To set the relay URL on first installation:
```bash
CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh
```

After installation, install the iPhone app via Xcode, then pair:

```
Open in browser on your Mac: https://localhost:8000/pair
```

> Your browser will show a certificate warning — this is expected. The certificate is self-signed and generated locally on your Mac. Click **Advanced → Proceed to localhost** (Chrome) or **Show Details → visit this website** (Safari).

Scan the QR code in the ChitNow iPhone app to complete pairing.

## Cloudflare relay setup

The Cloudflare relay sends a generic APNs wake-up push when a new approval request is created. It never contains the command or summary.

1. Create a Cloudflare D1 database and Worker (see `relay/README.md`)
2. Set `RELAY_MASTER_SECRET`, `APNS_PRIVATE_KEY`, `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_BUNDLE_ID` as Wrangler secrets
3. Apply the schema: `wrangler d1 execute chitnow-relay --file=relay/schema.sql`
4. Deploy: `cd relay && npm run deploy`
5. Set the relay URL in `broker/config.json`:
   ```json
   {"api_key": "...", "relay_url": "https://your-worker.workers.dev"}
   ```
   Or set it on first install: `CHITNOW_RELAY_URL=https://your-worker.workers.dev bash install.sh`
6. Re-pair (scan QR again) — the iPhone will register with the relay and send credentials to the broker

## Codex hook

Add to `~/.codex/config.toml`, then re-trust in the Codex TUI (`/hooks`):

Run `bash install.sh` — it prints the exact config snippet with absolute paths for your system.

```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
# Replace /ABSOLUTE/PATH with your actual clone path (install.sh prints this for you)
command = "env THENOW_CONFIG_PATH=/ABSOLUTE/PATH/broker/config.json /ABSOLUTE/PATH/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```

## Uninstall

```bash
bash uninstall.sh
```

## Architecture

```
Hook (Claude Code / Codex)
  → high-risk command detected
  → POST /approval-requests to LAN broker (HTTPS, TLS-pinned)
  → blocks on SSE /wait/{id}

Broker sends push (two parallel paths):
  1. Cloudflare relay: POST /v1/push with HMAC auth
       → Worker sends generic APNs "wake up" push (no command data)
       → iPhone wakes → polls /pending-requests → pings Watch
  2. iPhone foreground polling every 5s (always active when app open)
  3. Watch polling every 5s (always active when Watch app open)

User approves/denies on Watch or iPhone notification
  → POST /decision/{id} directly to LAN broker
  → SSE unblocks → hook exits with allow/deny
```

The relay payload sent to Apple APNs contains only:
```json
{"aps": {"alert": {"title": "ChitNow", "body": "New approval request — open ChitNow to review"}, "content-available": 1}, "type": "approval_request"}
```
No commands, summaries, broker URLs, API keys, or fingerprints pass through the relay or Apple's servers.

## Limitations

- **Relay wake-up only.** The Watch receives full request details (command, summary) from the LAN broker directly — never through the relay.
- **LAN required for approvals.** Mac and iPhone/Watch must be on the same network. Approval decisions go directly to the LAN broker.
- **Watch background execution.** watchOS limits background URLSession; the Watch app must be open for reliable delivery without relay.
- **Single user.** One API key shared across clients. No per-device revocation (relay installations can be revoked individually).
- **codexbar is optional.** Token usage, daily cost, and quota rings on Watch require codexbar running on your Mac.

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
| POST | `/relay-credentials` | Update relay installation credentials |

## Logs

```bash
tail -f broker/broker.log
```
