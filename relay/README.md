# ChitNow Relay

Cloudflare Worker that forwards generic APNs push notifications for ChitNow.

The Worker **never receives or stores** commands, summaries, cwd, broker URLs, API keys, TLS fingerprints, or approval decisions. It only sends a generic "New approval request" push notification.

## Architecture

```
Mac Broker
  → POST /v1/push  (installation_id + HMAC-SHA256 + timestamp + nonce)
  → Worker validates credentials, rate-limit, nonce replay
  → Worker sends generic APNs push to stored device token
  → iPhone wakes up, polls LAN Broker for the actual request
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
wrangler secret put APNS_PRIVATE_KEY    # paste contents of AuthKey_XXXX.p8
wrangler secret put APNS_KEY_ID         # e.g. ZRLVNRQ23Q
wrangler secret put APNS_TEAM_ID        # e.g. F7PJZAN683
wrangler secret put APNS_BUNDLE_ID      # e.g. com.wangyang.thenow
```

For sandbox (development): also set `APNS_ENV = sandbox`.

### 3. Deploy

```bash
npm install
npm run deploy
```

### 4. Configure Broker

After deploying, update `broker/config.json` with:
```json
{
  "api_key": "...",
  "relay_url": "https://chitnow-relay.<your-subdomain>.workers.dev",
  "relay_installation_id": "...",
  "relay_secret": "..."
}
```

These are populated automatically when the iPhone pairs and registers with the Worker.

## API

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Liveness check |
| GET | `/v1/challenge` | One-time registration challenge |
| POST | `/v1/installations/register` | Register device, get installation_id + relay_secret |
| POST | `/v1/installations/update-token` | Update APNs device token |
| POST | `/v1/push` | Send generic push notification |
| POST | `/v1/installations/revoke` | Revoke installation |

## Security

- Each installation has an independent 32-byte relay secret (stored as SHA-256 hash)
- Push requests require HMAC-SHA256 signature + timestamp + one-time nonce
- Rate limited: 30 pushes/hour per installation; 5 registrations/hour per IP
- Generic APNs payload only — no command data ever reaches Cloudflare or Apple servers
- App Attest integration boundary reserved at `/v1/installations/register`

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
