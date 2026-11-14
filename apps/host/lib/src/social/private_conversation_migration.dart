import '../storage/migrations.dart';

/// Explicit opt-in M04 migration, registered after canonical accounts and friends.
/// Direct conversations are separate from the group membership model in 300.
const privateConversationMigration = Migration(302, 'private conversations', '''
CREATE TABLE direct_conversations (
  id TEXT PRIMARY KEY NOT NULL,
  account_low TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  account_high TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  UNIQUE(account_low,account_high),
  CHECK(account_low < account_high)
);
CREATE INDEX direct_conversations_high ON direct_conversations(account_high);
''');
