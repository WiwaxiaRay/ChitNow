/**
 * Unit tests for relay auth helpers.
 * Run: cd relay && npm test
 */
import { describe, it, expect } from "vitest";
import {
  hmacSha256Hex,
  sha256Hex,
  safeEqual,
  parsePushAuth,
  verifyPushHmac,
  nowSecs,
  TIMESTAMP_TOLERANCE_SECS,
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

describe("parsePushAuth", () => {
  const valid = {
    installation_id: "inst-123",
    timestamp: 1700000000,
    nonce: "random-nonce-1234",
    hmac: "a".repeat(64),
  };

  it("accepts a valid object", () => {
    expect(parsePushAuth(valid)).toMatchObject({ installation_id: "inst-123" });
  });

  it("rejects null", () => {
    expect(parsePushAuth(null)).toBeNull();
  });

  it("rejects missing hmac", () => {
    const { hmac, ...rest } = valid;
    expect(parsePushAuth(rest)).toBeNull();
  });

  it("rejects nonce too short", () => {
    expect(parsePushAuth({ ...valid, nonce: "short" })).toBeNull();
  });

  it("rejects non-numeric timestamp", () => {
    expect(parsePushAuth({ ...valid, timestamp: "not-a-number" })).toBeNull();
  });
});

describe("verifyPushHmac", () => {
  async function makeClaims(secret: string, overrides: Partial<{
    installation_id: string; timestamp: number; nonce: string;
  }> = {}) {
    const installation_id = overrides.installation_id ?? "inst-abc";
    const timestamp       = overrides.timestamp ?? nowSecs();
    const nonce           = overrides.nonce ?? "test-nonce-12345678";
    const message = `${installation_id}:${timestamp}:${nonce}`;
    const hmac = await hmacSha256Hex(secret, message);
    return { installation_id, timestamp, nonce, hmac };
  }

  it("verifies a correct HMAC", async () => {
    const claims = await makeClaims("my-secret");
    expect(await verifyPushHmac(claims, "my-secret")).toBe(true);
  });

  it("rejects a wrong secret", async () => {
    const claims = await makeClaims("secret-a");
    expect(await verifyPushHmac(claims, "secret-b")).toBe(false);
  });

  it("rejects a tampered installation_id", async () => {
    const claims = await makeClaims("secret");
    const tampered = { ...claims, installation_id: "different-id" };
    expect(await verifyPushHmac(tampered, "secret")).toBe(false);
  });

  it("rejects a tampered timestamp", async () => {
    const claims = await makeClaims("secret", { timestamp: 1700000000 });
    const tampered = { ...claims, timestamp: 1700000001 };
    expect(await verifyPushHmac(tampered, "secret")).toBe(false);
  });

  it("rejects a tampered nonce", async () => {
    const claims = await makeClaims("secret");
    const tampered = { ...claims, nonce: "different-nonce-xyz" };
    expect(await verifyPushHmac(tampered, "secret")).toBe(false);
  });
});
