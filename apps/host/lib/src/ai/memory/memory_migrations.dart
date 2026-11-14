import '../../storage/migrations.dart';

/// Explicit opt-in migration; the host composition root registers this later.
const memoryMigrations = [
  Migration(600, 'encrypted internal memory and source links', '''
CREATE TABLE encrypted_memory (
  id TEXT PRIMARY KEY NOT NULL,
  owning_operator_id TEXT NOT NULL REFERENCES account(id),
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id),
  source_account_id TEXT NOT NULL REFERENCES account(id),
  about_account_id TEXT REFERENCES account(id),
  scope_key TEXT NOT NULL,
  tier TEXT NOT NULL CHECK(tier IN ('t0','t1','t2')),
  status TEXT NOT NULL CHECK(status IN ('pending','active','rejected','superseded','archived','deleted')),
  evidence TEXT NOT NULL CHECK(evidence IN ('userConfirmed','userStated','inferred','modelClaim')),
  encrypted_body TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX memory_retrieve ON encrypted_memory(owning_operator_id,ai_profile_id,status,tier,created_at);
CREATE TABLE memory_source_messages (
  memory_id TEXT NOT NULL REFERENCES encrypted_memory(id),
  source_message_id TEXT NOT NULL REFERENCES messages(message_id),
  PRIMARY KEY(memory_id,source_message_id)
);
'''),
];
