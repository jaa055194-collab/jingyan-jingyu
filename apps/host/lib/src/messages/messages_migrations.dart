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
  Migration(209, 'message pins', '''
CREATE TABLE message_pins (
  conversation_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  pinned_at TEXT NOT NULL,
  PRIMARY KEY(conversation_id, message_id)
);
CREATE INDEX idx_message_pins_conversation ON message_pins(conversation_id);
'''),
  Migration(210, 'encrypted search blind index', '''
CREATE TABLE message_search_tokens (
  message_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  token_hmac TEXT NOT NULL,
  PRIMARY KEY(message_id, token_hmac)
);
CREATE INDEX idx_search_tokens_hmac ON message_search_tokens(token_hmac);
CREATE TABLE search_index_key (
  id TEXT PRIMARY KEY NOT NULL,
  sealed TEXT NOT NULL
);
'''),
  Migration(211, 'favorites', '''
CREATE TABLE favorites (
  id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('text','message','link','file')),
  message_id TEXT,
  conversation_id TEXT,
  title TEXT,
  content TEXT,
  created_at TEXT NOT NULL,
  CHECK(
    (kind = 'message' AND message_id IS NOT NULL AND conversation_id IS NOT NULL AND content IS NULL)
    OR (kind != 'message' AND message_id IS NULL AND conversation_id IS NULL AND content IS NOT NULL)
  )
);
CREATE INDEX idx_favorites_owner ON favorites(owner_account_id);
'''),
  Migration(212, 'favorite search blind index', '''
CREATE TABLE favorite_search_tokens (
  favorite_id TEXT NOT NULL,
  owner_account_id TEXT NOT NULL,
  token_hmac TEXT NOT NULL,
  PRIMARY KEY(favorite_id, token_hmac)
);
CREATE INDEX idx_favorite_search_tokens_owner
  ON favorite_search_tokens(owner_account_id, token_hmac);
'''),
  Migration(213, 'attachments index and chunked upload', '''
CREATE TABLE attachments (
  id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL,
  conversation_id TEXT,
  kind TEXT NOT NULL,
  mime TEXT NOT NULL,
  size INTEGER NOT NULL CHECK(size >= 0),
  sha256 TEXT NOT NULL,
  rel_path TEXT NOT NULL,
  width INTEGER,
  height INTEGER,
  duration_ms INTEGER,
  extracted_text TEXT,
  extraction_status TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_attachments_owner ON attachments(owner_account_id);
CREATE TABLE attachment_uploads (
  id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL,
  conversation_id TEXT,
  kind TEXT NOT NULL,
  mime TEXT NOT NULL,
  declared_size INTEGER NOT NULL CHECK(declared_size >= 0),
  received_bytes INTEGER NOT NULL DEFAULT 0,
  next_chunk INTEGER NOT NULL DEFAULT 0,
  status TEXT NOT NULL CHECK(status IN ('pending','completed','aborted')),
  created_at TEXT NOT NULL
);
CREATE INDEX idx_attachment_uploads_owner ON attachment_uploads(owner_account_id);
CREATE TABLE attachment_upload_chunks (
  upload_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  size INTEGER NOT NULL CHECK(size >= 0),
  PRIMARY KEY(upload_id, chunk_index)
);
'''),
  Migration(214, 'favorite tags and note', '''
ALTER TABLE favorites ADD COLUMN tags TEXT;
ALTER TABLE favorites ADD COLUMN note TEXT;
'''),
];
