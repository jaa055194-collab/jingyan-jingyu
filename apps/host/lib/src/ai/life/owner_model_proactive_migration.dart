import '../../storage/migrations.dart';

/// Model-driven proactive contact. Separate receiving policy, delivery
/// watermark and global stop; no grants, history or timing slots are backfilled.
/// Unlike the fixed rule greeting this invokes the model under B3, so provider
/// and binding changes must also invalidate an enabled grant.
const ownerModelProactiveMigration = Migration(608, 'owner model proactive', '''
CREATE TABLE owner_model_proactive_stops (
  owner_id TEXT PRIMARY KEY NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
  blocked INTEGER NOT NULL CHECK(blocked IN (0,1))
);
CREATE TABLE owner_model_proactive (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
  local_minute INTEGER NOT NULL CHECK(local_minute BETWEEN 0 AND 1439),
  offset_minutes INTEGER CHECK(offset_minutes BETWEEN -840 AND 840),
  quiet_start INTEGER NOT NULL CHECK(quiet_start BETWEEN 0 AND 1439),
  quiet_end INTEGER NOT NULL CHECK(quiet_end BETWEEN 0 AND 1439 AND quiet_end<>quiet_start),
  interval_minutes INTEGER NOT NULL CHECK(interval_minutes BETWEEN 60 AND 10080),
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
CREATE INDEX owner_model_proactive_due ON owner_model_proactive(due_at) WHERE due_at IS NOT NULL;
CREATE TABLE owner_model_proactive_delivery (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_account_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  last_at INTEGER NOT NULL,
  PRIMARY KEY(owner_id,ai_account_id)
);

-- The base consent already records identity/profile/block/disable invalidations.
-- Never recreate independent permission when the same pair is opened again.
CREATE TRIGGER owner_model_proactive_chat_update AFTER UPDATE ON owner_ai_direct_grants
WHEN OLD.revision IS NOT NEW.revision OR OLD.enabled IS NOT NEW.enabled OR
     OLD.conversation_id IS NOT NEW.conversation_id OR OLD.ai_account_id IS NOT NEW.ai_account_id OR
     OLD.ai_profile_id IS NOT NEW.ai_profile_id OR OLD.owner_account_id IS NOT NEW.owner_account_id
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_chat_delete AFTER DELETE ON owner_ai_direct_grants
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_chat_insert AFTER INSERT ON owner_ai_direct_grants
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=NEW.owner_account_id AND ai_profile_id=NEW.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_pair_update AFTER UPDATE OF account_low,account_high ON direct_conversations
WHEN OLD.account_low IS NOT NEW.account_low OR OLD.account_high IS NOT NEW.account_high
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE conversation_id=OLD.id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_level_update AFTER UPDATE ON ai_social_levels
WHEN NEW.level NOT IN ('L3','L4') OR NEW.owner_id IS NOT OLD.owner_id OR NEW.ai_profile_id IS NOT OLD.ai_profile_id
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_level_delete AFTER DELETE ON ai_social_levels
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_level_insert AFTER INSERT ON ai_social_levels WHEN NEW.level NOT IN ('L3','L4')
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND chat_revision IS NOT NULL;
END;

-- A model call depends on the current chat binding and provider credential.
-- Any change revokes the grant; re-enabling requires a fresh opt-in review.
CREATE TRIGGER owner_model_proactive_binding_insert AFTER INSERT ON model_bindings
WHEN NEW.capability='chat'
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_binding_delete AFTER DELETE ON model_bindings
WHEN OLD.capability='chat'
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL
  WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND chat_revision IS NOT NULL;
END;
CREATE TRIGGER owner_model_proactive_binding_update AFTER UPDATE ON model_bindings
WHEN (OLD.capability='chat' OR NEW.capability='chat') AND
 (OLD.owner_id IS NOT NEW.owner_id OR OLD.ai_profile_id IS NOT NEW.ai_profile_id OR
  OLD.capability IS NOT NEW.capability OR OLD.provider_id IS NOT NEW.provider_id OR OLD.model IS NOT NEW.model)
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL WHERE chat_revision IS NOT NULL AND
    ((OLD.capability='chat' AND owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id) OR
     (NEW.capability='chat' AND owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id));
END;
CREATE TRIGGER owner_model_proactive_provider_update AFTER UPDATE ON providers
WHEN OLD.base_url IS NOT NEW.base_url OR OLD.encrypted_key IS NOT NEW.encrypted_key OR
     OLD.enabled IS NOT NEW.enabled OR OLD.capabilities IS NOT NEW.capabilities
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL WHERE chat_revision IS NOT NULL
    AND owner_id=OLD.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=OLD.owner_id AND provider_id=OLD.id AND capability='chat');
END;
CREATE TRIGGER owner_model_proactive_provider_insert AFTER INSERT ON providers
BEGIN
  UPDATE owner_model_proactive SET revision=revision+1,chat_revision=NULL,conversation_id=NULL,nominal_at=NULL,due_at=NULL WHERE chat_revision IS NOT NULL
    AND owner_id=NEW.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=NEW.owner_id AND provider_id=NEW.id AND capability='chat');
END;
''');
