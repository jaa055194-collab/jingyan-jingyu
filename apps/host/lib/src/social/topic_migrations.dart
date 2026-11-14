import '../storage/migrations.dart';

/// Topic metadata migration, included by the default host. Other callers need accounts,
/// messages (200), groups (300), and direct conversations (302).
const topicMigration = Migration(304, 'group topic metadata references', '''
CREATE TABLE social_topics (
  id TEXT PRIMARY KEY NOT NULL,
  conversation_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
  root_message_id TEXT NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
  created_by TEXT NOT NULL REFERENCES account(id),
  created_at INTEGER NOT NULL
);
CREATE INDEX social_topics_group ON social_topics(conversation_id, created_at, id);
CREATE TABLE social_topic_references (
  topic_id TEXT NOT NULL REFERENCES social_topics(id) ON DELETE CASCADE,
  message_id TEXT NOT NULL REFERENCES messages(message_id) ON DELETE CASCADE,
  associated_by TEXT NOT NULL REFERENCES account(id),
  associated_at INTEGER NOT NULL,
  PRIMARY KEY(topic_id, message_id)
);
''');
