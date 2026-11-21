import '../../storage/migrations.dart';

/// Separate purpose grant. It never alters the meaning or wire shape of the
/// existing ownerTextOnly grant or gives a model access to general memory.
const ownerReplyPreferencesMigration = Migration(
  604,
  'owner reply preference consent and accepted-source fence',
  '''
CREATE TABLE owner_reply_preferences (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>0),
  encrypted_choices TEXT,
  target_token TEXT,
  PRIMARY KEY(owner_id, ai_profile_id),
  CHECK(target_token IS NULL OR encrypted_choices IS NOT NULL)
);
CREATE INDEX owner_reply_preferences_ai ON owner_reply_preferences(ai_profile_id);

-- A separate, random incarnation for the existing main chat binding and its
-- recipient configuration. Using a side table leaves old positional INSERTs
-- and column shapes intact. No secret (or digest of a secret) is stored here.
CREATE TABLE owner_reply_target_epochs (
  owner_id TEXT NOT NULL,
  ai_profile_id TEXT NOT NULL,
  epoch TEXT NOT NULL,
  PRIMARY KEY(owner_id, ai_profile_id)
);
INSERT INTO owner_reply_target_epochs
SELECT owner_id, ai_profile_id, lower(hex(randomblob(24))) FROM model_bindings
WHERE capability='chat';

CREATE TRIGGER owner_reply_preference_binding_insert AFTER INSERT ON model_bindings
WHEN NEW.capability='chat'
BEGIN
  INSERT INTO owner_reply_target_epochs VALUES(NEW.owner_id,NEW.ai_profile_id,lower(hex(randomblob(24))))
    ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET epoch=excluded.epoch;
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1
    WHERE owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_reply_preference_binding_delete AFTER DELETE ON model_bindings
WHEN OLD.capability='chat'
BEGIN
  DELETE FROM owner_reply_target_epochs WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id;
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_reply_preference_binding_update AFTER UPDATE ON model_bindings
WHEN (OLD.capability='chat' OR NEW.capability='chat') AND
 (OLD.owner_id IS NOT NEW.owner_id OR OLD.ai_profile_id IS NOT NEW.ai_profile_id OR
  OLD.capability IS NOT NEW.capability OR OLD.provider_id IS NOT NEW.provider_id OR OLD.model IS NOT NEW.model)
BEGIN
  DELETE FROM owner_reply_target_epochs WHERE OLD.capability='chat' AND owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id;
  INSERT INTO owner_reply_target_epochs
    SELECT NEW.owner_id, NEW.ai_profile_id, lower(hex(randomblob(24))) WHERE NEW.capability='chat'
    ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET epoch=excluded.epoch;
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL AND
    ((OLD.capability='chat' AND owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id) OR
     (NEW.capability='chat' AND owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id));
END;

-- Provider edits rotate the offer even before a grant exists. Name-only edits
-- don't change the recipient. A key change changes the recipient account even
-- when its displayed mask, ID, origin and model happen to stay the same.
CREATE TRIGGER owner_reply_preference_provider_update AFTER UPDATE ON providers
WHEN OLD.base_url IS NOT NEW.base_url OR OLD.encrypted_key IS NOT NEW.encrypted_key OR
     OLD.enabled IS NOT NEW.enabled OR OLD.capabilities IS NOT NEW.capabilities
BEGIN
  UPDATE owner_reply_target_epochs SET epoch=lower(hex(randomblob(24)))
    WHERE owner_id=OLD.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=OLD.owner_id AND provider_id=OLD.id AND capability='chat');
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL
    AND owner_id=OLD.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=OLD.owner_id AND provider_id=OLD.id AND capability='chat');
END;
CREATE TRIGGER owner_reply_preference_provider_insert AFTER INSERT ON providers
BEGIN
  UPDATE owner_reply_target_epochs SET epoch=lower(hex(randomblob(24)))
    WHERE owner_id=NEW.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=NEW.owner_id AND provider_id=NEW.id AND capability='chat');
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL
    AND owner_id=NEW.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=NEW.owner_id AND provider_id=NEW.id AND capability='chat');
END;

-- Existing consent triggers already turn transfer, block, disable and profile
-- changes into durable ownerTextOnly revocations. Revocation here is separate:
-- returning to the prior pairing/provider never re-enables the preference grant.
CREATE TRIGGER owner_reply_preference_direct_update AFTER UPDATE ON owner_ai_direct_grants
WHEN OLD.revision IS NOT NEW.revision OR OLD.enabled IS NOT NEW.enabled OR
     OLD.conversation_id IS NOT NEW.conversation_id OR OLD.ai_account_id IS NOT NEW.ai_account_id
BEGIN
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_reply_preference_direct_delete AFTER DELETE ON owner_ai_direct_grants
BEGIN
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_reply_preference_direct_insert AFTER INSERT ON owner_ai_direct_grants
BEGIN
  UPDATE owner_reply_preferences SET target_token=NULL,revision=revision+1
    WHERE owner_id=NEW.owner_account_id AND ai_profile_id=NEW.ai_profile_id AND target_token IS NOT NULL;
END;

-- No backfill: delayed attempts, duplicates or accepted pre-opt-in text cannot
-- acquire the grant later. This executes inside the existing acceptance Tx.
CREATE TABLE owner_reply_preference_sources (
  source_message_id TEXT PRIMARY KEY NOT NULL REFERENCES owner_ai_direct_sources(source_message_id) ON DELETE CASCADE,
  preference_revision INTEGER NOT NULL,
  target_token TEXT NOT NULL
);
CREATE TRIGGER owner_reply_preference_accept AFTER INSERT ON owner_ai_direct_sources
BEGIN
  INSERT INTO owner_reply_preference_sources(source_message_id,preference_revision,target_token)
  SELECT NEW.source_message_id, p.revision, p.target_token
  FROM owner_reply_preferences p WHERE p.owner_id=NEW.owner_account_id
    AND p.ai_profile_id=NEW.ai_profile_id AND p.target_token IS NOT NULL;
END;
''',
);
