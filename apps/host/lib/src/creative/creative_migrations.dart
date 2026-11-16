/// M09 creative 预留迁移（800–899）。
///
/// 仅登记 schema，不改共享 `jingyu_host.dart` 装配；由交付报告建议在
/// `defaultModules` 的 migration 列表里追加 `...creativeMigrations` 后生效。
/// 版本号段不与已用编号冲突（1、100、200–、300–、500–、600–、1200–）。
/// 已发布的迁移号与 SQL 只追加、不改号。
library;

import '../storage/migrations.dart';

/// 创意模块表：周报/年报记录、深夜电台期次。
const List<Migration> creativeMigrations = [
  Migration(800, 'creative reports', '''
CREATE TABLE creative_reports (
  owner_account_id TEXT NOT NULL,
  ai_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('weekly','annual')),
  period_key TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('generated','missed','deferred')),
  updated_at TEXT NOT NULL,
  deferred_to TEXT,
  report_json TEXT,
  PRIMARY KEY(owner_account_id, ai_id, kind, period_key)
);
CREATE INDEX idx_creative_reports_owner ON creative_reports(owner_account_id);
'''),
  Migration(801, 'creative radio episodes', '''
CREATE TABLE creative_radio_episodes (
  owner_account_id TEXT NOT NULL,
  ai_id TEXT NOT NULL,
  date_key TEXT NOT NULL,
  scheduled_for TEXT NOT NULL,
  generated_at TEXT NOT NULL,
  script_json TEXT NOT NULL,
  voice_id TEXT NOT NULL,
  offline_cache_key TEXT NOT NULL,
  playable_offline INTEGER NOT NULL CHECK(playable_offline IN (0,1)),
  PRIMARY KEY(owner_account_id, ai_id, date_key)
);
CREATE INDEX idx_creative_radio_owner ON creative_radio_episodes(owner_account_id);
'''),
  Migration(802, 'creative activity feed', '''
CREATE TABLE creative_activity (
  owner_account_id TEXT NOT NULL,
  ai_id TEXT NOT NULL,
  scope TEXT NOT NULL CHECK(scope IN ('privateChat','groupChat','moments')),
  kind TEXT NOT NULL CHECK(kind IN ('topic','agreementCompleted','checkin','mood','milestone')),
  day_key TEXT NOT NULL,
  label TEXT NOT NULL DEFAULT '',
  value INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_creative_activity_owner ON creative_activity(owner_account_id, ai_id, day_key);
'''),
];
