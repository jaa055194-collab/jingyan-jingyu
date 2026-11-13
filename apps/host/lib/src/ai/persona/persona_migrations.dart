import '../../storage/migrations.dart';

/// Explicit opt-in Migration601; registration belongs to the composition root.
/// History is append-only, including operator edits, reverts and lock changes.
const List<Migration> personaMigrations = [
  Migration(601, 'encrypted persona cards and immutable history', '''
CREATE TABLE persona_cards (
  ai_profile_id TEXT PRIMARY KEY NOT NULL REFERENCES ai_profile(id),
  owner_id TEXT NOT NULL REFERENCES account(id),
  version INTEGER NOT NULL CHECK(version > 0),
  locked INTEGER NOT NULL CHECK(locked IN (0, 1)),
  encrypted_card TEXT NOT NULL,
  UNIQUE(owner_id, ai_profile_id)
);
CREATE TABLE persona_history (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_profile_id TEXT NOT NULL,
  version INTEGER NOT NULL CHECK(version > 0),
  kind TEXT NOT NULL CHECK(kind IN ('initialize','selfIterate','edit','revert','lock')),
  actor_id TEXT NOT NULL REFERENCES account(id),
  at TEXT NOT NULL,
  locked_before INTEGER CHECK(locked_before IN (0, 1)),
  locked_after INTEGER NOT NULL CHECK(locked_after IN (0, 1)),
  reverts_change_id TEXT REFERENCES persona_history(id),
  encrypted_before TEXT NOT NULL,
  encrypted_after TEXT NOT NULL,
  encrypted_diff TEXT NOT NULL,
  encrypted_reason TEXT NOT NULL,
  encrypted_evidence TEXT NOT NULL,
  UNIQUE(owner_id, ai_profile_id, version),
  FOREIGN KEY(owner_id, ai_profile_id) REFERENCES persona_cards(owner_id, ai_profile_id),
  CHECK((kind = 'initialize' AND version = 1 AND locked_before IS NULL) OR
        (kind <> 'initialize' AND version > 1 AND locked_before IS NOT NULL)),
  CHECK((kind = 'revert' AND reverts_change_id IS NOT NULL) OR
        (kind <> 'revert' AND reverts_change_id IS NULL))
);
CREATE TRIGGER persona_history_no_replace BEFORE INSERT ON persona_history
WHEN EXISTS (
  SELECT 1 FROM persona_history
  WHERE id=NEW.id OR
    (owner_id=NEW.owner_id AND ai_profile_id=NEW.ai_profile_id AND version=NEW.version)
)
BEGIN SELECT RAISE(ABORT, 'persona history is immutable'); END;
CREATE TRIGGER persona_history_no_update BEFORE UPDATE ON persona_history
BEGIN SELECT RAISE(ABORT, 'persona history is immutable'); END;
CREATE TRIGGER persona_history_no_delete BEFORE DELETE ON persona_history
BEGIN SELECT RAISE(ABORT, 'persona history is immutable'); END;
'''),
];
