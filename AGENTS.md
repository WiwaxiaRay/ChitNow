# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this project is

**thenow** is an AI agent approval system. When Codex or Codex runs a high-risk shell command, a PreToolUse hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Codex/ChatGPT quota and daily cost.

Three components:

1. **`broker/`** — FastAPI Python backend (runs on Mac as a launchd agent)
2. **`thenow/`** — iOS companion app (APNs device registration, notification handling)
3. **`thenow Watch App/`** — watchOS app (quota display + inline approve/deny)

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

### Codex hook

The PreToolUse hook lives at `~/.Codex/scripts/thenow_hook.py` (outside this repo). It's wired via `~/.Codex/settings.json`. Set `THENOW_AGENT=codex` in Codex environment to tag requests as GPT/Codex.

Test manually:
```bash
curl -s -X POST http://localhost:8000/approval-requests \
  -H "X-API-Key: dev-key" -H "Content-Type: application/json" \
  -d '{"title":"Test","summary":"test","command":"rm -rf /tmp/x","agent":"Codex"}'
```

## Architecture

### Request flow

```
Codex / Codex
  → thenow_hook.py (PreToolUse)
    → POST /approval-requests          # creates DB record, sends APNs push
    → GET  /wait/{id} (SSE)            # blocks until decision or 180s timeout
iPhone receives push → user long-presses → APPROVE/DENY
  → NotificationDelegate.swift
    → POST /decision/{id}
      → SSE event fires → hook exits 0 (approve) or 1 (deny)
Apple Watch polls GET /pending-requests every 5s
  → inline approve/deny in Watch App → POST /decision/{id}
```

### Broker (`broker/main.py`)

- SQLite via `aiosqlite` — tables: `devices`, `approval_requests`, `audit_log`
- APNs via `httpx` HTTP/2 + JWT (`PyJWT`). Sandbox endpoint. Auth key: `AuthKey_ZRLVNRQ23Q.p8`
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID
- `GET /usage` reads two codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/Codex-v2.json` — daily Codex token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/Codex.json` — Codex quota (session=5hr window, weekly window)
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota (primaryLimit=5hr, secondaryLimit=weekly)
- `API_KEY = "dev-key"` — change before exposing on network

### iOS app (`thenow/`)

- `thenowApp.swift` — `AppDelegate` registers for APNs on launch, uploads device token to broker
- `NotificationDelegate.swift` — handles `APPROVE`/`DENY` action identifiers from `AGENT_APPROVAL` notification category, POSTs decision to broker
- `BrokerClient.swift` — uses mDNS hostname (`.local`) which works on iOS

### Watch App (`thenow Watch App/`)

- `thenowApp.swift` — wraps `ContentView` in `NavigationStack`
- `ContentView.swift` — flat `TabView` (tag 0 = Codex, tag 1 = ChatGPT); auto-navigates to the tab matching an incoming request's agent; two timers: approval poll every 5s, usage poll every 30s
- `WatchBrokerClient.swift` — uses **direct IP** `192.168.0.227:8000` (not `.local` — mDNS is unreliable on watchOS); simulator uses `localhost`
- `Models.swift` — `ApprovalRequest`, `UsageStats`, `QuotaInfo` (with both session and weekly quota fields), `UsageResponse`
- `UsageView.swift` — `WatchPageView(theme:)` renders: concentric activity rings (outer=5hr quota, inner=weekly quota), pixel mascot center, terminal-style block (3 rows: 5-HR countdown, WEEK countdown, TKN+cost); `PendingRequestCard` for inline approve/deny
- `WatchTheme` — color constants for Codex (coral/orange) and ChatGPT (signal green)

### Key constants

| What | Value |
|------|-------|
| APNs Key ID | `ZRLVNRQ23Q` |
| APNs Team ID | `F7PJZAN683` |
| Bundle ID | `com.wangyang.thenow` |
| APNs env | sandbox (`api.sandbox.push.apple.com`) |
| Broker port | `8000` |
| Request timeout | `180s` |
| Watch IP | `192.168.0.227` (update if network changes) |

## Common gotchas

- **Watch IP hardcoded**: If the Mac's IP changes, update `WatchBrokerClient.swift` line with `192.168.0.227`.
- **APNs sandbox**: Currently using sandbox endpoint. Switch to `api.push.apple.com` for production.
- **Broker not found on Watch**: mDNS (`.local`) doesn't reliably resolve on watchOS URLSession — always use direct IP for the Watch target.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
