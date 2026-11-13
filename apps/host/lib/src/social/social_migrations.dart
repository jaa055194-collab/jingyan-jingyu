import '../storage/migrations.dart';

/// M04 owns versions 300–399. The host combines these with storage migrations.
const List<Migration> socialMigrations = [
  Migration(300, 'social conversations and membership', '''
CREATE TABLE social_conversations (
  id TEXT PRIMARY KEY,
  owner_account_id TEXT NOT NULL,
  name TEXT NOT NULL,
  history_visibility TEXT NOT NULL CHECK (history_visibility IN ('all', 'joined')),
  created_at INTEGER NOT NULL
);
CREATE TABLE social_members (
  conversation_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
  account_id TEXT NOT NULL,
  joined_at INTEGER NOT NULL,
  first_visible_seq INTEGER NOT NULL CHECK (first_visible_seq >= 1),
  PRIMARY KEY (conversation_id, account_id)
);
CREATE INDEX social_members_account ON social_members(account_id, conversation_id);
'''),
];
