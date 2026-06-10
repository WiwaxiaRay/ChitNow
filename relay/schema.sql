-- ChitNow relay D1 schema
-- Apply: wrangler d1 execute chitnow-relay --file=schema.sql

CREATE TABLE IF NOT EXISTS installations (
  installation_id   TEXT     PRIMARY KEY,
  relay_secret_hash TEXT     NOT NULL,          -- SHA256 of derived relay_secret, for audit
  apns_device_token TEXT     NOT NULL,
  created_at        INTEGER  NOT NULL,           -- Unix epoch seconds
  last_seen_at      INTEGER  NOT NULL,
  revoked_at        INTEGER  DEFAULT NULL,       -- non-null = revoked
  token_stale_at    INTEGER  DEFAULT NULL        -- non-null = APNs 410 received; update-token needed
);

CREATE TABLE IF NOT EXISTS used_nonces (
  nonce           TEXT    NOT NULL,
  installation_id TEXT    NOT NULL,
  used_at         INTEGER NOT NULL,
  PRIMARY KEY (nonce, installation_id)
);

-- Per-installation push rate-limit tracking and registration rate-limit tracking
CREATE TABLE IF NOT EXISTS push_log (
  installation_id TEXT    NOT NULL,
  pushed_at       INTEGER NOT NULL               -- Unix epoch seconds
);
CREATE INDEX IF NOT EXISTS idx_push_log_inst_time ON push_log(installation_id, pushed_at);
CREATE INDEX IF NOT EXISTS idx_push_log_pushed_at ON push_log(pushed_at);

-- Registration challenge nonces (prevent enumeration)
CREATE TABLE IF NOT EXISTS reg_challenges (
  challenge_id  TEXT    PRIMARY KEY,
  nonce         TEXT    NOT NULL,
  created_at    INTEGER NOT NULL,
  used          INTEGER NOT NULL DEFAULT 0       -- 0 = unused, 1 = used
);
CREATE INDEX IF NOT EXISTS idx_reg_challenges_created ON reg_challenges(created_at);
