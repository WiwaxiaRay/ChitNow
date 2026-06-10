/**
 * HMAC-SHA256 authentication helpers for ChitNow relay.
 *
 * Each installation has an independent relay_secret (32 random bytes, hex-encoded).
 * The secret is hashed with SHA-256 and only the hash is stored in D1.
 *
 * Push requests are authenticated with a signed body:
 *   message  = installation_id + ":" + timestamp + ":" + nonce
 *   hmac     = HMAC-SHA256(relay_secret, message)   — hex
 *
 * The relay verifies:
 *   1. HMAC matches
 *   2. |now - timestamp| <= TIMESTAMP_TOLERANCE_SECS
 *   3. nonce has not been seen before for this installation
 *   4. Installation exists and is not revoked
 */

export const TIMESTAMP_TOLERANCE_SECS = 300; // 5 minutes
const NONCE_TTL_SECS = 600;                  // clean up nonces older than 10 min

export async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(message));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

export async function sha256Hex(data: string): Promise<string> {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(data));
  return Array.from(new Uint8Array(buf))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

/** Constant-time string comparison to prevent timing attacks. */
export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
}

export interface PushAuthClaims {
  installation_id: string;
  timestamp: number;   // unix seconds
  nonce: string;       // random string, single-use
  hmac: string;        // hex HMAC-SHA256
}

export function parsePushAuth(body: unknown): PushAuthClaims | null {
  if (typeof body !== "object" || body === null) return null;
  const b = body as Record<string, unknown>;
  if (
    typeof b.installation_id !== "string" ||
    typeof b.timestamp !== "number" ||
    typeof b.nonce !== "string" ||
    typeof b.hmac !== "string"
  ) return null;
  if (b.nonce.length < 16 || b.nonce.length > 128) return null;
  return {
    installation_id: b.installation_id,
    timestamp: b.timestamp,
    nonce: b.nonce,
    hmac: b.hmac,
  };
}

export async function verifyPushHmac(
  claims: PushAuthClaims,
  relaySecret: string,
): Promise<boolean> {
  const message = `${claims.installation_id}:${claims.timestamp}:${claims.nonce}`;
  const expected = await hmacSha256Hex(relaySecret, message);
  return safeEqual(expected, claims.hmac);
}

export function nowSecs(): number {
  return Math.floor(Date.now() / 1000);
}
