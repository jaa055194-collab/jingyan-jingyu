import '../storage/migrations.dart';

/// Explicit ownerTextOnly consent, not friendship and not model dispatch.
/// Rows also tag revoked conversations so legacy friendship cannot revive them.
const ownerAiDirectMigration = Migration(307, 'owner AI direct consent', '''
CREATE TABLE owner_ai_direct_grants (
  owner_account_id TEXT NOT NULL REFERENCES account(id),
  -- Durable identity tombstone: deliberately no FK/cascade to ai_profile.
  -- Profile deletion/rename must retain the tag to prevent legacy fallback.
  ai_profile_id TEXT NOT NULL,
  ai_account_id TEXT NOT NULL REFERENCES account(id),
  conversation_id TEXT NOT NULL UNIQUE REFERENCES direct_conversations(id),
  enabled INTEGER NOT NULL DEFAULT 0 CHECK(enabled IN (0,1)),
  revision INTEGER NOT NULL DEFAULT 0 CHECK(revision >= 0),
  updated_at INTEGER NOT NULL,
  PRIMARY KEY(owner_account_id,ai_profile_id),
  CHECK(owner_account_id <> ai_account_id)
);
CREATE TRIGGER owner_ai_direct_operator_update AFTER UPDATE OF operator_id,ai_id ON ai_operator
WHEN OLD.operator_id <> NEW.operator_id OR OLD.ai_id <> NEW.ai_id
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE ai_account_id=OLD.ai_id AND enabled=1;
END;
CREATE TRIGGER owner_ai_direct_operator_delete AFTER DELETE ON ai_operator
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE ai_account_id=OLD.ai_id AND enabled=1;
END;
CREATE TRIGGER owner_ai_direct_disable AFTER UPDATE OF disabled,kind ON account
WHEN NEW.disabled=1 OR OLD.kind<>NEW.kind
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE (owner_account_id=OLD.id OR ai_account_id=OLD.id) AND enabled=1;
END;
CREATE TRIGGER owner_ai_direct_block AFTER INSERT ON account_blocks
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE enabled=1 AND (
   (owner_account_id=NEW.blocker AND ai_account_id=NEW.target) OR
   (owner_account_id=NEW.target AND ai_account_id=NEW.blocker));
END;
CREATE TRIGGER owner_ai_direct_block_update AFTER UPDATE OF blocker,target ON account_blocks
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE enabled=1 AND (
   (owner_account_id=NEW.blocker AND ai_account_id=NEW.target) OR
   (owner_account_id=NEW.target AND ai_account_id=NEW.blocker));
END;
''');

/// Numeric ordering matters: canonical ai_profile is introduced by migration 501.
/// Keep these identity triggers in an explicit post-501 migration, never runtime DDL.
const ownerAiProfileInvalidationMigration = Migration(
  505,
  'owner AI profile consent invalidation',
  '''
CREATE TRIGGER owner_ai_direct_profile_update AFTER UPDATE OF id,account_id ON ai_profile
WHEN OLD.id<>NEW.id OR OLD.account_id<>NEW.account_id
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE ai_profile_id=OLD.id AND enabled=1;
END;
CREATE TRIGGER owner_ai_direct_profile_delete AFTER DELETE ON ai_profile
BEGIN
 UPDATE owner_ai_direct_grants SET enabled=0,revision=revision+1
 WHERE ai_profile_id=OLD.id AND enabled=1;
END;
''',
);
