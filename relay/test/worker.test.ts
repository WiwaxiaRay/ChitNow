/**
 * End-to-end Worker route tests using a real in-memory SQLite database
 * (via better-sqlite3) as a D1 mock.
 *
 * These tests import the Worker's fetch handler directly and call it with
 * mock Request objects and a mock Env.
 *
 * Run: cd relay && npm test
 */
import { describe, it, expect, beforeEach, vi } from "vitest";
import Database from "better-sqlite3";
import { readFileSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";
import { hmacSha256Hex, sha256Hex, canonicalMessage, nowSecs } from "../src/auth";
import workerModule from "../src/index";

vi.mock("../src/apns", () => ({
  sendApnsPush: vi.fn().mockResolvedValue({ ok: true, status: 200 }),
  GENERIC_PAYLOAD: {
    aps: {
      alert: { title: "ChitNow", body: "New approval request — open ChitNow to review" },
      sound: "default",
      "content-available": 1,
    },
    type: "approval_request",
  },
}));

const __dirname = dirname(fileURLToPath(import.meta.url));
const SCHEMA_PATH = join(__dirname, "..", "schema.sql");

// ---------------------------------------------------------------------------
// MockD1: wraps better-sqlite3 with the D1 async API
// ---------------------------------------------------------------------------

class MockD1PreparedStatement {
  private db: Database.Database;
  private sql: string;
  private params: unknown[] = [];

  constructor(db: Database.Database, sql: string) {
    this.db = db;
    this.sql = sql;
  }

  bind(...args: unknown[]): this {
    this.params = args;
    return this;
  }

  async first<T = unknown>(): Promise<T | null> {
    try {
      const stmt = this.db.prepare(this.sql);
      const row = stmt.get(...(this.params as Parameters<Database.Statement["get"]>)) as T | undefined;
      return row ?? null;
    } catch (e) {
      throw e;
    }
  }

  async run(): Promise<{ meta: { changes: number } }> {
    try {
      const stmt = this.db.prepare(this.sql);
      const info = stmt.run(...(this.params as Parameters<Database.Statement["run"]>));
      return { meta: { changes: info.changes } };
    } catch (e) {
      throw e;
    }
  }

  async all<T = unknown>(): Promise<{ results: T[] }> {
    try {
      const stmt = this.db.prepare(this.sql);
      const rows = stmt.all(...(this.params as Parameters<Database.Statement["all"]>)) as T[];
      return { results: rows };
    } catch (e) {
      throw e;
    }
  }
}

class MockD1Database {
  private db: Database.Database;

  constructor(db: Database.Database) {
    this.db = db;
  }

  prepare(sql: string): MockD1PreparedStatement {
    return new MockD1PreparedStatement(this.db, sql);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const MASTER_SECRET = "test-master-secret";

function makeMockEnv(db: MockD1Database) {
  return {
    DB: db as unknown as D1Database,
    RELAY_MASTER_SECRET: MASTER_SECRET,
    APNS_PRIVATE_KEY: "fake-key",
    APNS_KEY_ID: "TESTKEY123",
    APNS_TEAM_ID: "TESTTEAM12",
    APNS_BUNDLE_ID: "com.example.test",
    APNS_ENV: "sandbox",
  };
}

async function buildAuthHeaders(
  method: string,
  path: string,
  bodyText: string,
  installationId: string,
  relaySecret: string,
  overrides: Partial<{
    timestamp: number;
    nonce: string;
    signature: string;
  }> = {}
): Promise<Record<string, string>> {
  const timestamp = overrides.timestamp ?? nowSecs();
  const nonce     = overrides.nonce ?? Array.from(crypto.getRandomValues(new Uint8Array(16)))
    .map((b) => b.toString(16).padStart(2, "0")).join("");
  const canonical = await canonicalMessage(method, path, timestamp, nonce, bodyText);
  const sig = overrides.signature ?? await hmacSha256Hex(relaySecret, canonical);
  return {
    "X-ChitNow-Installation": installationId,
    "X-ChitNow-Timestamp":    String(timestamp),
    "X-ChitNow-Nonce":        nonce,
    "X-ChitNow-Signature":    sig,
  };
}

/** Register a fresh installation and return its credentials. */
async function registerInstallation(
  env: ReturnType<typeof makeMockEnv>,
  deviceToken: string = "a".repeat(64)
): Promise<{ installationId: string; relaySecret: string }> {
  // Get challenge
  const chalResp = await workerModule.fetch(
    new Request("https://relay.example.com/v1/challenge"),
    env
  );
  expect(chalResp.status).toBe(200);
  const chalJSON = await chalResp.json() as { challenge_id: string; nonce: string; expires_at: number };

  // Register
  const body = JSON.stringify({
    apns_device_token: deviceToken,
    challenge_id: chalJSON.challenge_id,
    nonce: chalJSON.nonce,
    environment: "sandbox",
  });
  const regResp = await workerModule.fetch(
    new Request("https://relay.example.com/v1/register", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body,
    }),
    env
  );
  expect(regResp.status).toBe(201);
  const regJSON = await regResp.json() as { installation_id: string; relay_secret: string };
  return { installationId: regJSON.installation_id, relaySecret: regJSON.relay_secret };
}

// ---------------------------------------------------------------------------
// Setup
// ---------------------------------------------------------------------------

let sqliteDb: Database.Database;
let db: MockD1Database;
let env: ReturnType<typeof makeMockEnv>;

beforeEach(() => {
  sqliteDb = new Database(":memory:");
  // Load schema: split on ";" but keep the delimiter for exec
  const schemaText = readFileSync(SCHEMA_PATH, "utf-8");
  // Remove SQL comments before splitting
  const stripped = schemaText.replace(/--[^\n]*/g, "");
  const stmts = stripped.split(";").map((s) => s.trim()).filter(Boolean);
  for (const stmt of stmts) {
    try {
      sqliteDb.exec(stmt + ";");
    } catch {
      // skip blank lines, comments, etc.
    }
  }
  db = new MockD1Database(sqliteDb);
  env = makeMockEnv(db);
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

describe("GET /health", () => {
  it("returns 200 with status ok", async () => {
    const resp = await workerModule.fetch(new Request("https://relay.example.com/health"), env);
    expect(resp.status).toBe(200);
    const body = await resp.json() as Record<string, unknown>;
    expect(body.status).toBe("ok");
  });
});

describe("GET /v1/challenge", () => {
  it("returns challenge_id, nonce, and expires_at", async () => {
    const resp = await workerModule.fetch(new Request("https://relay.example.com/v1/challenge"), env);
    expect(resp.status).toBe(200);
    const body = await resp.json() as Record<string, unknown>;
    expect(typeof body.challenge_id).toBe("string");
    expect(typeof body.nonce).toBe("string");
    expect(typeof body.expires_at).toBe("number");
    expect((body.expires_at as number)).toBeGreaterThan(nowSecs());
  });
});

describe("POST /v1/register", () => {
  it("returns 201 with installation_id and relay_secret on valid challenge", async () => {
    const chalResp = await workerModule.fetch(new Request("https://relay.example.com/v1/challenge"), env);
    const chalJSON = await chalResp.json() as { challenge_id: string; nonce: string };

    const body = JSON.stringify({
      apns_device_token: "a".repeat(64),
      challenge_id: chalJSON.challenge_id,
      nonce: chalJSON.nonce,
      environment: "production",
    });
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }),
      env
    );
    expect(resp.status).toBe(201);
    const data = await resp.json() as Record<string, unknown>;
    expect(typeof data.installation_id).toBe("string");
    expect(typeof data.relay_secret).toBe("string");
    expect((data.relay_secret as string).length).toBe(64);
  });

  it("returns 409 when challenge is already used", async () => {
    const chalResp = await workerModule.fetch(new Request("https://relay.example.com/v1/challenge"), env);
    const chalJSON = await chalResp.json() as { challenge_id: string; nonce: string };

    const body = JSON.stringify({
      apns_device_token: "a".repeat(64),
      challenge_id: chalJSON.challenge_id,
      nonce: chalJSON.nonce,
      environment: "production",
    });
    // First registration succeeds
    await workerModule.fetch(
      new Request("https://relay.example.com/v1/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }),
      env
    );
    // Second registration with same challenge should fail
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }),
      env
    );
    expect(resp.status).toBe(409);
  });

  it("returns 410 when challenge is expired", async () => {
    // Insert an expired challenge directly into the DB
    const now = nowSecs();
    sqliteDb.prepare(
      "INSERT INTO reg_challenges (challenge_id, nonce, created_at, used) VALUES (?, ?, ?, 0)"
    ).run("expired-challenge-id", "some-nonce-1234567890", now - 400);

    const body = JSON.stringify({
      apns_device_token: "a".repeat(64),
      challenge_id: "expired-challenge-id",
      nonce: "some-nonce-1234567890",
      environment: "production",
    });
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/register", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body,
      }),
      env
    );
    expect(resp.status).toBe(410);
  });
});

describe("POST /v1/push", () => {
  it("returns 200 with valid signature", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({ event: "approval_pending" });
    const headers = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret);
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp.status).toBe(200);
  });

  it("returns 401 with wrong signature", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({ event: "approval_pending" });
    const headers = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret, {
      signature: "b".repeat(64),  // wrong signature
    });
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp.status).toBe(401);
  });

  it("returns 409 with replayed nonce", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({ event: "approval_pending" });
    const nonce = "same-nonce-reused-12345678";
    const headers = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret, { nonce });

    // First request succeeds
    const resp1 = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp1.status).toBe(200);

    // Rebuild headers with same nonce for replay attempt
    const headers2 = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret, { nonce });
    const resp2 = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers2 },
        body: bodyText,
      }),
      env
    );
    expect(resp2.status).toBe(409);
  });

  it("returns 401 with old timestamp", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({ event: "approval_pending" });
    const oldTimestamp = nowSecs() - 400; // beyond 300s tolerance
    const headers = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret, {
      timestamp: oldTimestamp,
    });
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp.status).toBe(401);
  });
});

describe("POST /v1/update-token", () => {
  it("returns 200 with valid signature", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({ apns_device_token: "b".repeat(64), environment: "production" });
    const headers = await buildAuthHeaders("POST", "/v1/update-token", bodyText, installationId, relaySecret);
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/update-token", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp.status).toBe(200);
  });
});

describe("POST /v1/revoke", () => {
  it("returns 200 with valid signature", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    const bodyText = JSON.stringify({});
    const headers = await buildAuthHeaders("POST", "/v1/revoke", bodyText, installationId, relaySecret);
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/revoke", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: bodyText,
      }),
      env
    );
    expect(resp.status).toBe(200);
  });

  it("returns 401 after revoke when pushing", async () => {
    const { installationId, relaySecret } = await registerInstallation(env);

    // Revoke
    const revokeBody = JSON.stringify({});
    const revokeHeaders = await buildAuthHeaders("POST", "/v1/revoke", revokeBody, installationId, relaySecret);
    const revokeResp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/revoke", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...revokeHeaders },
        body: revokeBody,
      }),
      env
    );
    expect(revokeResp.status).toBe(200);

    // Push after revoke should fail
    const bodyText = JSON.stringify({ event: "approval_pending" });
    const pushHeaders = await buildAuthHeaders("POST", "/v1/push", bodyText, installationId, relaySecret);
    const pushResp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/push", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...pushHeaders },
        body: bodyText,
      }),
      env
    );
    expect(pushResp.status).toBe(401);
  });
});

describe("unknown routes", () => {
  it("returns 404 for unknown path", async () => {
    const resp = await workerModule.fetch(
      new Request("https://relay.example.com/v1/unknown"),
      env
    );
    expect(resp.status).toBe(404);
  });
});
