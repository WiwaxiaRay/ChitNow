# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**ChitNow** (repo: thenow) is an AI agent approval system. When Claude Code or Codex runs a high-risk shell command, a hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Claude/ChatGPT quota and daily cost.

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

# Run via run.sh (generates config + certs if missing, then starts uvicorn with TLS)
bash run.sh

# Managed by launchd (auto-starts on login, KeepAlive=true)
launchctl load ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
launchctl unload ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
# Logs: broker/broker.log
```

`run.sh` calls `generate_config.py` (idempotent) which creates:
- `config.json` — random 64-char hex API key
- `certs/broker.key` + `certs/broker.crt` — self-signed P-256 cert (SAN includes all LAN IPs)
- `certs/fingerprint.txt` — SHA-256 cert fingerprint for pinning

Both files are gitignored. The broker serves **HTTPS only** on port 8000.

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

The hook reads `broker/config.json` for the API key and uses `broker/certs/broker.crt` as the TLS verification cert (`verify=CERT_PATH` in httpx).

Test manually (read API key from config.json first):
```bash
KEY=$(python3 -c "import json; print(json.load(open('broker/config.json'))['api_key'])")
curl -sk -X POST https://localhost:8000/approval-requests \
  -H "X-API-Key: $KEY" -H "Content-Type: application/json" \
  -d '{"title":"Test","summary":"test","command":"rm -rf /tmp/x","agent":"claude-code"}'
```

## Architecture

### Security model

The broker uses **HTTPS + self-signed cert + cert pinning**. The pairing flow distributes credentials to the iPhone:

```
User opens https://localhost:8000/pair in browser
  → broker generates one-time session {sid, key, url, fp, exp}
  → QR code encodes the JSON payload
iPhone scans QR → PairingView.swift
  → POST /pair/{sid}/confirm (using PinnedSessionDelegate with scanned fp)
  → stores {brokerURL, apiKey, certFingerprint} in iOS Keychain
  → calls discoverAndShareWithWatch() → WCSession.updateApplicationContext
Watch receives context → stores in App Group UserDefaults (group.com.wangyang.thenow)
Widget reads from same App Group UserDefaults
```

All clients (iOS, Watch, Widget, hook) pin to the cert fingerprint. On fingerprint mismatch, `PinnedSessionDelegate` posts `Notification.Name.certMismatch` → iOS shows re-pair alert.

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
- APNs via `httpx` HTTP/2 + JWT (`PyJWT`). Endpoint controlled by `THENOW_APNS_ENV` env var: `sandbox` → `api.sandbox.push.apple.com`, `production` (default in launchd plist) → `api.push.apple.com`. Auth key: `AuthKey_ZRLVNRQ23Q.p8`
- APNs JWT protected by `asyncio.Lock` (`_apns_lock`) to prevent concurrent regeneration
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID; orphaned entries cleaned up every 60s in `_ip_monitor`
- `GET /usage` reads codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/claude-v2.json` — daily Claude token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/claude.json` — Claude quota
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota
- `GET /broker-ip` returns `{"url": "https://<mac-lan-ip>:8000"}` — requires auth
- `_ip_monitor` background task fires every 60s, pushes new broker URL via APNs on IP change
- Pairing endpoints: `GET /pair` (HTML + QR), `POST /pair/{sid}/confirm`, `GET /pair/{sid}/status`

### iOS app (`thenow/`)

- `KeychainHelper.swift` — stores/reads `brokerURL`, `apiKey`, `certFingerprint` from iOS Keychain (`kSecClassGenericPassword`)
- `PairingView.swift` — QR scanner (`AVCaptureSession`), parses `PairingPayload`, calls `POST /pair/{sid}/confirm`, saves to Keychain on success
- `BrokerClient.swift` — `PinnedSessionDelegate` pins TLS against stored fingerprint; posts `.certMismatch` notification on mismatch; `discoverAndShareWithWatch()` pushes all three credentials to Watch via `WCSession.updateApplicationContext`
- `ContentView.swift` — switches between `PairingView` / `ActiveView`; shows cert-mismatch alert; `DiagnosticsView` sheet with live health check
- `thenowApp.swift` — `AppDelegate` registers for APNs; `pingWatchNewRequest()` calls both `sendMessage` (foreground) and `transferUserInfo` (background-queued) for reliable Watch delivery

### Watch App (`thenow Watch App/`)

- `WatchSessionManager.swift` — `WCSessionDelegate`; reads `brokerURL`, `apiKey`, `certFingerprint` from incoming context; writes all three to `sharedDefaults` (App Group)
- `WatchBrokerClient.swift` — reads credentials from `UserDefaults(suiteName: "group.com.wangyang.thenow")`; `WatchPinnedDelegate` pins TLS; `#if targetEnvironment(simulator)` uses `localhost`
- `ContentView.swift` — `TabView` (tag 0=Claude, tag 1=ChatGPT); new-request detection via `knownRequestIDs: Set<String>`; `dismissedIDs` prevents reappearing cards
- `UsageView.swift` — `PendingRequestCard` uses `CardCountdown: ObservableObject` (`@StateObject`) for stable countdown — struct-level Timer resets on re-render

### Widget (`ChitNow Widget ChitNow Widget/ThenowWidget.swift`)

**Critical**: always edit `ChitNow Widget ChitNow Widget/ThenowWidget.swift`. The directory `thenow Widget/` contains a dead file not in any build target.

- Reads `brokerURL`, `apiKey`, `certFingerprint` from `UserDefaults(suiteName: "group.com.wangyang.thenow")` (App Group shared with Watch App)
- `WidgetPinnedDelegate` pins TLS; `makePinnedSession()` returns pinned session when fingerprint is available
- `.accessoryCircular` and `.accessoryRectangular` complications; separate `ClaudeWidget` / `GPTWidget` sharing one `ThenowProvider`

### Key constants

| What | Value |
|------|-------|
| APNs Key ID | `ZRLVNRQ23Q` |
| APNs Team ID | `F7PJZAN683` |
| Bundle ID | `com.wangyang.thenow` |
| Widget Bundle ID | `com.wangyang.thenow.watchkitapp.ChitNow-Widget-ChitNow-Widget` |
| App Group | `group.com.wangyang.thenow` |
| APNs env | `THENOW_APNS_ENV` — `production` in launchd plist |
| Broker port | `8000` (HTTPS) |
| Hook timeout (PermissionRequest) | `15s` → falls back to Codex UI |
| Hook timeout (PreToolUse) | `180s` → deny |
| Watch poll interval | `5s` (approvals), `30s` (usage) |
| Pairing session TTL | `300s` (5 min), one-time use |

## Common gotchas

- **Wrong widget file**: `thenow Widget/ThenowWidget.swift` is dead. Edit `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.
- **APNs env**: launchd plist sets `THENOW_APNS_ENV=production`. Xcode direct-install (development profile) gets sandbox tokens — switch to `sandbox` or the push will fail with BadDeviceToken.
- **Cert regeneration**: running `generate_config.py` or deleting `broker/certs/` creates a new cert with a new fingerprint. All paired clients will get `.certMismatch` and must re-pair by scanning the QR again.
- **App Group entitlements**: Watch App and Widget both require `group.com.wangyang.thenow` in their `.entitlements` files and matching provisioning profiles. Missing entitlement = Widget shows stale/empty data.
- **Watch broker URL**: Watch reads from App Group `UserDefaults["brokerURL"]`. Fallback IP in `WatchBrokerClient.swift` is last-resort — recovers within ~60s via IP monitor push.
- **mDNS on watchOS**: `.local` hostnames don't resolve in watchOS `URLSession` — Watch and Widget always use direct IP.
- **Codex hook trust**: After editing `~/.codex/config.toml`, re-trust via `codex` CLI TUI (`/hooks`); desktop app panel is read-only.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
