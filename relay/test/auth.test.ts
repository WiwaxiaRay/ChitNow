/**
 * Unit tests for relay auth helpers.
 * Run: cd relay && npm test
 */
import { describe, it, expect } from "vitest";
import {
  hmacSha256Hex,
  sha256Hex,
  safeEqual,
  nowSecs,
  TIMESTAMP_TOLERANCE_SECS,
  deriveRelaySecret,
  canonicalMessage,
  parseAuthHeaders,
} from "../src/auth";

describe("hmacSha256Hex", () => {
  it("produces a 64-char hex string", async () => {
    const h = await hmacSha256Hex("secret", "message");
    expect(h).toHaveLength(64);
    expect(/^[0-9a-f]+$/.test(h)).toBe(true);
  });

  it("same input produces same output", async () => {
    const a = await hmacSha256Hex("key", "data");
    const b = await hmacSha256Hex("key", "data");
    expect(a).toBe(b);
  });

  it("different key produces different output", async () => {
    const a = await hmacSha256Hex("key1", "data");
    const b = await hmacSha256Hex("key2", "data");
    expect(a).not.toBe(b);
  });

  it("different message produces different output", async () => {
    const a = await hmacSha256Hex("key", "data1");
    const b = await hmacSha256Hex("key", "data2");
    expect(a).not.toBe(b);
  });
});

describe("sha256Hex", () => {
  it("produces a 64-char hex string", async () => {
    const h = await sha256Hex("input");
    expect(h).toHaveLength(64);
  });

  it("is deterministic", async () => {
    expect(await sha256Hex("x")).toBe(await sha256Hex("x"));
  });
});

describe("safeEqual", () => {
  it("returns true for equal strings", () => {
    expect(safeEqual("abc", "abc")).toBe(true);
  });

  it("returns false for different strings of same length", () => {
    expect(safeEqual("abc", "abd")).toBe(false);
  });

  it("returns false for different lengths", () => {
    expect(safeEqual("ab", "abc")).toBe(false);
  });
});

describe("deriveRelaySecret", () => {
  it("returns a 64-char hex string", async () => {
    const s = await deriveRelaySecret("master", "inst-123");
    expect(s).toHaveLength(64);
    expect(/^[0-9a-f]+$/.test(s)).toBe(true);
  });

  it("same master + installation_id always produces same relay_secret", async () => {
    const a = await deriveRelaySecret("master-secret", "inst-abc");
    const b = await deriveRelaySecret("master-secret", "inst-abc");
    expect(a).toBe(b);
  });

  it("different installation_ids derive different relay_secrets", async () => {
    const a = await deriveRelaySecret("master-secret", "inst-1");
    const b = await deriveRelaySecret("master-secret", "inst-2");
    expect(a).not.toBe(b);
  });

  it("different master secrets derive different relay_secrets", async () => {
    const a = await deriveRelaySecret("master-a", "inst-1");
    const b = await deriveRelaySecret("master-b", "inst-1");
    expect(a).not.toBe(b);
  });
});

describe("canonicalMessage", () => {
  it("returns expected format", async () => {
    const result = await canonicalMessage("POST", "/v1/push", 1700000000, "abc-nonce", "{}");
    const bodyHash = await sha256Hex("{}");
    expect(result).toBe(`POST\n/v1/push\n1700000000\nabc-nonce\n${bodyHash}`);
  });

  it("changes if method changes", async () => {
    const a = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce", "{}");
    const b = await canonicalMessage("GET",  "/v1/push", 1700000000, "nonce", "{}");
    expect(a).not.toBe(b);
  });

  it("changes if path changes", async () => {
    const a = await canonicalMessage("POST", "/v1/push",    1700000000, "nonce", "{}");
    const b = await canonicalMessage("POST", "/v1/revoke",  1700000000, "nonce", "{}");
    expect(a).not.toBe(b);
  });

  it("changes if timestamp changes", async () => {
    const a = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce", "{}");
    const b = await canonicalMessage("POST", "/v1/push", 1700000001, "nonce", "{}");
    expect(a).not.toBe(b);
  });

  it("changes if nonce changes", async () => {
    const a = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce1", "{}");
    const b = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce2", "{}");
    expect(a).not.toBe(b);
  });

  it("changes if body changes", async () => {
    const a = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce", "{}");
    const b = await canonicalMessage("POST", "/v1/push", 1700000000, "nonce", '{"key":"val"}');
    expect(a).not.toBe(b);
  });
});

describe("parseAuthHeaders", () => {
  const makeReq = (headers: Record<string, string>) =>
    new Request("https://example.com/v1/push", { method: "POST", headers });

  const validHeaders = {
    "X-ChitNow-Installation": "inst-abc-123",
    "X-ChitNow-Timestamp":    "1700000000",
    "X-ChitNow-Nonce":        "a".repeat(16),
    "X-ChitNow-Signature":    "a".repeat(64),
  };

  it("parses valid headers", () => {
    const result = parseAuthHeaders(makeReq(validHeaders));
    expect(result).not.toBeNull();
    expect(result!.installationId).toBe("inst-abc-123");
    expect(result!.timestamp).toBe(1700000000);
    expect(result!.nonce).toBe("a".repeat(16));
    expect(result!.signature).toBe("a".repeat(64));
  });

  it("returns null if X-ChitNow-Installation missing", () => {
    const { "X-ChitNow-Installation": _, ...rest } = validHeaders;
    expect(parseAuthHeaders(makeReq(rest))).toBeNull();
  });

  it("returns null if X-ChitNow-Timestamp missing", () => {
    const { "X-ChitNow-Timestamp": _, ...rest } = validHeaders;
    expect(parseAuthHeaders(makeReq(rest))).toBeNull();
  });

  it("returns null if X-ChitNow-Nonce missing", () => {
    const { "X-ChitNow-Nonce": _, ...rest } = validHeaders;
    expect(parseAuthHeaders(makeReq(rest))).toBeNull();
  });

  it("returns null if X-ChitNow-Signature missing", () => {
    const { "X-ChitNow-Signature": _, ...rest } = validHeaders;
    expect(parseAuthHeaders(makeReq(rest))).toBeNull();
  });

  it("returns null if timestamp is not an integer string", () => {
    expect(parseAuthHeaders(makeReq({ ...validHeaders, "X-ChitNow-Timestamp": "not-a-number" }))).toBeNull();
  });

  it("returns null if nonce is too short", () => {
    expect(parseAuthHeaders(makeReq({ ...validHeaders, "X-ChitNow-Nonce": "short" }))).toBeNull();
  });

  it("returns null if signature is not 64 hex chars", () => {
    expect(parseAuthHeaders(makeReq({ ...validHeaders, "X-ChitNow-Signature": "abc" }))).toBeNull();
    expect(parseAuthHeaders(makeReq({ ...validHeaders, "X-ChitNow-Signature": "z".repeat(64) }))).toBeNull();
  });
});

describe("nowSecs", () => {
  it("returns a reasonable unix timestamp", () => {
    const t = nowSecs();
    expect(t).toBeGreaterThan(1_700_000_000);
    expect(t).toBeLessThan(2_000_000_000);
  });
});

describe("TIMESTAMP_TOLERANCE_SECS", () => {
  it("is 300 (5 minutes)", () => {
    expect(TIMESTAMP_TOLERANCE_SECS).toBe(300);
  });
});
