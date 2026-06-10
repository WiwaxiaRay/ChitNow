# ChitNow Relay

Cloudflare Worker that forwards generic APNs push notifications for ChitNow.

The Worker **never receives or stores** commands, summaries, cwd, broker URLs, API keys, TLS fingerprints, or approval decisions. It only sends a generic "New approval request" push notification.

## Architecture

```
Mac Broker
  → POST /v1/push  (X-ChitNow-* auth headers + body {"event":"approval_pending"})
  → Worker validates signature, checks timestamp + nonce replay
  → Worker sends generic APNs push to stored device token
  → iPhone wakes up, polls LAN Broker for the actual request details
  → Watch receives full request from LAN broker (never through relay)
```

## Setup (manual steps required)

### 1. Create D1 database

```bash
wrangler d1 create chitnow-relay
# Copy the database_id into wrangler.toml
wrangler d1 execute chitnow-relay --file=schema.sql
```

### 2. Set Worker Secrets

```bash
wrangler secret put RELAY_MASTER_SECRET  # random secret, e.g. openssl rand -hex 32
wrangler secret put APNS_PRIVATE_KEY     # paste contents of AuthKey_XXXX.p8
wrangler secret put APNS_KEY_ID          # e.g. ZRLVNRQ23Q
wrangler secret put APNS_TEAM_ID         # e.g. F7PJZAN683
wrangler secret put APNS_BUNDLE_ID       # e.g. com.wangyang.thenow
```

For sandbox (development): also set `APNS_ENV = sandbox`.

### 3. Deploy

```bash
npm install
npm run deploy
```

### 4. Configure Broker

After deploying, set the relay URL in `broker/config.json`:
```json
{
  "api_key": "...",
  "relay_url": "https://chitnow-relay.<your-subdomain>.workers.dev"
}
```

Or set it on first install: `CHITNOW_RELAY_URL=https://... bash install.sh`

The relay credentials (`installation_id` and `relay_secret`) are populated automatically when the iPhone pairs and registers with the Worker, then sends them to the broker via the pairing flow.

## API

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | none | Liveness check |
| GET | `/v1/challenge` | none | One-time registration challenge |
| POST | `/v1/register` | none (uses challenge) | Register device, returns installation_id + relay_secret |
| POST | `/v1/update-token` | headers | Update APNs device token |
| POST | `/v1/push` | headers | Send generic push notification |
| POST | `/v1/revoke` | headers | Revoke installation |

## Auth (header-based, canonical message)

Authenticated endpoints (`/v1/push`, `/v1/update-token`, `/v1/revoke`) use:

```
canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256(BODY)
signature = HMAC-SHA256(relay_secret, canonical)
```

Headers:
```
X-ChitNow-Installation: <installation_id>
X-ChitNow-Timestamp:    <unix_seconds>
X-ChitNow-Nonce:        <random_hex_min_16_chars>
X-ChitNow-Signature:    <hmac_sha256_hex_64_chars>
```

The `relay_secret` is derived on the Worker as `HMAC-SHA256(RELAY_MASTER_SECRET, installation_id)` — it is never stored. Only the installation_id is stored (with a SHA-256 hash of the relay_secret for audit purposes).

## Push body

```json
{"event": "approval_pending"}
```

The broker sends only this minimal body. All command data stays on the LAN broker.

## APNs payload sent to Apple

```json
{
  "aps": {
    "alert": {"title": "ChitNow", "body": "New approval request — open ChitNow to review"},
    "sound": "default",
    "content-available": 1
  },
  "type": "approval_request"
}
```

No command, summary, broker URL, API key, or fingerprint ever passes through the relay or Apple's servers.

## Security

- Each installation's `relay_secret` is derived on demand: `HMAC-SHA256(RELAY_MASTER_SECRET, installation_id)` — never stored
- All authenticated requests require: valid timestamp (±5 min), valid HMAC, unique nonce (replay rejected with 409)
- Nonce is consumed ONLY after HMAC verification passes
- Rate limited: 30 pushes/hour per installation; 5 registrations/hour per IP
- Registration uses a one-time challenge (`challenge_id` + `nonce`) to prevent enumeration

## Running tests

```bash
npm install
npm test
```

## Free Plan limits

The Worker runs within Cloudflare Free Plan limits:
- 100,000 requests/day
- D1 reads: 5M/day, writes: 100K/day
- Worker CPU: 10ms per request

ChitNow generates ~1 push per approval request. At normal usage this is well within Free Plan limits.
