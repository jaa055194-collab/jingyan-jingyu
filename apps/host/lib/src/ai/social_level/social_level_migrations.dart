import '../../storage/migrations.dart';

/// No backfill/default: each current operator must choose explicitly.
const socialLevelMigration = Migration(
  603,
  'explicit per-owner AI social level',
  '''
CREATE TABLE ai_social_levels (
  owner_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  ai_profile_id TEXT NOT NULL REFERENCES ai_profile(id) ON DELETE CASCADE,
  level TEXT NOT NULL CHECK(level IN ('L0','L1','L2','L3','L4')),
  updated_at TEXT NOT NULL,
  PRIMARY KEY(owner_id,ai_profile_id)
);
''',
);
