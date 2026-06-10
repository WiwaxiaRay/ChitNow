/**
 * APNs Provider API client using Web Crypto (ES256 JWT).
 *
 * The JWT is cached for up to 50 minutes to avoid re-signing on every request.
 * The APNs payload is intentionally generic — it never contains the command,
 * summary, cwd, broker URL, or any other sensitive data.
 */

export interface ApnsConfig {
  privateKeyPem: string;  // contents of .p8 (with or without PEM headers)
  keyId: string;          // 10-char key ID
  teamId: string;         // 10-char team ID
  bundleId: string;
  production: boolean;
}

const APNS_HOST_PROD    = "https://api.push.apple.com";
const APNS_HOST_SANDBOX = "https://api.sandbox.push.apple.com";

// Module-level JWT cache (per Worker instance)
let _cachedJwt: string | null = null;
let _cachedJwtAt: number = 0;
const JWT_TTL_SECS = 50 * 60; // 50 minutes

/** The ONLY payload sent to Apple's servers — generic wake-up, no sensitive data.
 *  Exported for testing — verify no forbidden fields are ever added. */
export const GENERIC_PAYLOAD = {
  aps: {
    alert: {
      title: "ChitNow",
      body: "New approval request",
    },
    sound: "default",
    category: "AGENT_APPROVAL",
  },
  type: "approval_request",
  // NO: request_id, command, summary, cwd, broker_url, api_key, cert_fp
};

/** APNs expiration: 30 seconds from now. Approval decisions are time-sensitive. */
function apnsExpiration(): number {
  return Math.floor(Date.now() / 1000) + 30;
}

async function stripPemHeaders(pem: string): Promise<string> {
  return pem
    .replace(/-----BEGIN EC PRIVATE KEY-----/, "")
    .replace(/-----END EC PRIVATE KEY-----/, "")
    .replace(/-----BEGIN PRIVATE KEY-----/, "")
    .replace(/-----END PRIVATE KEY-----/, "")
    .replace(/\s+/g, "");
}

async function importApnsKey(privateKeyPem: string): Promise<CryptoKey> {
  const b64 = await stripPemHeaders(privateKeyPem);
  const der = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

function base64UrlEncode(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=/g, "");
}

async function makeApnsJwt(config: ApnsConfig): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (_cachedJwt && now - _cachedJwtAt < JWT_TTL_SECS) {
    return _cachedJwt;
  }

  const header = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: config.keyId })),
  );
  const payload = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ iss: config.teamId, iat: now })),
  );
  const sigInput = `${header}.${payload}`;

  const key = await importApnsKey(config.privateKeyPem);
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(sigInput),
  );

  const jwt = `${sigInput}.${base64UrlEncode(new Uint8Array(sig))}`;
  _cachedJwt = jwt;
  _cachedJwtAt = now;
  return jwt;
}

export interface ApnsResult {
  ok: boolean;
  status: number;
  reason?: string;  // APNs error reason (never the JWT or device token)
}

export async function sendApnsPush(
  deviceToken: string,
  config: ApnsConfig,
): Promise<ApnsResult> {
  const host = config.production ? APNS_HOST_PROD : APNS_HOST_SANDBOX;
  const jwt = await makeApnsJwt(config);

  const resp = await fetch(`${host}/3/device/${deviceToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": config.bundleId,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(apnsExpiration()),
      "content-type": "application/json",
    },
    body: JSON.stringify(GENERIC_PAYLOAD),
  });

  if (resp.status === 200) {
    return { ok: true, status: 200 };
  }

  // Extract only the error reason — never log JWT, device token, or full response
  let reason: string | undefined;
  try {
    const body = (await resp.json()) as { reason?: string };
    reason = body.reason;
  } catch {
    reason = "unknown";
  }
  return { ok: false, status: resp.status, reason };
}
