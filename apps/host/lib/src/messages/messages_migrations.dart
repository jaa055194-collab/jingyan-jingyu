import '../storage/migrations.dart';

/// Append-only migrations allocated to M03 (200–299).
const List<Migration> messagesMigrations = [
  Migration(200, 'persistent message store', '''
CREATE TABLE message_heads (
  conversation_id TEXT PRIMARY KEY NOT NULL,
  seq INTEGER NOT NULL CHECK(seq >= 0)
);
CREATE TABLE messages (
  message_id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL,
  seq INTEGER NOT NULL CHECK(seq > 0),
  sender_id TEXT NOT NULL,
  client_msg_id TEXT NOT NULL CHECK(length(client_msg_id) BETWEEN 1 AND 64),
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  sent_at TEXT NOT NULL,
  UNIQUE(conversation_id, seq),
  UNIQUE(conversation_id, sender_id, client_msg_id)
);
CREATE TABLE message_acks (
  conversation_id TEXT NOT NULL,
  device_id TEXT NOT NULL,
  seq INTEGER NOT NULL CHECK(seq >= 0),
  PRIMARY KEY(conversation_id, device_id)
);
'''),
  Migration(205, 'message recall state', '''
ALTER TABLE messages ADD COLUMN recalled_at TEXT;
'''),
  Migration(206, 'message edit history', '''
CREATE TABLE message_edits (
  edit_id TEXT PRIMARY KEY NOT NULL,
  message_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  editor_id TEXT NOT NULL,
  body TEXT NOT NULL,
  edited_at TEXT NOT NULL
);
CREATE INDEX idx_message_edits_message ON message_edits(message_id);
'''),
  Migration(207, 'scheduled messages', '''
CREATE TABLE scheduled_messages (
  id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL,
  sender_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  body TEXT NOT NULL,
  deliver_at TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','delivered','cancelled','expired')),
  created_at TEXT NOT NULL
);
CREATE INDEX idx_scheduled_due ON scheduled_messages(status, deliver_at);
'''),
  Migration(208, 'message reactions', '''
CREATE TABLE message_reactions (
  message_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  emoji TEXT NOT NULL CHECK(length(emoji) BETWEEN 1 AND 32),
  created_at TEXT NOT NULL,
  PRIMARY KEY(message_id, account_id, emoji)
);
CREATE INDEX idx_message_reactions_message ON message_reactions(message_id);
'''),
];
