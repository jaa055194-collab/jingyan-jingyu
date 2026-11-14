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
];
