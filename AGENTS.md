# AGENTS.md

This file provides guidance to Codex (codex.com) when working with code in this repository.

## What this project is

**thenow** is an AI agent approval system. When Claude Code or Codex runs a high-risk shell command, a hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Claude/ChatGPT quota and daily cost.

Five components:

1. **`broker/`** — FastAPI Python backend (runs on Mac as a launchd agent)
2. **`thenow/`** — iOS companion app (pairing, relay registration, notification handling, broker IP relay to Watch)
3. **`thenow Watch App/`** — watchOS app (quota display + inline approve/deny)
4. **`ChitNow Widget ChitNow Widget/`** — watchOS widget extension (watch face complication)
5. **`relay/`** — Cloudflare Worker + D1 relay (generic APNs wake-up pushes only)

## Build & run

### Broker

```bash
cd broker
# First time
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# Run manually with generated config, TLS certs, and restricted permissions
bash run.sh

# Managed by launchd (auto-starts on login, KeepAlive=true)
launchctl load ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
launchctl unload ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
# Logs: broker/broker.log
```

### iOS + watchOS

Open `thenow.xcodeproj` in Xcode. Two schemes:
- **thenow** — iOS companion app (runs on iPhone)
- **thenow Watch App** — watchOS app + widget extension (runs on Apple Watch)

Build watchOS for simulator (list simulators first with `xcrun simctl list devices available`):
```bash
xcodebuild -scheme "thenow Watch App" \
  -destination "platform=watchOS Simulator,id=<simulator-id>" build
```

### Tests and checks

```bash
broker/.venv/bin/pytest broker/tests -q
cd relay && npm test && npm run type-check
cd .. && bash scripts/scan_secrets.sh
```

### Hook wiring

The hook script lives at `~/.claude/scripts/thenow_hook.py` (outside this repo). Debug log: `/tmp/thenow_hook_debug.log`.

**Claude Code** — PreToolUse hook wired via `~/.claude/settings.json`.

**Codex** — PermissionRequest hook wired via `~/.codex/config.toml`:
```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "env THENOW_CONFIG_PATH=/ABSOLUTE/PATH/broker/config.json /ABSOLUTE/PATH/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```
High-risk commands (sudo, rm, git push, git reset --hard) are forced into the PermissionRequest flow via `~/.codex/rules/default.rules`. The hook auto-detects the agent by checking whether `transcript_path` contains `.claude`.

Run `bash install.sh` to install the Claude Code hook and print the exact Codex
hook command with absolute paths. PreToolUse defaults to
`THENOW_APPROVAL_MODE=balanced`, which lets ordinary read-only commands such as
`ls`, `cat`, and `pwd` pass through while intercepting risk-pattern matches.
`strict` sends every Bash command to the Watch. Every Codex PermissionRequest
is sent to the Watch regardless of approval mode.

Test manually (read API key from config.json first):
```bash
KEY=$(python3 -c "import json; print(json.load(open('broker/config.json'))['api_key'])")
curl -sk -X POST https://localhost:8000/approval-requests \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"title":"Test","summary":"test","command":"rm -rf /tmp/x","agent":"claude-code"}'
```

## Architecture

### Request flow

```
Claude Code / Codex
  → thenow_hook.py (PreToolUse / PermissionRequest)
    → POST /approval-requests          # creates DB record, requests generic relay push
    → GET  /wait/{id} (SSE)            # blocks until decision or timeout
        PermissionRequest: 15s timeout → falls back to Codex native UI
        PreToolUse:       180s timeout → denies on expiry
iPhone receives generic relay push → polls LAN broker → PhoneSessionManager pings Watch
Apple Watch polls GET /pending-requests every 5s
  → PendingRequestCard → POST /decision/{id}
```

### Broker (`broker/main.py`)

- SQLite via `aiosqlite` — tables: `approval_requests`, `audit_log`
- Relay push via `relay_client.py`; the broker stores per-installation relay credentials in `relay_credentials.json` (600)
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID; orphaned entries cleaned up every 60s in `_ip_monitor`
- `GET /usage` reads codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/claude-v2.json` — daily Claude token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/claude.json` — Claude quota
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota
- `GET /broker-ip` returns `{"url": "https://<mac-lan-ip>:8000"}` — **requires auth** (same `X-API-Key` header)
- `_ip_monitor` background task cleans expired SSE waiter objects every 60s
- Pairing requires localhost plus `pairing_bootstrap_secret`; the QR contains a 5-minute, single-use pairing token, never the API key
- `GET/PUT /approval-routing` stores the authoritative `watch_approvals_enabled` setting in `config.json`; routing lookup failure must deny by default

### iOS app (`thenow/`)

- `KeychainHelper.swift` — stores broker credentials and relay installation credentials in iOS Keychain
- `RelayClient.swift` — registers/updates/revokes/rotates the iPhone relay installation
- `thenowApp.swift` — `AppDelegate` registers the APNs token with the relay; `PhoneSessionManager` activates WCSession, polls while foregrounded, and replies to Watch broker-URL requests
- `NotificationDelegate.swift` — presents relay notifications while the app is foregrounded
- `BrokerClient.swift` — uses the pinned HTTPS broker URL saved during pairing; calls `GET /broker-ip` and pushes the current direct-IP URL to Watch via `WCSession.updateApplicationContext`

### Watch App (`thenow Watch App/`)

- `WatchSessionManager.swift` — `WCSessionDelegate`; all WCSession callbacks dispatch to `DispatchQueue.main` before posting `NotificationCenter` events or writing `UserDefaults` (background-thread safety)
- `WatchBrokerClient.swift` — requires complete paired credentials from App Group `UserDefaults`, pins TLS, and caches the last successful `/usage` response for offline display. Paired Watch simulators use `localhost` to reach the host Mac but do not bypass pairing.
- `ContentView.swift` — `TabView` (tag 0=Claude, tag 1=ChatGPT); new-request detection via `knownRequestIDs: Set<String>` inside `reloadApprovals()` on `MainActor` — fires haptic and navigates tab immediately when new IDs are detected; `dismissedIDs` prevents dismissed cards from reappearing on next poll
- When Watch approval routing is disabled from iPhone, Watch clears approval cards and stops approval polling while usage/widget updates continue
- `UsageView.swift` — `WatchPageView` renders concentric rings + pixel mascot + terminal block; `PendingRequestCard` uses `CardCountdown: ObservableObject` (held in `@StateObject`) for a stable 1-second countdown — using `private let Timer` on a struct caused the timer to reset every time the parent re-rendered
- `Models.swift` — `ApprovalRequest`, `UsageStats`, `QuotaInfo`, `UsageResponse`

### Widget (`ChitNow Widget ChitNow Widget/ThenowWidget.swift`)

**Critical**: the Xcode target is `ChitNow Widget ChitNow WidgetExtension`. The directory `thenow Widget/` contains a file that is **not referenced by any target** — always edit `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.

- watchOS complication supporting `.accessoryCircular` and `.accessoryRectangular`
- Separate `ClaudeWidget` and `GPTWidget` structs sharing one `ThenowProvider`
- Reads the direct-IP broker URL shared by iPhone; simulator uses `localhost`
- Requires `NSLocalNetworkUsageDescription` + `NSAppTransportSecurity/NSAllowsLocalNetworking` in `ChitNow Widget ChitNow Widget/Info.plist`

### Key constants

| What | Value |
|------|-------|
| Bundle ID | `com.wangyang.thenow` |
| Widget Bundle ID | `com.wangyang.thenow.watchkitapp.ChitNow-Widget-ChitNow-Widget` |
| App Group | `group.com.wangyang.thenow` |
| Relay push | generic wake-up only; Worker owns APNs credentials |
| Broker port | `8000` (HTTPS) |
| Hook timeout (PermissionRequest) | `15s` → falls back to Codex native UI |
| Hook timeout (PreToolUse) | `180s` → deny |
| Watch poll interval | `5s` (approvals), `30s` (usage) |
| Pairing session TTL | `300s`, one-time use |

## Common gotchas

- **Wrong widget file**: `thenow Widget/ThenowWidget.swift` is a dead file not in any build target. The actual widget source is `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.
- **Watch broker URL**: Watch reads `UserDefaults["brokerURL"]` set by iPhone via WatchConnectivity. If the Mac LAN IP changes, re-pairing may be required.
- **Pairing URL**: plain `https://localhost:8000/pair` is intentionally rejected. Use the setup-token URL printed by `install.sh`.
- **mDNS on watchOS**: `.local` hostnames don't resolve reliably in watchOS `URLSession`; Watch and Widget use the direct IP shared by iPhone.
- **Relay APNs environment**: Production and Xcode development builds use different APNs tokens; configure the Worker environment to match the build being tested.
- **Codex hook trust**: After editing `~/.codex/config.toml` hooks, re-trust via the `codex` CLI TUI (`/hooks`); the desktop app's panel is read-only.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
- **Authentication exceptions**: normal Broker API routes, including `/broker-ip`, require `X-API-Key`; pairing routes use setup/pairing tokens, and `/health` is public.
- **Native approval fallback**: only an authenticated Broker response with `watch_approvals_enabled=false` may trigger native Claude Code/Codex approval. Broker/routing failures must deny.
