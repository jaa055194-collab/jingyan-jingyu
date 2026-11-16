/// M12 lifecycle 预留迁移（1200–1299）。
///
/// 仅登记 schema，不改共享 `jingyu_host.dart` 装配；由交付报告建议在
/// `defaultModules` 的 migration 列表里追加 `...lifecycleMigrations` 后生效。
/// 版本号段不与已用编号（1、100、200–214、300–305、500–504、600–602、700+）冲突。
library;

import '../storage/migrations.dart';

/// 生命周期相关表：配额账本、清理日志、导出作业、删除回执。
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
];
