/**
 * APNs payload tests — verify the generic payload never contains forbidden fields,
 * and that network behaviour is correct.
 * Run: cd relay && npm test
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { GENERIC_PAYLOAD } from "../src/apns";

const FORBIDDEN_FIELDS = [
  "request_id", "command", "summary", "cwd", "broker_url",
  "api_key", "cert_fp", "broker_address",
];

// ---------------------------------------------------------------------------
// Payload contract tests — no network needed
// ---------------------------------------------------------------------------

describe("GENERIC_PAYLOAD contract", () => {
  it("has aps.alert with generic title and body", () => {
    expect(GENERIC_PAYLOAD.aps.alert.title).toBe("ChitNow");
    expect(GENERIC_PAYLOAD.aps.alert.body).toBe("New approval request — open ChitNow to review");
  });

  it("does NOT contain category field (non-functional action buttons removed)", () => {
    const serialised = JSON.stringify(GENERIC_PAYLOAD);
    expect(serialised).not.toContain('"category"');
  });

  it("does NOT contain category at any nesting level", () => {
    function flatten(obj: unknown, keys: string[] = []): string[] {
      if (typeof obj !== "object" || obj === null) return keys;
      for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
        keys.push(k);
        flatten(v, keys);
      }
      return keys;
    }
    const allKeys = flatten(GENERIC_PAYLOAD);
    expect(allKeys).not.toContain("category");
  });

  it("has content-available: 1 for background wake", () => {
    expect((GENERIC_PAYLOAD.aps as Record<string, unknown>)["content-available"]).toBe(1);
  });

  it("has type = approval_request", () => {
    expect((GENERIC_PAYLOAD as Record<string, unknown>).type).toBe("approval_request");
  });

  it("does not contain any forbidden field", () => {
    const serialised = JSON.stringify(GENERIC_PAYLOAD);
    for (const field of FORBIDDEN_FIELDS) {
      expect(serialised).not.toContain(`"${field}"`);
    }
  });

  it("does not contain any forbidden field at any nesting level", () => {
    function flatten(obj: unknown, keys: string[] = []): string[] {
      if (typeof obj !== "object" || obj === null) return keys;
      for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
        keys.push(k);
        flatten(v, keys);
      }
      return keys;
    }
    const allKeys = flatten(GENERIC_PAYLOAD);
    for (const field of FORBIDDEN_FIELDS) {
      expect(allKeys).not.toContain(field);
    }
  });
});

// ---------------------------------------------------------------------------
// Network / APNs call tests — mock fetch and crypto
// ---------------------------------------------------------------------------

const fetchMock = vi.fn();
global.fetch = fetchMock;

describe("sendApnsPush network behaviour", () => {
  beforeEach(() => {
    fetchMock.mockReset();
    // Mock crypto.subtle so importKey and sign don't need a real key
    vi.spyOn(crypto.subtle, "importKey").mockResolvedValue({} as CryptoKey);
    vi.spyOn(crypto.subtle, "sign").mockResolvedValue(new Uint8Array(64).buffer as ArrayBuffer);
    fetchMock.mockResolvedValue(new Response(null, { status: 200 }));
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  const testConfig = {
    privateKeyPem: "fake",
    keyId: "TESTKEY123",
    teamId: "TESTTEAM12",
    bundleId: "com.example.test",
    production: false,
  };

  it("sends only GENERIC_PAYLOAD — no forbidden fields in request body", async () => {
    const { sendApnsPush } = await import("../src/apns");
    await sendApnsPush("a".repeat(64), testConfig);

    expect(fetchMock).toHaveBeenCalledOnce();
    const body = JSON.parse(fetchMock.mock.calls[0]![1].body as string) as Record<string, unknown>;
    for (const field of FORBIDDEN_FIELDS) {
      expect(body).not.toHaveProperty(field);
    }
  });

  it("uses sandbox host when production=false", async () => {
    const { sendApnsPush } = await import("../src/apns");
    await sendApnsPush("b".repeat(64), { ...testConfig, production: false });
    const url = fetchMock.mock.calls[0]![0] as string;
    expect(url).toContain("sandbox.push.apple.com");
  });

  it("uses production host when production=true", async () => {
    const { sendApnsPush } = await import("../src/apns");
    await sendApnsPush("c".repeat(64), { ...testConfig, production: true });
    const url = fetchMock.mock.calls[0]![0] as string;
    expect(url).toContain("api.push.apple.com");
    expect(url).not.toContain("sandbox");
  });

  it("returns ok:true on APNs 200", async () => {
    const { sendApnsPush } = await import("../src/apns");
    const result = await sendApnsPush("d".repeat(64), testConfig);
    expect(result.ok).toBe(true);
    expect(result.status).toBe(200);
  });

  it("returns ok:false with sanitised reason on APNs error", async () => {
    fetchMock.mockResolvedValueOnce(
      new Response(JSON.stringify({ reason: "BadDeviceToken" }), { status: 400 }),
    );
    const { sendApnsPush } = await import("../src/apns");
    const result = await sendApnsPush("e".repeat(64), testConfig);
    expect(result.ok).toBe(false);
    expect(result.status).toBe(400);
    expect(result.reason).toBe("BadDeviceToken");
    // Must not contain JWT material or long base64 strings
    expect(result.reason ?? "").not.toMatch(/[A-Za-z0-9+/]{40,}/);
  });

  it("does not include device token in APNs request body", async () => {
    const { sendApnsPush } = await import("../src/apns");
    const deviceToken = "f".repeat(64);
    await sendApnsPush(deviceToken, testConfig);
    const body = fetchMock.mock.calls[0]![1].body as string;
    expect(body).not.toContain(deviceToken);
  });

  it("sets apns-expiration header", async () => {
    const { sendApnsPush } = await import("../src/apns");
    await sendApnsPush("g".repeat(64), testConfig);
    const headers = fetchMock.mock.calls[0]![1].headers as Record<string, string>;
    expect(headers["apns-expiration"]).toBeDefined();
    const exp = parseInt(headers["apns-expiration"]!, 10);
    expect(exp).toBeGreaterThan(Math.floor(Date.now() / 1000));
  });
});
