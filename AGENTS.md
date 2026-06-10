# AGENTS.md

This file provides guidance to Codex (codex.com) when working with code in this repository.

## What this project is

**thenow** is an AI agent approval system. When Claude Code or Codex runs a high-risk shell command, a hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Claude/ChatGPT quota and daily cost.

Four components:

1. **`broker/`** — FastAPI Python backend (runs on Mac as a launchd agent)
2. **`thenow/`** — iOS companion app (APNs device registration, notification handling, broker IP relay to Watch)
3. **`thenow Watch App/`** — watchOS app (quota display + inline approve/deny)
4. **`ChitNow Widget ChitNow Widget/`** — watchOS widget extension (watch face complication)

## Build & run

### Broker

```bash
cd broker
# First time
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# Run manually
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000

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

### Hook wiring

The hook script lives at `~/.claude/scripts/thenow_hook.py` (outside this repo). Debug log: `/tmp/thenow_hook_debug.log`.

**Claude Code** — PreToolUse hook wired via `~/.claude/settings.json`.

**Codex** — PermissionRequest hook wired via `~/.codex/config.toml`:
```toml
[[hooks.PermissionRequest]]
matcher = "^Bash$"
[[hooks.PermissionRequest.hooks]]
type = "command"
command = "/path/to/broker/.venv/bin/python ~/.claude/scripts/thenow_hook.py"
timeout = 190
statusMessage = "Waiting for Apple Watch approval..."

[features]
hooks = true
```
High-risk commands (sudo, rm, git push, git reset --hard) are forced into the PermissionRequest flow via `~/.codex/rules/default.rules`. The hook auto-detects the agent by checking whether `transcript_path` contains `.claude`.

Test manually:
```bash
curl -s -X POST http://localhost:8000/approval-requests \
  -H "X-API-Key: dev-key" -H "Content-Type: application/json" \
  -d '{"title":"Test","summary":"test","command":"rm -rf /tmp/x","agent":"claude-code"}'
```

## Architecture

### Request flow

```
Claude Code / Codex
  → thenow_hook.py (PreToolUse / PermissionRequest)
    → POST /approval-requests          # creates DB record, sends APNs push
    → GET  /wait/{id} (SSE)            # blocks until decision or timeout
        PermissionRequest: 15s timeout → falls back to Codex native UI
        PreToolUse:       180s timeout → denies on expiry
iPhone receives push → user long-presses → APPROVE/DENY
  → NotificationDelegate.swift → POST /decision/{id}
Apple Watch polls GET /pending-requests every 5s
  → PendingRequestCard → POST /decision/{id}
```

### Broker (`broker/main.py`)

- SQLite via `aiosqlite` — tables: `devices`, `approval_requests`, `audit_log`
- APNs via `httpx` HTTP/2 + JWT (`PyJWT`). **Production** endpoint (`api.push.apple.com`). Auth key: `AuthKey_ZRLVNRQ23Q.p8`
- APNs JWT protected by `asyncio.Lock` (`_apns_lock`) to prevent concurrent regeneration
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID; orphaned entries cleaned up every 60s in `_ip_monitor`
- `GET /usage` reads codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/claude-v2.json` — daily Claude token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/claude.json` — Claude quota
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota
- `GET /broker-ip` returns `{"url": "http://<mac-lan-ip>:8000"}` — **requires auth** (same `X-API-Key` header)
- `_ip_monitor` background task fires every 60s, pushes new broker URL via APNs on IP change

### iOS app (`thenow/`)

- `thenowApp.swift` — `AppDelegate` registers for APNs, uploads device token to broker; `PhoneSessionManager` activates WCSession and replies to Watch broker-URL requests
- `NotificationDelegate.swift` — handles `APPROVE`/`DENY` action identifiers from `AGENT_APPROVAL` category, POSTs decision to broker
- `BrokerClient.swift` — uses mDNS hostname (`.local`); calls `GET /broker-ip` and pushes current Mac LAN IP to Watch via `WCSession.updateApplicationContext`

### Watch App (`thenow Watch App/`)

- `WatchSessionManager.swift` — `WCSessionDelegate`; all WCSession callbacks dispatch to `DispatchQueue.main` before posting `NotificationCenter` events or writing `UserDefaults` (background-thread safety)
- `WatchBrokerClient.swift` — reads `brokerURL` from `UserDefaults`; `#if targetEnvironment(simulator)` uses `localhost`; caches last successful `/usage` response for offline display
- `ContentView.swift` — `TabView` (tag 0=Claude, tag 1=ChatGPT); new-request detection via `knownRequestIDs: Set<String>` inside `reloadApprovals()` on `MainActor` — fires haptic and navigates tab immediately when new IDs are detected; `dismissedIDs` prevents dismissed cards from reappearing on next poll
- `UsageView.swift` — `WatchPageView` renders concentric rings + pixel mascot + terminal block; `PendingRequestCard` uses `CardCountdown: ObservableObject` (held in `@StateObject`) for a stable 1-second countdown — using `private let Timer` on a struct caused the timer to reset every time the parent re-rendered
- `Models.swift` — `ApprovalRequest`, `UsageStats`, `QuotaInfo`, `UsageResponse`

### Widget (`ChitNow Widget ChitNow Widget/ThenowWidget.swift`)

**Critical**: the Xcode target is `ChitNow Widget ChitNow WidgetExtension`. The directory `thenow Widget/` contains a file that is **not referenced by any target** — always edit `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.

- watchOS complication supporting `.accessoryCircular` and `.accessoryRectangular`
- Separate `ClaudeWidget` and `GPTWidget` structs sharing one `ThenowProvider`
- `#if targetEnvironment(simulator)` → `localhost:8000`; real device → mDNS hostname
- Requires `NSLocalNetworkUsageDescription` + `NSAppTransportSecurity/NSAllowsLocalNetworking` in `ChitNow Widget ChitNow Widget/Info.plist`

### Key constants

| What | Value |
|------|-------|
| APNs Key ID | `ZRLVNRQ23Q` |
| APNs Team ID | `F7PJZAN683` |
| Bundle ID | `com.wangyang.thenow` |
| Widget Bundle ID | `com.wangyang.thenow.watchkitapp.ChitNow-Widget-ChitNow-Widget` |
| APNs env | production (`api.push.apple.com`) |
| Broker port | `8000` |
| Hook timeout (PermissionRequest) | `15s` → falls back to Codex native UI |
| Hook timeout (PreToolUse) | `180s` → deny |
| Watch poll interval | `5s` (approvals), `30s` (usage) |

## Common gotchas

- **Wrong widget file**: `thenow Widget/ThenowWidget.swift` is a dead file not in any build target. The actual widget source is `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.
- **Watch broker URL**: Watch reads `UserDefaults["brokerURL"]` set by iPhone via WatchConnectivity. The fallback IP in `WatchBrokerClient.swift` is last-resort only — after a network change, the Watch recovers within ~60s as the IP monitor detects the change and pushes the new URL.
- **mDNS on watchOS**: `.local` hostnames don't resolve reliably in watchOS `URLSession` — Watch always uses direct IP. mDNS is fine for iOS and widget (iPhone process).
- **APNs BadDeviceToken**: Reopening the iOS app re-registers and uploads a fresh token. Occurs after app reinstall or provisioning changes.
- **APNs provisioning**: Broker uses production APNs endpoint. Xcode direct-install (development profile) requires switching `APNS_HOST` in `broker/main.py` to `https://api.sandbox.push.apple.com`.
- **Codex hook trust**: After editing `~/.codex/config.toml` hooks, re-trust via the `codex` CLI TUI (`/hooks`); the desktop app's panel is read-only.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
- **`/broker-ip` requires auth**: All endpoints except `/health` require `X-API-Key` header — including `/broker-ip` (was unauthenticated before, now fixed).
