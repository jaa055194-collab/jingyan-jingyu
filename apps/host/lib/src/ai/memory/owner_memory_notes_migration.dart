import '../../storage/migrations.dart';

/// Manual owner-confirmed notes and a separate use grant. It never reads the
/// chat history, group data, persona, other AI, or existing preference grants.
const ownerMemoryNotesMigration = Migration(
  606,
  'owner memory notes and use grant',
  '''
CREATE TABLE owner_memory_notes (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  encrypted_body TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX owner_memory_notes_list ON owner_memory_notes(owner_id,ai_profile_id,created_at);
CREATE TABLE owner_memory_note_settings (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  revision INTEGER NOT NULL CHECK(typeof(revision)='integer' AND revision>=0),
  enabled INTEGER NOT NULL CHECK(enabled IN (0,1)),
  target_token TEXT,
  PRIMARY KEY(owner_id,ai_profile_id)
);
CREATE INDEX owner_memory_note_settings_ai ON owner_memory_note_settings(ai_profile_id);

-- Independent recipient incarnation. This is intentionally not the preference
-- table: a memory grant cannot be enabled or retained by a reply-preference
-- setting, and changing either target revokes this grant separately.
CREATE TABLE owner_memory_target_epochs (
  owner_id TEXT NOT NULL,
  ai_profile_id TEXT NOT NULL,
  epoch TEXT NOT NULL,
  PRIMARY KEY(owner_id,ai_profile_id)
);
INSERT INTO owner_memory_target_epochs
SELECT owner_id,ai_profile_id,lower(hex(randomblob(24))) FROM model_bindings
WHERE capability='chat';

CREATE TRIGGER owner_memory_note_binding_insert AFTER INSERT ON model_bindings
WHEN NEW.capability='chat'
BEGIN
  INSERT INTO owner_memory_target_epochs VALUES(NEW.owner_id,NEW.ai_profile_id,lower(hex(randomblob(24))))
    ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET epoch=excluded.epoch;
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1
    WHERE owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_memory_note_binding_delete AFTER DELETE ON model_bindings
WHEN OLD.capability='chat'
BEGIN
  DELETE FROM owner_memory_target_epochs WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id;
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_memory_note_binding_update AFTER UPDATE ON model_bindings
WHEN (OLD.capability='chat' OR NEW.capability='chat') AND
 (OLD.owner_id IS NOT NEW.owner_id OR OLD.ai_profile_id IS NOT NEW.ai_profile_id OR
  OLD.capability IS NOT NEW.capability OR OLD.provider_id IS NOT NEW.provider_id OR OLD.model IS NOT NEW.model)
BEGIN
  DELETE FROM owner_memory_target_epochs WHERE OLD.capability='chat' AND owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id;
  INSERT INTO owner_memory_target_epochs
    SELECT NEW.owner_id,NEW.ai_profile_id,lower(hex(randomblob(24))) WHERE NEW.capability='chat'
    ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET epoch=excluded.epoch;
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL AND
    ((OLD.capability='chat' AND owner_id=OLD.owner_id AND ai_profile_id=OLD.ai_profile_id) OR
     (NEW.capability='chat' AND owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id));
END;
CREATE TRIGGER owner_memory_note_provider_update AFTER UPDATE ON providers
WHEN OLD.base_url IS NOT NEW.base_url OR OLD.encrypted_key IS NOT NEW.encrypted_key OR
     OLD.enabled IS NOT NEW.enabled OR OLD.capabilities IS NOT NEW.capabilities
BEGIN
  UPDATE owner_memory_target_epochs SET epoch=lower(hex(randomblob(24)))
    WHERE owner_id=OLD.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=OLD.owner_id AND provider_id=OLD.id AND capability='chat');
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL
    AND owner_id=OLD.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=OLD.owner_id AND provider_id=OLD.id AND capability='chat');
END;
CREATE TRIGGER owner_memory_note_provider_insert AFTER INSERT ON providers
BEGIN
  UPDATE owner_memory_target_epochs SET epoch=lower(hex(randomblob(24)))
    WHERE owner_id=NEW.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=NEW.owner_id AND provider_id=NEW.id AND capability='chat');
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1 WHERE target_token IS NOT NULL
    AND owner_id=NEW.owner_id AND ai_profile_id IN
      (SELECT ai_profile_id FROM model_bindings WHERE owner_id=NEW.owner_id AND provider_id=NEW.id AND capability='chat');
END;
CREATE TRIGGER owner_memory_note_direct_update AFTER UPDATE ON owner_ai_direct_grants
WHEN OLD.revision IS NOT NEW.revision OR OLD.enabled IS NOT NEW.enabled OR
     OLD.conversation_id IS NOT NEW.conversation_id OR OLD.ai_account_id IS NOT NEW.ai_account_id OR
     OLD.ai_profile_id IS NOT NEW.ai_profile_id OR OLD.owner_account_id IS NOT NEW.owner_account_id
BEGIN
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_memory_note_direct_delete AFTER DELETE ON owner_ai_direct_grants
BEGIN
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1
    WHERE owner_id=OLD.owner_account_id AND ai_profile_id=OLD.ai_profile_id AND target_token IS NOT NULL;
END;
CREATE TRIGGER owner_memory_note_direct_insert AFTER INSERT ON owner_ai_direct_grants
BEGIN
  UPDATE owner_memory_note_settings SET enabled=0,target_token=NULL,revision=revision+1
    WHERE owner_id=NEW.owner_account_id AND ai_profile_id=NEW.ai_profile_id AND target_token IS NOT NULL;
END;

-- No backfill: existing messages, duplicate/pending attempts or messages
-- accepted before opt-in cannot acquire notes. Every note mutation bumps
-- settings.revision, so an accepted source becomes unusable after edits.
CREATE TABLE owner_memory_note_sources (
  source_message_id TEXT PRIMARY KEY NOT NULL REFERENCES owner_ai_direct_sources(source_message_id) ON DELETE CASCADE,
  settings_revision INTEGER NOT NULL,
  target_token TEXT NOT NULL
);
CREATE TRIGGER owner_memory_note_accept AFTER INSERT ON owner_ai_direct_sources
BEGIN
  INSERT INTO owner_memory_note_sources(source_message_id,settings_revision,target_token)
  SELECT NEW.source_message_id,s.revision,s.target_token FROM owner_memory_note_settings s
  WHERE s.owner_id=NEW.owner_account_id AND s.ai_profile_id=NEW.ai_profile_id
    AND s.enabled=1 AND s.target_token IS NOT NULL;
END;
''',
);
