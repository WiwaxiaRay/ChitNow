-- ChitNow relay D1 schema
-- Apply: wrangler d1 execute chitnow-relay --file=schema.sql

CREATE TABLE IF NOT EXISTS installations (
  installation_id   TEXT     PRIMARY KEY,
  relay_secret_hash TEXT     NOT NULL,          -- HMAC-SHA256 of relay_secret, hex
  apns_device_token TEXT     NOT NULL,
  created_at        INTEGER  NOT NULL,           -- Unix epoch seconds
  last_seen_at      INTEGER  NOT NULL,
  revoked_at        INTEGER  DEFAULT NULL        -- non-null = revoked
);

CREATE TABLE IF NOT EXISTS used_nonces (
  nonce         TEXT    NOT NULL,
  installation_id TEXT  NOT NULL,
  used_at       INTEGER NOT NULL,
  PRIMARY KEY (nonce, installation_id)
);

-- Optionally: per-installation push rate-limit tracking
CREATE TABLE IF NOT EXISTS push_log (
  installation_id TEXT    NOT NULL,
  pushed_at       INTEGER NOT NULL               -- Unix epoch seconds
);
CREATE INDEX IF NOT EXISTS idx_push_log_inst_time ON push_log(installation_id, pushed_at);

-- Registration challenge nonces (prevent enumeration)
CREATE TABLE IF NOT EXISTS reg_challenges (
  challenge     TEXT    PRIMARY KEY,
  created_at    INTEGER NOT NULL,
  used          INTEGER NOT NULL DEFAULT 0       -- 0 = unused, 1 = used
);
