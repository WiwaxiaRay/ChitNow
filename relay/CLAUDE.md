# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
npm test              # run all tests (vitest)
npm run test:watch    # watch mode
npm run type-check    # tsc --noEmit (no test files — tsconfig excludes test/)
npm run dev           # local Wrangler dev server
npm run deploy        # deploy to Cloudflare Workers
```

Run a single test file:
```bash
npx vitest run test/worker.test.ts
```

Apply schema to D1 (initial setup or after schema changes):
```bash
npx wrangler d1 execute chitnow-relay --file=schema.sql
# For existing DBs, add key_version column manually:
# npx wrangler d1 execute chitnow-relay --file=migrations/0002_relay_lifecycle.sql
```

## Architecture

Three source files:

- **`src/auth.ts`** — pure crypto helpers: `hmacSha256Hex`, `sha256Hex`, `safeEqual`, `deriveRelaySecret`, `canonicalMessage`, `parseAuthHeaders`. No D1 access.
- **`src/apns.ts`** — APNs HTTP/2 push via `fetch`. Exports `sendApnsPush` and `GENERIC_PAYLOAD` (the exact payload sent to Apple — no command data).
- **`src/index.ts`** — Worker entry point. All route handlers, `Env` interface, `verifyAuth`, `getMasterSecret`, `activeKeyVersion`.

## Key design decisions

**Derive-on-demand secrets**: `relay_secret = HMAC-SHA256(RELAY_MASTER_SECRET_V{N}, installation_id)`. The Worker never stores plaintext secrets — only `SHA256(relay_secret)` for audit. Keep the previous master-secret version configured during migration; deleting it early invalidates installations that have not rotated.

**Versioned master secrets**: `Env` has `RELAY_MASTER_SECRET_V1`, `RELAY_MASTER_SECRET_V2`, `RELAY_ACTIVE_KEY_VERSION` (default `"1"`). Legacy `RELAY_MASTER_SECRET` is treated as V1 for backward compatibility. `installations.key_version` tracks which version each installation uses. Use `POST /v1/rotate-secret` to migrate an installation to the active version.

**Auth order in `verifyAuth`**: timestamp → load installation (reads `key_version`) → HMAC verify → INSERT nonce. Nonce is consumed **only after** HMAC passes. A failed HMAC never touches the nonce table (prevents timing oracle / nonce pollution).

**Nonce replay prevention**: `used_nonces` has a PRIMARY KEY on `(nonce, installation_id)`. `INSERT` throws on duplicate → Worker catches → returns 409. Stale nonces are cleaned up opportunistically on each push (TTL 900s).

**Registration challenge**: prevents device-token enumeration. Client must get a `challenge_id + nonce` from `GET /v1/challenge` (TTL 5 min, single-use) and present both in `POST /v1/register`. Atomic `UPDATE … WHERE used=0` prevents TOCTOU.

**APNs payload**: `GENERIC_PAYLOAD` contains only title, body, `content-available: 1`, and `type`. No `category` (removed because APPROVE/DENY action buttons can never work without a `request_id` in the payload). The iPhone wakes and polls the LAN broker for actual request details.

## Testing

Tests run in Node.js (`vitest`), not Miniflare. D1 is mocked with `better-sqlite3` via `MockD1Database` in `test/worker.test.ts`. The mock implements the same async API (`prepare/bind/first/run/all`) including PRIMARY KEY constraint throws.

`test/apns.test.ts` and `test/auth.test.ts` use `vi.mock` or direct imports with no DB. `test/worker.test.ts` imports the Worker handler directly and calls it with a `MockD1Database` instance and a mock `Env`.

The `tsconfig.json` excludes `test/` — `@cloudflare/workers-types` conflicts with `better-sqlite3` types, so tests rely on vitest's own type resolution.

## Wrangler secrets to set before deploying

```bash
npx wrangler secret put RELAY_MASTER_SECRET_V1   # openssl rand -hex 32
npx wrangler secret put APNS_PRIVATE_KEY          # contents of AuthKey_XXXX.p8
npx wrangler secret put APNS_KEY_ID               # 10-char key ID
npx wrangler secret put APNS_TEAM_ID              # 10-char team ID
npx wrangler secret put APNS_BUNDLE_ID            # com.wangyang.thenow
# Optional for sandbox:
npx wrangler secret put APNS_ENV                  # "sandbox"
```

`RELAY_ACTIVE_KEY_VERSION` defaults to `"1"` if unset; only needed when rotating to V2.
