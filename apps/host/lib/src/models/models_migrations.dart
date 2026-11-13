import '../storage/migrations.dart';

/// M05 starts at 500 per the models specification. Registration is explicit.
const List<Migration> modelsMigrations = [
  Migration(500, 'owner scoped model providers', '''
CREATE TABLE providers (
  owner_id TEXT NOT NULL,
  id TEXT NOT NULL,
  name TEXT NOT NULL,
  base_url TEXT NOT NULL,
  encrypted_key TEXT NOT NULL,
  key_mask TEXT NOT NULL,
  enabled INTEGER NOT NULL CHECK(enabled IN (0, 1)),
  capabilities TEXT NOT NULL CHECK(json_valid(capabilities) AND json_type(capabilities) = 'array'),
  PRIMARY KEY (owner_id, id)
);
'''),
];
