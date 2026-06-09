# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

The broker is a single-file FastAPI service (`main.py`) that intermediates approval requests between AI coding agents (Claude Code / Codex) and an Apple Watch. All logic lives in `main.py` — there are no sub-modules.

## Run & manage

```bash
# First-time setup
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt

# Run directly
.venv/bin/uvicorn main:app --host 0.0.0.0 --port 8000

# Via launchd (auto-starts on login)
launchctl load   ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist
launchctl unload ~/Library/LaunchAgents/com.wangyang.thenow-broker.plist

# Logs
tail -f broker.log

# Quick smoke test
curl -s http://localhost:8000/health
curl -s -H "X-API-Key: dev-key" http://localhost:8000/broker-ip
```

## Key design decisions

**SSE for hook blocking**: `POST /approval-requests` creates a DB record and an in-memory `asyncio.Event`. The hook then calls `GET /wait/{id}` which SSE-streams until the event fires or 180 s elapses. On broker restart all in-memory events are lost, so `init_db()` immediately expires any `pending` rows whose `expires_at` has passed.

**Race-condition-free decisions**: `POST /decision/{id}` uses a single atomic `UPDATE … WHERE status='pending' AND expires_at > now` and checks `cursor.rowcount`. If 0 rows updated it distinguishes 404 / 409 / 410 with a follow-up `SELECT`. This prevents two concurrent approve+deny calls both succeeding.

**APNs JWT**: `_apns_auth_token()` caches the signed JWT for 50 minutes (3000 s) to avoid re-reading the `.p8` key on every push. Token is in-process global; broker restart re-generates it.

**Startup silent push**: `_startup_push()` fires 2 s after startup, resolves the outbound IP via a no-data UDP socket to 8.8.8.8, and sends a `content-available: 1` push with `broker_url` in the payload. The iPhone app handles this in the background and relays the URL to the Watch via WatchConnectivity.

**Usage data**: `GET /usage` reads JSON files written by the [codexbar](https://github.com/steipete/codexbar) menubar app. Four source files, each with a distinct schema — see the inline comments in `main.py`. All reads are wrapped in bare `except Exception` so a missing/malformed file never breaks the response.

## API surface (all require `X-API-Key: dev-key` except `/health` and `/broker-ip`)

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/register-device` | Store iPhone APNs token |
| POST | `/approval-requests` | Create request, send alert push |
| GET  | `/wait/{id}` | SSE — blocks until decision or timeout |
| POST | `/decision/{id}` | Record approve/deny, fire SSE event |
| GET  | `/pending-requests` | List non-expired pending requests |
| GET  | `/usage` | Claude + GPT token/cost/quota summary |
| GET  | `/broker-ip` | Returns `{"url": "http://<mac-ip>:8000"}` |
| GET  | `/health` | Liveness probe |
| GET  | `/audit` | Last 100 audit log entries |

## Files

| File | Purpose |
|------|---------|
| `main.py` | Entire broker — DB, APNs, SSE, routes |
| `broker.db` | SQLite — tables: `devices`, `approval_requests`, `audit_log` |
| `AuthKey_ZRLVNRQ23Q.p8` | APNs ES256 private key — never commit |
| `requirements.txt` | Python deps |

## Gotchas

- `APNS_HOST` is `api.push.apple.com` (production). If the app is installed via Xcode (development provisioning) switch to `api.sandbox.push.apple.com`.
- `API_KEY = "dev-key"` is hardcoded. Fine for local-only use; change before exposing on a shared network.
- The Mac's LAN IP changes on network switches. The startup push and `/broker-ip` derive the current IP dynamically; the Watch App falls back to the hardcoded IP in `WatchBrokerClient.swift` until it receives a WatchConnectivity update from the iPhone.
