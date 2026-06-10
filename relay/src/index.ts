/**
 * ChitNow APNs Relay — Cloudflare Worker
 *
 * Sends generic "wake-up" APNs push notifications on behalf of the Mac Broker.
 * The Worker never receives or stores: commands, summaries, cwd, broker URLs,
 * API keys, TLS fingerprints, or approval decisions.
 *
 * Endpoints:
 *   GET  /health
 *   GET  /v1/challenge
 *   POST /v1/register
 *   POST /v1/update-token
 *   POST /v1/push
 *   POST /v1/revoke
 */

import {
  hmacSha256Hex,
  sha256Hex,
  safeEqual,
  nowSecs,
  TIMESTAMP_TOLERANCE_SECS,
  deriveRelaySecret,
  canonicalMessage,
  parseAuthHeaders,
  type AuthHeaders,
} from "./auth";
import { sendApnsPush, type ApnsConfig } from "./apns";

// Rate limits (per installation, sliding window)
const PUSH_RATE_LIMIT      = 30;   // max pushes per window
const PUSH_RATE_WINDOW_SEC = 3600; // 1 hour window

// Registration: max installations per IP to prevent abuse
const REG_RATE_LIMIT_PER_IP  = 5;
const REG_RATE_WINDOW_SEC    = 3600;

export interface Env {
  DB: D1Database;
  // Secrets set via `wrangler secret put`:
  RELAY_MASTER_SECRET: string;
  APNS_PRIVATE_KEY: string;
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_BUNDLE_ID: string;
  // Optional: set to "sandbox" for development builds; defaults to production
  APNS_ENV?: string;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function apnsConfig(env: Env): ApnsConfig {
  return {
    privateKeyPem: env.APNS_PRIVATE_KEY,
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
    bundleId: env.APNS_BUNDLE_ID,
    production: (env.APNS_ENV ?? "production") === "production",
  };
}

// ── GET /health ───────────────────────────────────────────────────────────────

async function handleHealth(env: Env): Promise<Response> {
  const apnsOk = !!(env.APNS_PRIVATE_KEY && env.APNS_KEY_ID && env.APNS_TEAM_ID && env.APNS_BUNDLE_ID);
  return json({ status: "ok", apns_configured: apnsOk });
}

// ── GET /v1/challenge ─────────────────────────────────────────────────────────
// Issues a one-time registration challenge. Required before registering.

async function handleChallenge(_req: Request, env: Env): Promise<Response> {
  const challengeId = crypto.randomUUID();
  const nonce = Array.from(crypto.getRandomValues(new Uint8Array(16)))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
  const now = nowSecs();
  const expiresAt = now + 300; // 5 minutes

  await env.DB.prepare(
    "INSERT INTO reg_challenges (challenge_id, nonce, created_at) VALUES (?,?,?)"
  ).bind(challengeId, nonce, now).run();

  // Clean up expired challenges opportunistically
  await env.DB.prepare("DELETE FROM reg_challenges WHERE created_at < ?")
    .bind(now - 600).run();

  return json({ challenge_id: challengeId, nonce, expires_at: expiresAt });
}

// ── POST /v1/register ─────────────────────────────────────────────────────────

async function handleRegister(req: Request, env: Env): Promise<Response> {
  const ip = req.headers.get("cf-connecting-ip") ?? "unknown";

  // Basic IP-based rate limiting
  const windowStart = nowSecs() - REG_RATE_WINDOW_SEC;
  const recentRegs = await env.DB.prepare(
    "SELECT COUNT(*) as cnt FROM push_log WHERE installation_id=? AND pushed_at > ?",
  ).bind(`_reg_${ip}`, windowStart).first<{ cnt: number }>();
  if ((recentRegs?.cnt ?? 0) >= REG_RATE_LIMIT_PER_IP) {
    return json({ error: "rate_limited" }, 429);
  }

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  if (typeof body !== "object" || body === null) return json({ error: "bad_request" }, 400);
  const b = body as Record<string, unknown>;

  // Validate required fields
  const apnsToken   = b.apns_device_token;
  const challengeId = b.challenge_id;
  const nonce       = b.nonce;
  const environment = b.environment;

  if (typeof apnsToken !== "string" || apnsToken.length < 32) {
    return json({ error: "missing apns_device_token" }, 400);
  }
  if (typeof challengeId !== "string") {
    return json({ error: "missing challenge_id" }, 400);
  }
  if (typeof nonce !== "string") {
    return json({ error: "missing nonce" }, 400);
  }

  // Validate the challenge (must exist, be unused, and be < 5 minutes old)
  const chRow = await env.DB.prepare(
    "SELECT nonce, created_at, used FROM reg_challenges WHERE challenge_id=?",
  ).bind(challengeId).first<{ nonce: string; created_at: number; used: number }>();
  if (!chRow) return json({ error: "invalid_challenge" }, 403);
  if (chRow.used) return json({ error: "challenge_already_used" }, 409);
  if (nowSecs() - chRow.created_at > 300) return json({ error: "challenge_expired" }, 410);

  // Verify nonce matches what was issued
  if (!safeEqual(chRow.nonce, nonce)) {
    return json({ error: "invalid_nonce" }, 403);
  }

  // Atomically mark challenge as used (prevents TOCTOU)
  const updateResult = await env.DB.prepare(
    "UPDATE reg_challenges SET used=1 WHERE challenge_id=? AND used=0"
  ).bind(challengeId).run();
  if (updateResult.meta.changes === 0) {
    return json({ error: "challenge_already_used" }, 409);
  }

  // Generate installation credentials
  const installationId = crypto.randomUUID();
  // relay_secret is derived: HMAC-SHA256(RELAY_MASTER_SECRET, installationId)
  const relaySecret = await deriveRelaySecret(env.RELAY_MASTER_SECRET, installationId);
  const secretHash  = await sha256Hex(relaySecret);
  const now = nowSecs();

  await env.DB.prepare(
    `INSERT INTO installations (installation_id, relay_secret_hash, apns_device_token, created_at, last_seen_at)
     VALUES (?, ?, ?, ?, ?)`,
  ).bind(installationId, secretHash, apnsToken, now, now).run();

  // Track this registration for rate limiting
  await env.DB.prepare("INSERT INTO push_log (installation_id, pushed_at) VALUES (?,?)")
    .bind(`_reg_${ip}`, now).run();

  return json({ installation_id: installationId, relay_secret: relaySecret }, 201);
}

// ── Auth verification (shared) ────────────────────────────────────────────────

/**
 * Verify HMAC-based auth headers for authenticated endpoints.
 * Returns error string on failure, null on success.
 * The authHeaders must already be parsed; bodyText is the raw request body.
 *
 * Order:
 *   1. Timestamp check (fast rejection)
 *   2. Load installation
 *   3. Verify HMAC
 *   4. Atomically insert nonce (prevents replay)
 */
async function verifyAuth(
  authHeaders: AuthHeaders,
  bodyText: string,
  method: string,
  path: string,
  env: Env,
): Promise<string | null> {
  // 1. Timestamp check
  const drift = Math.abs(nowSecs() - authHeaders.timestamp);
  if (drift > TIMESTAMP_TOLERANCE_SECS) return "timestamp_out_of_range";

  // 2. Load installation
  const inst = await env.DB.prepare(
    "SELECT revoked_at FROM installations WHERE installation_id=?",
  ).bind(authHeaders.installationId).first<{ revoked_at: number | null }>();
  if (!inst) return "installation_not_found";
  if (inst.revoked_at !== null) return "installation_revoked";

  // 3. Verify HMAC — derive relay_secret from master secret
  const relaySecret = await deriveRelaySecret(env.RELAY_MASTER_SECRET, authHeaders.installationId);
  const canonical   = await canonicalMessage(method, path, authHeaders.timestamp, authHeaders.nonce, bodyText);
  const expected    = await hmacSha256Hex(relaySecret, canonical);
  if (!safeEqual(expected, authHeaders.signature)) return "invalid_signature";

  // 4. Atomically insert nonce (throw on PRIMARY KEY violation = replayed)
  try {
    await env.DB.prepare(
      "INSERT INTO used_nonces (nonce, installation_id, used_at) VALUES (?,?,?)",
    ).bind(authHeaders.nonce, authHeaders.installationId, nowSecs()).run();
  } catch {
    return "nonce_replayed";
  }

  return null; // auth ok
}

// ── POST /v1/push ─────────────────────────────────────────────────────────────

async function handlePush(req: Request, env: Env): Promise<Response> {
  const authHeaders = parseAuthHeaders(req);
  if (!authHeaders) return json({ error: "invalid_auth" }, 401);

  const bodyText = await req.text();

  const authErr = await verifyAuth(authHeaders, bodyText, "POST", "/v1/push", env);
  if (authErr) {
    const status = (authErr === "nonce_replayed") ? 409 : 401;
    return json({ error: authErr }, status);
  }

  // Verify rate limit for this installation
  const windowStart = nowSecs() - PUSH_RATE_WINDOW_SEC;
  const pushCount = await env.DB.prepare(
    "SELECT COUNT(*) as cnt FROM push_log WHERE installation_id=? AND pushed_at > ?",
  ).bind(authHeaders.installationId, windowStart).first<{ cnt: number }>();
  if ((pushCount?.cnt ?? 0) >= PUSH_RATE_LIMIT) {
    return json({ error: "rate_limited" }, 429);
  }

  // Fetch device token
  const inst = await env.DB.prepare(
    "SELECT apns_device_token FROM installations WHERE installation_id=? AND revoked_at IS NULL",
  ).bind(authHeaders.installationId).first<{ apns_device_token: string }>();
  if (!inst) return json({ error: "installation_not_found" }, 404);

  // Log push attempt before sending
  await env.DB.prepare("INSERT INTO push_log (installation_id, pushed_at) VALUES (?,?)")
    .bind(authHeaders.installationId, nowSecs()).run();

  // Update last_seen_at
  await env.DB.prepare("UPDATE installations SET last_seen_at=? WHERE installation_id=?")
    .bind(nowSecs(), authHeaders.installationId).run();

  // Opportunistic cleanup (non-fatal)
  try {
    const cleanupBefore = nowSecs();
    await env.DB.prepare("DELETE FROM reg_challenges WHERE created_at < ?")
      .bind(cleanupBefore - 600).run();
    await env.DB.prepare("DELETE FROM used_nonces WHERE used_at < ?")
      .bind(cleanupBefore - 900).run();
    await env.DB.prepare("DELETE FROM push_log WHERE pushed_at < ?")
      .bind(cleanupBefore - 7200).run();
  } catch {
    // cleanup failure must never fail a push request
  }

  // Send APNs push — generic payload only, no command/summary data
  const result = await sendApnsPush(inst.apns_device_token, apnsConfig(env));
  if (!result.ok) {
    console.log(`[push] APNs error ${result.status}: ${result.reason}`);
    if (result.status === 410) {
      // BadDeviceToken / Unregistered — mark token as stale
      await env.DB.prepare(
        "UPDATE installations SET token_stale_at=? WHERE installation_id=?"
      ).bind(nowSecs(), authHeaders.installationId).run();
      return json({ error: "device_token_invalid", hint: "call update-token" }, 422);
    }
    return json({ error: "push_failed", apns_status: result.status }, 502);
  }

  return json({ status: "ok" });
}

// ── POST /v1/update-token ─────────────────────────────────────────────────────

async function handleUpdateToken(req: Request, env: Env): Promise<Response> {
  const authHeaders = parseAuthHeaders(req);
  if (!authHeaders) return json({ error: "invalid_auth" }, 401);

  const bodyText = await req.text();

  const authErr = await verifyAuth(authHeaders, bodyText, "POST", "/v1/update-token", env);
  if (authErr) {
    const status = (authErr === "nonce_replayed") ? 409 : 401;
    return json({ error: authErr }, status);
  }

  let b: Record<string, unknown>;
  try {
    b = JSON.parse(bodyText);
  } catch {
    return json({ error: "invalid_json" }, 400);
  }

  const apnsToken = b.apns_device_token;
  if (typeof apnsToken !== "string" || apnsToken.length < 32) {
    return json({ error: "missing apns_device_token" }, 400);
  }

  await env.DB.prepare(
    "UPDATE installations SET apns_device_token=?, last_seen_at=?, token_stale_at=NULL WHERE installation_id=?",
  ).bind(apnsToken, nowSecs(), authHeaders.installationId).run();

  return json({ status: "ok" });
}

// ── POST /v1/revoke ───────────────────────────────────────────────────────────

async function handleRevoke(req: Request, env: Env): Promise<Response> {
  const authHeaders = parseAuthHeaders(req);
  if (!authHeaders) return json({ error: "invalid_auth" }, 401);

  const bodyText = await req.text();

  const authErr = await verifyAuth(authHeaders, bodyText, "POST", "/v1/revoke", env);
  if (authErr) {
    const status = (authErr === "nonce_replayed") ? 409 : 401;
    return json({ error: authErr }, status);
  }

  await env.DB.prepare(
    "UPDATE installations SET revoked_at=? WHERE installation_id=?",
  ).bind(nowSecs(), authHeaders.installationId).run();

  return json({ status: "ok" });
}

// ── Router ────────────────────────────────────────────────────────────────────

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url    = new URL(req.url);
    const method = req.method.toUpperCase();
    const path   = url.pathname;

    try {
      if (method === "GET"  && path === "/health")          return handleHealth(env);
      if (method === "GET"  && path === "/v1/challenge")    return handleChallenge(req, env);
      if (method === "POST" && path === "/v1/register")     return handleRegister(req, env);
      if (method === "POST" && path === "/v1/push")         return handlePush(req, env);
      if (method === "POST" && path === "/v1/update-token") return handleUpdateToken(req, env);
      if (method === "POST" && path === "/v1/revoke")       return handleRevoke(req, env);
      return json({ error: "not_found" }, 404);
    } catch (err) {
      console.error(`[relay] unhandled error: ${err instanceof Error ? err.message : "unknown"}`);
      return json({ error: "internal_error" }, 500);
    }
  },
};
