import '../../storage/migrations.dart';

/// Explicit opt-in M06 migration; composition-root registration is separate.
/// State is machine-readable enums and numbers; no prose or secrets are stored.
const List<Migration> lifeMigrations = [
  Migration(602, 'durable rule life engine and activity evidence', '''
CREATE TABLE life_state (
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id),
  last_heartbeat_at TEXT NOT NULL,
  last_activity_at TEXT NOT NULL,
  activity TEXT NOT NULL CHECK(activity IN ('sleeping','waking','washing','cooking','eating','reading','writing','daydreaming','tidying','wateringPlants','lookingOutside','listeningToMusic','bathing','writingDiary','waitingForYou')),
  location TEXT NOT NULL CHECK(location IN ('home','neighborhood','friendsHome','villa')),
  energy INTEGER NOT NULL CHECK(energy BETWEEN 0 AND 100),
  mood TEXT NOT NULL CHECK(mood IN ('calm','happy','sad','tired','focused','curious','neutral')),
  presence TEXT NOT NULL CHECK(presence IN ('available','busy','away','offline')),
  focus INTEGER NOT NULL CHECK(focus BETWEEN 0 AND 100),
  PRIMARY KEY(owner_id, ai_profile_id)
);
CREATE TABLE activity_log (
  id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL REFERENCES account(id),
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id),
  kind TEXT NOT NULL CHECK(kind IN ('activity','gap')),
  at TEXT NOT NULL,
  gap_start TEXT,
  activity TEXT CHECK(activity IS NULL OR activity IN ('sleeping','waking','washing','cooking','eating','reading','writing','daydreaming','tidying','wateringPlants','lookingOutside','listeningToMusic','bathing','writingDiary','waitingForYou')),
  location TEXT CHECK(location IS NULL OR location IN ('home','neighborhood','friendsHome','villa')),
  energy INTEGER CHECK(energy IS NULL OR energy BETWEEN 0 AND 100),
  mood TEXT CHECK(mood IS NULL OR mood IN ('calm','happy','sad','tired','focused','curious','neutral')),
  presence TEXT CHECK(presence IS NULL OR presence IN ('available','busy','away','offline')),
  focus INTEGER CHECK(focus BETWEEN 0 AND 100),
  CHECK((kind='activity' AND gap_start IS NULL AND activity IS NOT NULL AND
         location IS NOT NULL AND energy IS NOT NULL AND mood IS NOT NULL AND
         presence IS NOT NULL AND focus IS NOT NULL) OR
        (kind='gap' AND gap_start IS NOT NULL AND activity IS NULL AND
         location IS NULL AND energy IS NULL AND mood IS NULL AND
         presence IS NULL AND focus IS NULL))
);
CREATE INDEX activity_log_recent
  ON activity_log(owner_id, ai_profile_id, at DESC, id DESC);
'''),
];
