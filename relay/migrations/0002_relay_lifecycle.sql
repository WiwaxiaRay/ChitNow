-- Run once before deploying the relay lifecycle Worker update:
-- wrangler d1 execute chitnow-relay --file=migrations/0002_relay_lifecycle.sql

ALTER TABLE installations ADD COLUMN previous_key_version INTEGER;
ALTER TABLE installations ADD COLUMN previous_key_expires_at INTEGER;
ALTER TABLE installations ADD COLUMN registration_challenge_id TEXT;

CREATE UNIQUE INDEX IF NOT EXISTS idx_installations_reg_challenge
  ON installations(registration_challenge_id);

CREATE TABLE IF NOT EXISTS rate_limits (
  scope        TEXT    NOT NULL,
  subject      TEXT    NOT NULL,
  window_start INTEGER NOT NULL,
  count        INTEGER NOT NULL,
  PRIMARY KEY (scope, subject, window_start)
);
CREATE INDEX IF NOT EXISTS idx_rate_limits_window ON rate_limits(window_start);
