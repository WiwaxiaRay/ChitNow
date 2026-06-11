# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

**ChitNow** (repo: thenow) is an AI agent approval system. When Claude Code or Codex runs a high-risk shell command, a hook pauses execution, sends an APNs push notification, and waits for the user to approve or deny from their Apple Watch. The Watch App also displays Claude/ChatGPT quota and daily cost.

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

### Tests and security checks

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
Commands matching `~/.codex/rules/default.rules` (sudo, rm, git push, git reset --hard, etc.) are routed into the PermissionRequest flow by Codex. The hook then sends all PermissionRequest commands to Watch without additional regex filtering. The hook auto-detects the agent by checking whether `transcript_path` contains `.claude`.

Run `bash install.sh` to install the Claude Code hook and print the exact Codex
hook command with absolute paths. PreToolUse defaults to
`THENOW_APPROVAL_MODE=balanced`, which lets ordinary read-only commands such as
`ls`, `cat`, and `pwd` pass through and intercepts risk-pattern matches. Set
`THENOW_APPROVAL_MODE=strict` to send every Bash command to the Watch.

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
User opens the localhost setup-token URL printed by install.sh
  → broker generates one-time session:
      sid           = random hex 16 bytes
      pairing_token = random hex 32 bytes  (5 min TTL, single-use)
      QR payload v2 = {v:2, sid, pt, url, fp, exp}
                                  ↑
                            pairing token — API key is NOT in the QR
iPhone scans QR → PairingView.swift
  → POST /pair/{sid}/confirm  header: X-Pairing-Token: <pt>
      (TLS pinned using scanned fp)
  → response: {api_key, broker_url, cert_fp}  ← API key returned here
  → stores {brokerURL, apiKey, certFingerprint} in iOS Keychain
  → stores {relayURL, relayInstallationId, relaySecret} in iOS Keychain when relay is configured
  → calls discoverAndShareWithWatch() → WCSession.updateApplicationContext
Watch receives context → stores in App Group UserDefaults (group.com.wangyang.thenow)
Widget reads from same App Group UserDefaults
```

TLS pinning model:
- Hook (httpx): `verify=broker.crt` — uses cert file as trust root, not fingerprint comparison
- iPhone/Watch/Widget: SHA-256 fingerprint comparison in `PinnedSessionDelegate` / `WatchPinnedDelegate`
- On fingerprint mismatch, `PinnedSessionDelegate` posts `Notification.Name.certMismatch` → iOS shows re-pair alert

API Key storage locations: Mac `broker/config.json` (600), iPhone Keychain, Watch/Widget App Group UserDefaults (not Keychain-level protection)

Cert SAN includes localhost + LAN IPs detected via hostname resolution at generation time (not a full network interface enumeration).

### Request flow

```
Hook intercept:
  PreToolUse (Claude Code / Codex):
      balanced (default): only risk-pattern matches are sent to Watch
      strict: every Bash command is sent to Watch
      exit codes: deny=2, allow/pass-through=0
  PermissionRequest (Codex):
      ALL commands entering PermissionRequest are sent to Watch — no regex filter
      exit codes: approve/deny → stdout JSON {behavior:...} + exit 0
                  timeout (15s) → no JSON + exit 0 (falls back to Codex native UI)

  → POST /approval-requests   (TLS: verify=broker.crt as trust root)
  → GET  /wait/{id} (SSE)     blocks until decision or timeout (~185s PreToolUse, 15s PermissionRequest)

Approval routing:
  GET /approval-routing succeeds with watch_approvals_enabled=false
      → Claude Code PreToolUse returns permissionDecision="ask"
      → Codex PermissionRequest exits silently to its native approval UI
  Broker/routing lookup fails → deny by default

Discovery and notification paths run in parallel:

  Relay path (when configured):
      broker → Cloudflare Worker → Apple APNs (generic wake-up only)
      → iPhone AppDelegate.didReceiveRemoteNotification
        → PhoneSessionManager.pingWatchNewRequest()
          → WCSession.sendMessage (immediate if Watch app in foreground)
          → WCSession.transferUserInfo (queued for next Watch app activation)

  iPhone foreground polling (always active when app is foregrounded):
      every 5s GET /pending-requests → new IDs → pingWatchNewRequest()

  Watch direct polling (always active when Watch app is open):
      every 5s GET /pending-requests → PendingRequestCard

Decision path:
  Apple Watch: PendingRequestCard → POST /decision/{id}
  Sends: {"status": "approved" | "denied"}

IP change recovery:
  Watch fetchPending() failure → requestFreshBrokerURL()
    → WCSession sendMessage → iPhone queries /broker-ip (using current Keychain URL)
    → if Mac IP changed, iPhone Keychain URL is also stale → re-pair needed
```

### Broker (`broker/main.py`)

- SQLite via `aiosqlite` — tables: `approval_requests`, `audit_log`
- Generic wake-up pushes go through `relay_client.py`; no APNs provider key is stored on the Mac
- Relay credentials are stored in `broker/relay_credentials.json` with mode 600
- SSE waiting: in-memory `dict[str, asyncio.Event]` keyed by request ID; orphaned entries cleaned up every 60s in `_ip_monitor`
- `GET /usage` reads codexbar cache files for token/cost data:
  - `~/Library/Caches/codexbar/cost-usage/claude-v2.json` — daily Claude token rows
  - `~/Library/Caches/codexbar/cost-usage/codex-v8.json` — daily GPT token rows
  - `~/Library/Application Support/com.steipete.codexbar/history/claude.json` — Claude quota
  - `~/Library/Application Support/com.steipete.codexbar/openai-dashboard.json` — GPT quota
- `GET /broker-ip` returns `{"url": "https://<mac-lan-ip>:8000"}` — requires auth
- `_ip_monitor` background task cleans expired SSE waiter objects every 60s
- Pairing endpoints: `GET /pair?setup_token=...` (HTML + QR), `POST /pair/{sid}/confirm`, `GET /pair/{sid}/status`
- `GET/PUT /approval-routing` reads and atomically persists the authoritative Watch/native approval route in `config.json`

### Relay (`relay/`)

- `src/index.ts` — Worker routes, HMAC verification, replay prevention, rate limits, registration, revocation, and key-version rotation
- `src/auth.ts` — canonical request signing and crypto helpers
- `src/apns.ts` — APNs provider client; sends only the generic wake-up payload
- D1 stores APNs device tokens and installation lifecycle metadata, never commands or approval decisions
- Apply `schema.sql` for a new D1 database; apply `migrations/0002_relay_lifecycle.sql` once when upgrading an older database

### iOS app (`thenow/`)

- `KeychainHelper.swift` — stores/reads `brokerURL`, `apiKey`, `certFingerprint` from iOS Keychain (`kSecClassGenericPassword`)
- `RelayClient.swift` — registers, updates, revokes, and rotates relay installation credentials; relay secrets remain in iOS Keychain
- `PairingView.swift` — QR scanner (`AVCaptureSession`), parses `PairingPayload` (v2: contains pairing token `pt`, not API key), calls `POST /pair/{sid}/confirm` with `X-Pairing-Token` header, receives `api_key` from response, saves to Keychain
- `BrokerClient.swift` — `PinnedSessionDelegate` pins TLS against stored fingerprint; posts `.certMismatch` notification on mismatch; `discoverAndShareWithWatch()` pushes all three credentials to Watch via `WCSession.updateApplicationContext`
- `ContentView.swift` — switches between `PairingView` / `ActiveView`; shows cert-mismatch alert; `DiagnosticsView` sheet with live health check
- `ContentView.swift` also exposes the Watch approval routing switch; it updates only after the authenticated Broker PUT succeeds
- `thenowApp.swift` — `AppDelegate` registers the APNs token with the relay; `PhoneSessionManager.startPolling()` runs every 5s while app is foregrounded, diffs pending request IDs, and calls `pingWatchNewRequest()` on new IDs

### Watch App (`thenow Watch App/`)

- `WatchSessionManager.swift` — `WCSessionDelegate`; reads `brokerURL`, `apiKey`, `certFingerprint` from incoming context; writes all three to `sharedDefaults` (App Group)
- `WatchBrokerClient.swift` — requires complete paired credentials from `UserDefaults(suiteName: "group.com.wangyang.thenow")`; `WatchPinnedDelegate` pins TLS; paired simulators use `localhost` without bypassing pairing
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
| Bundle ID | `com.wangyang.thenow` |
| Widget Bundle ID | `com.wangyang.thenow.watchkitapp.ChitNow-Widget-ChitNow-Widget` |
| App Group | `group.com.wangyang.thenow` |
| Relay push | generic wake-up only; Worker owns APNs credentials |
| Broker port | `8000` (HTTPS) |
| Hook timeout (PermissionRequest) | `15s` → falls back to Codex UI |
| Hook timeout (PreToolUse) | `180s` → deny |
| Watch poll interval | `5s` (approvals), `30s` (usage) |
| Pairing session TTL | `300s` (5 min), one-time use |

## Common gotchas

- **Wrong widget file**: `thenow Widget/ThenowWidget.swift` is dead. Edit `ChitNow Widget ChitNow Widget/ThenowWidget.swift`.
- **Pairing URL**: plain `https://localhost:8000/pair` is rejected. Use the setup-token URL printed by `install.sh`.
- **Cert regeneration**: running `generate_config.py` or deleting `broker/certs/` creates a new cert with a new fingerprint. All paired clients will get `.certMismatch` and must re-pair by scanning the QR again.
- **App Group entitlements**: Watch App and Widget both require `group.com.wangyang.thenow` in their `.entitlements` files and matching provisioning profiles. Missing entitlement = Widget shows stale/empty data.
- **Watch broker URL**: Watch reads from App Group `UserDefaults["brokerURL"]`. On network failure, Watch asks iPhone for a fresh URL via WCSession. If the Mac IP changed, both may hold a stale URL and re-pairing is usually required.
- **mDNS on watchOS**: `.local` hostnames don't resolve in watchOS `URLSession` — Watch and Widget always use direct IP.
- **Relay APNs environment**: Xcode development installs use sandbox APNs tokens; App Store/TestFlight builds use production tokens. Configure the Worker accordingly.
- **Codex hook trust**: After editing `~/.codex/config.toml`, re-trust via `codex` CLI TUI (`/hooks`); desktop app panel is read-only.
- **Quota data stale**: codexbar must be running on Mac to refresh the JSON files the broker reads.
- **Secrets**: never commit `broker/config.json`, `broker/relay_credentials.json`, `.p8` files, `.dev.vars`, or `.wrangler/`; run `bash scripts/scan_secrets.sh` before release.
- **Native approval fallback**: only explicit `watch_approvals_enabled=false` from the authenticated Broker may fall back to native approval. Broker failure remains deny-by-default.
