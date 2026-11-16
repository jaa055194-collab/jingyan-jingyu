import '../storage/migrations.dart';

/// Lead-allocated migration 215. Opt-in: no default assembly change here.
const ownerReplyAttemptsMigration = Migration(
  215,
  'owner reply attempt ledger',
  '''
CREATE TABLE owner_reply_attempts (
  source_message_id TEXT NOT NULL,
  ai_profile_id TEXT NOT NULL,
  owner_account_id TEXT NOT NULL,
  ai_account_id TEXT NOT NULL,
  conversation_id TEXT NOT NULL,
  grant_revision INTEGER NOT NULL CHECK(typeof(grant_revision) = 'integer' AND grant_revision >= 0),
  request_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','completed','failed','discarded')),
  reply_id TEXT,
  safe_failure_code TEXT CHECK(safe_failure_code IS NULL OR safe_failure_code IN (
    'invalidArgument','unauthenticated','forbidden','notFound','conflict',
    'rateLimited','budgetExhausted','modelUnavailable','internal','unavailable'
  )),
  PRIMARY KEY(source_message_id, ai_profile_id),
  CHECK(typeof(source_message_id) = 'text' AND instr(source_message_id,char(0)) = 0 AND length(CAST(source_message_id AS BLOB)) BETWEEN 1 AND 64 AND source_message_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(typeof(ai_profile_id) = 'text' AND instr(ai_profile_id,char(0)) = 0 AND length(CAST(ai_profile_id AS BLOB)) BETWEEN 1 AND 64 AND ai_profile_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(typeof(owner_account_id) = 'text' AND instr(owner_account_id,char(0)) = 0 AND length(CAST(owner_account_id AS BLOB)) BETWEEN 1 AND 64 AND owner_account_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(typeof(ai_account_id) = 'text' AND instr(ai_account_id,char(0)) = 0 AND length(CAST(ai_account_id AS BLOB)) BETWEEN 1 AND 64 AND ai_account_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(typeof(conversation_id) = 'text' AND instr(conversation_id,char(0)) = 0 AND length(CAST(conversation_id AS BLOB)) BETWEEN 1 AND 64 AND conversation_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(typeof(request_id) = 'text' AND instr(request_id,char(0)) = 0 AND length(CAST(request_id AS BLOB)) BETWEEN 1 AND 64 AND request_id NOT GLOB '*[^A-Za-z0-9_-]*'),
  CHECK(reply_id IS NULL OR (typeof(reply_id) = 'text' AND instr(reply_id,char(0)) = 0 AND length(CAST(reply_id AS BLOB)) BETWEEN 1 AND 64 AND reply_id NOT GLOB '*[^A-Za-z0-9_-]*')),
  CHECK(
    (status = 'pending' AND reply_id IS NULL AND safe_failure_code IS NULL) OR
    (status = 'completed' AND reply_id IS NOT NULL AND safe_failure_code IS NULL) OR
    (status = 'failed' AND reply_id IS NULL AND safe_failure_code IS NOT NULL) OR
    (status = 'discarded' AND reply_id IS NULL)
  )
);
''',
);
