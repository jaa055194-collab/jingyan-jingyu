import '../storage/migrations.dart';

/// Metadata-only consent stamp for a freshly accepted owner text source.
/// No FK cascade: historical stamps must not disappear or be retroactively
/// reclaimed when identities, profiles or grants change.
const ownerAiDirectSourceMigration = Migration(
  216,
  'owner AI direct source consent stamp',
  '''
CREATE TABLE owner_ai_direct_sources (
  source_message_id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL,
  ai_profile_id TEXT NOT NULL,
  ai_account_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  grant_revision INTEGER NOT NULL
    CHECK(typeof(grant_revision)='integer' AND grant_revision>=0)
);
CREATE INDEX owner_ai_direct_sources_owner
  ON owner_ai_direct_sources(owner_account_id,conversation_id);
''',
);
