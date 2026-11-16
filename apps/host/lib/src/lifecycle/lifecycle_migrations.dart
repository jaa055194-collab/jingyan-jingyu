/// M12 lifecycle 预留迁移（1200–1299）。
///
/// 仅登记 schema，不改共享 `jingyu_host.dart` 装配；由交付报告建议在
/// `defaultModules` 的 migration 列表里追加 `...lifecycleMigrations` 后生效。
/// 版本号段不与已用编号（1、100、200–214、300–305、500–504、600–602、700+）冲突。
library;

import '../storage/migrations.dart';

/// 生命周期相关表：配额账本+磁盘状态、清理媒体/提醒/占位/运行、导出作业、删除回执。
const List<Migration> lifecycleMigrations = [
  Migration(1200, 'quota ledger', '''
CREATE TABLE quota (
  account_id TEXT PRIMARY KEY NOT NULL,
  used_bytes INTEGER NOT NULL CHECK(used_bytes >= 0),
  updated_at TEXT NOT NULL
);
'''),
  Migration(1201, 'cleanup log', '''
CREATE TABLE cleanup_log (
  id INTEGER PRIMARY KEY,
  at TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  kind TEXT NOT NULL,
  action TEXT NOT NULL CHECK(action IN ('remind','expire')),
  holders INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_cleanup_log_asset ON cleanup_log(asset_id);
'''),
  Migration(1202, 'export jobs', '''
CREATE TABLE export_jobs (
  id TEXT PRIMARY KEY NOT NULL,
  owner_account_id TEXT NOT NULL,
  status TEXT NOT NULL CHECK(status IN ('pending','running','completed','failed')),
  created_at TEXT NOT NULL,
  completed_at TEXT
);
CREATE INDEX idx_export_jobs_owner ON export_jobs(owner_account_id);
'''),
  Migration(1203, 'deletion receipts', '''
CREATE TABLE deletion_receipts (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL,
  generated_at TEXT NOT NULL,
  object_counts TEXT NOT NULL,
  backup_rotation_due_at TEXT NOT NULL,
  ai_disposition TEXT NOT NULL
);
CREATE INDEX idx_deletion_receipts_account ON deletion_receipts(account_id);
'''),
  Migration(1204, 'quota disk state', '''
CREATE TABLE quota_disk_state (
  id TEXT PRIMARY KEY NOT NULL,
  free_bytes INTEGER NOT NULL CHECK(free_bytes >= 0),
  total_bytes INTEGER NOT NULL CHECK(total_bytes > 0),
  CHECK(free_bytes <= total_bytes)
);
'''),
  Migration(1205, 'cleanup media assets and placeholders', '''
CREATE TABLE media_assets (
  id TEXT PRIMARY KEY NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('video','voice')),
  created_at TEXT NOT NULL,
  blob_present INTEGER NOT NULL DEFAULT 1 CHECK(blob_present IN (0,1))
);
CREATE TABLE media_asset_holders (
  asset_id TEXT NOT NULL,
  account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  PRIMARY KEY(asset_id, account_id)
);
CREATE TABLE media_reminders (
  asset_id TEXT PRIMARY KEY NOT NULL,
  reminded_at TEXT NOT NULL
);
CREATE TABLE media_placeholders (
  asset_id TEXT NOT NULL,
  owner_account_id TEXT NOT NULL,
  message_id TEXT NOT NULL,
  reason TEXT NOT NULL,
  PRIMARY KEY(asset_id, owner_account_id, message_id)
);
CREATE TABLE cleanup_runs (
  day_key TEXT PRIMARY KEY NOT NULL,
  ran_at TEXT NOT NULL
);
'''),
  Migration(1206, 'departure ledger', '''
CREATE TABLE departure_ledger (
  account_id TEXT PRIMARY KEY NOT NULL,
  object_counts TEXT NOT NULL,
  moments_to_anonymize INTEGER NOT NULL DEFAULT 0 CHECK(moments_to_anonymize >= 0)
);
'''),
];
