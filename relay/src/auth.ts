/**
 * HMAC-SHA256 authentication helpers for ChitNow relay.
 *
 * Each installation's relay_secret is DERIVED on demand:
 *   relay_secret = HMAC-SHA256(RELAY_MASTER_SECRET, installation_id)
 *
 * Auth uses HTTP headers (canonical message signature):
 *   canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256(BODY)
 *   signature = HMAC-SHA256(relay_secret, canonical)
 *
 * Headers:
 *   X-ChitNow-Installation: <installation_id>
 *   X-ChitNow-Timestamp:    <unix_seconds>
 *   X-ChitNow-Nonce:        <random_hex_min_16_chars>
 *   X-ChitNow-Signature:    <hmac_sha256_hex_64_chars>
 *
 * Verification order:
 *   1. Check timestamp within tolerance
 *   2. Load installation
 *   3. Verify HMAC
 *   4. Atomically insert nonce (fail = replayed)
 *   5. Execute business logic
 *
 * Nonce is NEVER consumed if HMAC is invalid.
 */

export const TIMESTAMP_TOLERANCE_SECS = 300; // 5 minutes

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

export function nowSecs(): number {
  return Math.floor(Date.now() / 1000);
}

/**
 * Derive the relay_secret for an installation.
 * relay_secret = HMAC-SHA256(masterSecret, installationId)
 */
export async function deriveRelaySecret(
  masterSecret: string,
  installationId: string,
): Promise<string> {
  return hmacSha256Hex(masterSecret, installationId);
}

/**
 * Build the canonical message string for signature verification.
 * canonical = METHOD + "\n" + PATH + "\n" + TIMESTAMP + "\n" + NONCE + "\n" + SHA256(BODY_TEXT)
 */
export async function canonicalMessage(
  method: string,
  path: string,
  timestamp: number,
  nonce: string,
  bodyText: string,
): Promise<string> {
  const bodyHash = await sha256Hex(bodyText);
  return `${method}\n${path}\n${timestamp}\n${nonce}\n${bodyHash}`;
}

export interface AuthHeaders {
  installationId: string;
  timestamp: number;
  nonce: string;
  signature: string;
}

/**
 * Parse and validate the X-ChitNow-* auth headers from a request.
 * Returns null if any required header is missing or invalid.
 */
export function parseAuthHeaders(req: Request): AuthHeaders | null {
  const installationId = req.headers.get("X-ChitNow-Installation");
  const timestampStr   = req.headers.get("X-ChitNow-Timestamp");
  const nonce          = req.headers.get("X-ChitNow-Nonce");
  const signature      = req.headers.get("X-ChitNow-Signature");

  if (!installationId || !timestampStr || !nonce || !signature) return null;
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(installationId)) {
    return null;
  }

  const timestamp = Number(timestampStr);
  if (!Number.isInteger(timestamp) || timestamp <= 0) return null;

  if (nonce.length < 16 || nonce.length > 256 || !/^[0-9a-f]+$/i.test(nonce)) return null;
  if (signature.length !== 64 || !/^[0-9a-f]+$/.test(signature)) return null;

  return { installationId, timestamp, nonce, signature };
}
