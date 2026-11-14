import '../storage/migrations.dart';

/// Account-local flags for either canonical conversation kind; no list ordering.
const conversationPreferencesMigration = Migration(
  306,
  'conversation pin preferences',
  '''
CREATE TABLE conversation_preferences (
  account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  conversation_id TEXT NOT NULL,
  pinned INTEGER NOT NULL DEFAULT 0 CHECK(pinned IN (0,1)),
  PRIMARY KEY(account_id,conversation_id)
);
''',
);
