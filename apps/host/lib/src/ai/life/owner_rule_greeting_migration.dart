import '../../storage/migrations.dart';

/// Separate owner receiving policy and delivery watermark; no existing grants,
/// history or timing slots are backfilled.
const ownerRuleGreetingMigration = Migration(605, 'owner rule greeting', '''
CREATE TABLE owner_rule_greeting_stops (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
  blocked INTEGER NOT NULL CHECK(blocked IN (0,1))
);
CREATE TABLE owner_rule_greetings (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
  local_minute INTEGER NOT NULL CHECK(local_minute BETWEEN 0 AND 1439),
  offset_minutes INTEGER CHECK(offset_minutes BETWEEN -840 AND 840),
  quiet_start INTEGER NOT NULL CHECK(quiet_start BETWEEN 0 AND 1439),
  quiet_end INTEGER NOT NULL CHECK(quiet_end BETWEEN 0 AND 1439 AND quiet_end<>quiet_start),
  conversation_id TEXT,
  chat_revision INTEGER,
  nominal_at INTEGER,
  due_at INTEGER,
  observed_through INTEGER NOT NULL CHECK(typeof(observed_through)='integer'),
  CHECK((chat_revision IS NULL AND conversation_id IS NULL AND nominal_at IS NULL AND due_at IS NULL) OR
        (chat_revision IS NOT NULL AND conversation_id IS NOT NULL AND nominal_at IS NOT NULL
          AND due_at IS NOT NULL AND due_at>=nominal_at AND offset_minutes IS NOT NULL)),
  PRIMARY KEY(owner_id,ai_profile_id)
);
CREATE INDEX owner_rule_greeting_due ON owner_rule_greetings(due_at) WHERE due_at IS NOT NULL;
CREATE TABLE owner_rule_greeting_delivery (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  last_day TEXT NOT NULL,
  last_sent_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,ai_account_id)
);

-- The base consent already records identity/profile/block/disable invalidations.
-- Never recreate independent permission when the same pair is opened again.
CREATE TRIGGER owner_rule_greeting_chat_update AFTER UPDATE ON owner_ai_direct_grants
WHEN OLD.revision IS NOT NEW.revision OR OLD.enabled IS NOT NEW.enabled OR
     OLD.conversation_id IS NOT NEW.conversation_id OR OLD.ai_account_id IS NOT NEW.ai_account_id OR
     OLD.ai_profile_id IS NOT NEW.ai_profile_id OR OLD.owner_account_id IS NOT NEW.owner_account_id
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_chat_delete AFTER DELETE ON owner_ai_direct_grants
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_chat_insert AFTER INSERT ON owner_ai_direct_grants
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=NEW.owner_account_id AND ai_profile_id=NEW.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_pair_update AFTER UPDATE OF account_low,account_high ON direct_conversations
WHEN OLD.account_low IS NOT NEW.account_low OR OLD.account_high IS NOT NEW.account_high
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE conversation_id=OLD.id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_level_update AFTER UPDATE ON ai_social_levels
WHEN NEW.level NOT IN ('L3','L4') OR NEW.owner_id IS NOT OLD.owner_id OR NEW.ai_profile_id IS NOT OLD.ai_profile_id
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_level_delete AFTER DELETE ON ai_social_levels
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_rule_greeting_level_insert AFTER INSERT ON ai_social_levels WHEN NEW.level NOT IN ('L3','L4')
BEGIN
  UPDATE owner_rule_greetings SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND chat_revision IS NOT NULL;
END;
''');
