import '../storage/migrations.dart';

/// Explicit opt-in M04 migration; register alongside canonical accounts.
const friendshipMigration = Migration(301, 'friend requests and blocking', '''
CREATE TABLE friend_requests (
  sender TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  target TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  status TEXT NOT NULL CHECK(status IN ('pending','accepted','denied')),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(sender,target),
  CHECK(sender <> target)
);
CREATE INDEX friend_requests_target ON friend_requests(target,status);
CREATE TABLE friendships (
  account_low TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  account_high TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(account_low,account_high),
  CHECK(account_low < account_high)
);
CREATE TABLE account_blocks (
  blocker TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  target TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  created_at INTEGER NOT NULL,
  PRIMARY KEY(blocker,target),
  CHECK(blocker <> target)
);
CREATE INDEX account_blocks_target ON account_blocks(target);
''');
