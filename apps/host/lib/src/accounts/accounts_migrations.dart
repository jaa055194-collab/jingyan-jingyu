import '../storage/migrations.dart';

/// M02 owns versions 100–199. Include alongside M01's allMigrations at open.
const List<Migration> accountsMigrations = [
  Migration(100, 'SQL accounts and sessions', '''
CREATE TABLE account (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('human', 'ai')),
  display_name TEXT NOT NULL,
  password_hash TEXT NOT NULL,
  is_admin INTEGER NOT NULL DEFAULT 0 CHECK(is_admin IN (0, 1)),
  enabled INTEGER NOT NULL DEFAULT 1 CHECK(enabled IN (0, 1)),
  failed_logins INTEGER NOT NULL DEFAULT 0 CHECK(failed_logins >= 0),
  locked_until INTEGER
);
CREATE UNIQUE INDEX account_single_admin ON account(is_admin) WHERE is_admin = 1;
CREATE TABLE ai_operator (
  ai_id TEXT PRIMARY KEY REFERENCES account(id),
  human_id TEXT NOT NULL REFERENCES account(id)
);
CREATE INDEX ai_operator_human ON ai_operator(human_id);
CREATE TABLE device (
  id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL REFERENCES account(id),
  device_name TEXT NOT NULL,
  access_hash TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL,
  revoked_at INTEGER
);
CREATE INDEX device_account_lru ON device(account_id, revoked_at, last_used_at);
CREATE TABLE invite (
  id TEXT PRIMARY KEY,
  code_hash TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL,
  max_uses INTEGER NOT NULL CHECK(max_uses > 0),
  used_count INTEGER NOT NULL DEFAULT 0 CHECK(used_count >= 0 AND used_count <= max_uses),
  revoked_at INTEGER
);
CREATE TABLE refresh_token (
  device_id TEXT PRIMARY KEY REFERENCES device(id),
  token_hash TEXT NOT NULL UNIQUE
);
'''),
];
