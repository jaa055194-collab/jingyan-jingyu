import '../storage/migrations.dart';

/// Explicitly registered after account 100, provider 500 and identity 501.
const Migration bindingMigration = Migration(
  502,
  'owner scoped AI bindings',
  '''
CREATE TABLE model_bindings (
  owner_id TEXT NOT NULL,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  capability TEXT NOT NULL CHECK(capability IN ('chat','chatFast','vision','imageGen','tts','asr','embedding')),
  provider_id TEXT NOT NULL,
  model TEXT NOT NULL CHECK(length(trim(model)) > 0),
  PRIMARY KEY (owner_id, ai_profile_id, capability),
  FOREIGN KEY (owner_id, provider_id) REFERENCES providers(owner_id, id) ON DELETE RESTRICT
);
CREATE INDEX model_bindings_provider ON model_bindings(owner_id, provider_id);
''',
);
