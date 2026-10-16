PRAGMA foreign_keys = ON;
CREATE TABLE IF NOT EXISTS users (
  username TEXT PRIMARY KEY,
  scopes TEXT NOT NULL,
  password_hash TEXT,
  password_salt TEXT,
  invite_hash TEXT UNIQUE,
  invite_expires INTEGER,
  token_version TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
  created_at INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS sessions (
  hash TEXT PRIMARY KEY,
  username TEXT NOT NULL REFERENCES users(username) ON DELETE CASCADE,
  expires INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS sessions_user ON sessions(username);
CREATE INDEX IF NOT EXISTS sessions_expiry ON sessions(expires);
CREATE TABLE IF NOT EXISTS throttles (
  key TEXT PRIMARY KEY,
  bucket INTEGER NOT NULL,
  count INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS monthly_usage (
  source TEXT NOT NULL,
  period TEXT NOT NULL,
  meter TEXT NOT NULL,
  upload_bytes INTEGER NOT NULL CHECK(upload_bytes >= 0),
  download_bytes INTEGER NOT NULL CHECK(download_bytes >= 0),
  started_at INTEGER NOT NULL,
  observed_at INTEGER NOT NULL,
  has_gap INTEGER NOT NULL DEFAULT 0 CHECK(has_gap IN (0, 1)),
  sequence INTEGER NOT NULL,
  PRIMARY KEY(source, period, meter)
);
CREATE TABLE IF NOT EXISTS usage_generations (
  source TEXT NOT NULL,
  period TEXT NOT NULL,
  generation TEXT NOT NULL,
  PRIMARY KEY(source, period)
);
