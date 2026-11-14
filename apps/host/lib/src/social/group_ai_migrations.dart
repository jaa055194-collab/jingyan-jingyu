import '../storage/migrations.dart';

/// Explicit opt-in M04 migration. Version 303 follows 300, 301 and 302.
const groupAiMigration = Migration(303, 'group AI policy', '''
CREATE TABLE group_ai_settings (
  group_id TEXT PRIMARY KEY REFERENCES social_conversations(id) ON DELETE CASCADE,
  min_interval_ms INTEGER NOT NULL CHECK(min_interval_ms >= 0),
  max_per_round INTEGER NOT NULL CHECK(max_per_round >= 1),
  daily_cap INTEGER NOT NULL CHECK(daily_cap >= 0),
  autonomous_interjection INTEGER NOT NULL CHECK(autonomous_interjection IN (0,1)),
  interjection_gap_ms INTEGER NOT NULL CHECK(interjection_gap_ms >= 0),
  hosting INTEGER NOT NULL CHECK(hosting IN (0,1)),
  updated_at INTEGER NOT NULL
);
CREATE TABLE group_ai_intervals (
  group_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
  ai_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  min_interval_ms INTEGER NOT NULL CHECK(min_interval_ms >= 0),
  PRIMARY KEY(group_id, ai_id)
);
CREATE TABLE group_ai_mutes (
  group_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
  ai_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  muted INTEGER NOT NULL CHECK(muted IN (0,1)),
  PRIMARY KEY(group_id, ai_id)
);
CREATE TABLE group_ai_admissions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  group_id TEXT NOT NULL REFERENCES social_conversations(id) ON DELETE CASCADE,
  ai_id TEXT NOT NULL REFERENCES account(id) ON DELETE CASCADE,
  round_id TEXT NOT NULL,
  mentioned INTEGER NOT NULL CHECK(mentioned IN (0,1)),
  posted_at INTEGER NOT NULL,
  budget_day TEXT NOT NULL,
  offset_minutes INTEGER NOT NULL CHECK(offset_minutes BETWEEN -840 AND 840)
);
CREATE INDEX group_ai_admissions_lookup ON group_ai_admissions(group_id,ai_id,posted_at);
CREATE INDEX group_ai_admissions_round ON group_ai_admissions(group_id,ai_id,round_id);
CREATE INDEX group_ai_admissions_day ON group_ai_admissions(group_id,budget_day);
''');
