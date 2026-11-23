import '../storage/migrations.dart';

/// Append-only migrations allocated to M02 (100–199).
const List<Migration> accountsMigrations = [
  Migration(100, 'accounts and hashed credentials', '''
CREATE TABLE account (
  id TEXT PRIMARY KEY NOT NULL,
  display_name TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('human', 'ai')),
  is_admin INTEGER NOT NULL CHECK(is_admin IN (0, 1)),
  disabled INTEGER NOT NULL CHECK(disabled IN (0, 1)),
  password_hash TEXT,
  failed_passwords INTEGER NOT NULL CHECK(failed_passwords >= 0),
  locked_until INTEGER NOT NULL,
  CHECK((kind = 'human' AND password_hash IS NOT NULL) OR
        (kind = 'ai' AND password_hash IS NULL AND is_admin = 0))
);
CREATE UNIQUE INDEX account_single_admin ON account(is_admin) WHERE is_admin = 1;
CREATE INDEX account_kind ON account(kind);
CREATE TABLE ai_operator (
  ai_id TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  operator_id TEXT NOT NULL REFERENCES account(id) ON DELETE RESTRICT,
  CHECK(ai_id <> operator_id)
);
CREATE INDEX ai_operator_operator ON ai_operator(operator_id);
CREATE TABLE device (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  device_name TEXT NOT NULL,
  access_hash TEXT NOT NULL UNIQUE,
  access_expires INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);
CREATE INDEX device_account_last_used ON device(account_id, last_used_at);
CREATE TABLE refresh_token (
  device_id TEXT PRIMARY KEY NOT NULL REFERENCES device(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL
);
CREATE INDEX refresh_token_expiry ON refresh_token(expires_at);
CREATE TABLE invite (
  id TEXT PRIMARY KEY NOT NULL,
  code_hash TEXT NOT NULL UNIQUE,
  expires_at INTEGER NOT NULL,
  max_uses INTEGER NOT NULL CHECK(max_uses > 0),
  used_count INTEGER NOT NULL CHECK(used_count >= 0 AND used_count <= max_uses),
  revoked_at INTEGER
);
CREATE INDEX invite_expiry ON invite(expires_at);
'''),
  // Keep the original account column layout for legacy positional inserts.
  Migration(101, 'logical owner AI removal state', '''
CREATE TABLE removed_ai_accounts (
  account_id TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  removed_at INTEGER NOT NULL
);
'''),
];
