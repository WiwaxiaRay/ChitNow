# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**thenow** is an AI agent approval system. When Claude Code or Codex runs a high-risk shell command, a hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Claude/ChatGPT quota and daily cost.

Four components:

1. **`broker/`** — FastAPI Python backend (runs on Mac as a launchd agent)
2. **`thenow/`** — iOS companion app (APNs device registration, notification handling, broker IP relay to Watch)
3. **`thenow Watch App/`** — watchOS app (quota display + inline approve/deny)
4. **`thenow Widget/`** — iOS widget (quick-glance quota display)

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
- **thenow Watch App** — watchOS app (runs on Apple Watch)

Build watchOS for simulator:
```bash
xcodebuild -scheme "thenow Watch App" \
  -destination "platform=watchOS Simulator,arch=arm64,id=<simulator-id>" build
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
High-risk commands (sudo, rm, git push, git reset --hard) are forced into the PermissionRequest flow via `~/.codex/rules/default.rules` using `prefix_rule(..., decision="prompt")`. The hook auto-detects the agent by checking whether `transcript_path` contains `.claude`.

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
    → GET  /wait/{id} (SSE)            # blocks until decision or 180s timeout
iPhone receives push → user long-presses → APPROVE/DENY
  → NotificationDelegate.swift
    → POST /decision/{id}
      → SSE event fires → hook exits allow (approve) or deny
Apple Watch polls GET /pending-requests every 5s
  → inline approve/deny in Watch App → POST /decision/{id}
```

### Broker (`broker/main.py`)

- SQLite via `aiosqlite` — tables: `devices`, `approval_requests`, `audit_log`
- APNs via `httpx` HTTP/2 + JWT (`PyJWT`). **Production** endpoint (`api.push.apple.com`). Auth key: `AuthKey_ZRLVNRQ23Q.p8`
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID
- `GET /usage` reads codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/claude-v2.json` — daily Claude token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/claude.json` — Claude quota (session=5hr window, weekly window)
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota (primaryLimit=5hr, secondaryLimit=weekly)
- `GET /broker-ip` returns `{"url": "http://<mac-lan-ip>:8000"}` (IP resolved dynamically via UDP socket to 8.8.8.8)
- `API_KEY = "dev-key"` — change before exposing on network

### iOS app (`thenow/`)

- `thenowApp.swift` — `AppDelegate` registers for APNs on launch, uploads device token to broker, activates `WCSession`
- `NotificationDelegate.swift` — handles `APPROVE`/`DENY` action identifiers from `AGENT_APPROVAL` notification category, POSTs decision to broker
- `BrokerClient.swift` — uses mDNS hostname (`.local`); also calls `GET /broker-ip` and pushes the current Mac LAN IP to Watch via `WCSession.updateApplicationContext(["brokerURL": ...])`

### Watch App (`thenow Watch App/`)

- `WatchSessionManager.swift` — `WCSessionDelegate`; on activation reads `brokerURL` from application context into `UserDefaults`; on network failure `WatchBrokerClient` calls `requestFreshBrokerURL()` to ask iPhone for an updated IP via `sendMessage`
- `WatchBrokerClient.swift` — reads `brokerURL` from `UserDefaults` (set by WatchSessionManager); falls back to hardcoded IP `172.30.87.117:8000`; simulator uses `localhost`; caches last successful `/usage` response for offline display
- `ContentView.swift` — flat `TabView` (tag 0 = Claude, tag 1 = ChatGPT); auto-navigates to the tab matching an incoming request's agent; two timers: approval poll every 5s, usage poll every 30s
- `Models.swift` — `ApprovalRequest`, `UsageStats`, `QuotaInfo` (with both session and weekly quota fields), `UsageResponse`
- `UsageView.swift` — `WatchPageView(theme:)` renders: concentric activity rings (outer=5hr quota, inner=weekly quota), pixel mascot center, terminal-style block (3 rows: 5-HR countdown, WEEK countdown, TKN+cost); `PendingRequestCard` for inline approve/deny
- `WatchTheme` — color constants for Claude (coral/orange) and ChatGPT (signal green)

### Key constants

| What | Value |
|------|-------|
| APNs Key ID | `ZRLVNRQ23Q` |
| APNs Team ID | `F7PJZAN683` |
| Bundle ID | `com.wangyang.thenow` |
| APNs env | production (`api.push.apple.com`) |
| Broker port | `8000` |
| Request timeout | `180s` |
| Watch IP fallback | `172.30.87.117` (update if WatchConnectivity isn't syncing) |

## Common gotchas

- **Watch IP**: Watch uses `UserDefaults["brokerURL"]` set by iPhone via WatchConnectivity. The hardcoded IP in `WatchBrokerClient.swift` is only a last-resort fallback — update it if the Mac's IP has changed and WatchConnectivity isn't syncing.
- **Broker not found on Watch**: mDNS (`.local`) doesn't reliably resolve on watchOS URLSession — always use direct IP for the Watch target.
- **Codex hook trust**: After editing the hooks section of `~/.codex/config.toml`, run the `codex` CLI TUI and use `/hooks` to re-trust; the desktop app's `/hooks` panel is read-only.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
- **APNs provisioning**: broker uses production APNs endpoint. If the iOS app is signed with a development profile (Xcode direct install), APNs pushes will fail — switch `APNS_HOST` in `broker/main.py` to `https://api.sandbox.push.apple.com` temporarily.
