/// M08 voice 持久化迁移（编号 700–799）。
///
/// 全部 SQL 只建本模块自用的表，不引用其它模块的表，便于内存/契约测试
/// 独立打开。已发布的迁移号与 SQL 不可改写，只能追加。
library;

import '../storage/migrations.dart';

/// 音色档案与相关记录。
const voiceProfileMigrations = <Migration>[
  Migration(700, 'voice profiles', '''
CREATE TABLE voice_profiles (
  ai_id TEXT PRIMARY KEY,
  provider TEXT NOT NULL,
  model TEXT NOT NULL,
  voice_id TEXT NOT NULL,
  params_json TEXT NOT NULL,
  revision INTEGER NOT NULL,
  pending_params_json TEXT,
  pending_revision INTEGER,
  consent_ref TEXT NOT NULL,
  activated_at TEXT NOT NULL
);
'''),
  Migration(701, 'voice profile revisions', '''
CREATE TABLE voice_profile_revisions (
  ai_id TEXT NOT NULL,
  revision INTEGER NOT NULL,
  params_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  PRIMARY KEY(ai_id, revision)
);
'''),
  Migration(702, 'voice consents', '''
CREATE TABLE voice_consents (
  ai_id TEXT NOT NULL,
  consent_ref TEXT NOT NULL,
  granted_by TEXT NOT NULL,
  granted_at TEXT NOT NULL,
  scope TEXT NOT NULL,
  PRIMARY KEY(ai_id, consent_ref)
);
'''),
  Migration(703, 'voice samples', '''
CREATE TABLE voice_samples (
  sample_id TEXT PRIMARY KEY,
  ai_id TEXT NOT NULL,
  consent_ref TEXT NOT NULL,
  recorded_at TEXT NOT NULL
);
CREATE INDEX voice_samples_ai ON voice_samples(ai_id);
'''),
];

/// 1v1 通话会话。
const voiceCallMigrations = <Migration>[
  Migration(710, 'voice calls', '''
CREATE TABLE voice_calls (
  call_id TEXT PRIMARY KEY,
  ai_id TEXT NOT NULL,
  peer_account_id TEXT NOT NULL,
  state TEXT NOT NULL CHECK(state IN ('ringing','active','missed','ended')),
  started_at TEXT NOT NULL,
  answered_at TEXT,
  ended_at TEXT
);
CREATE INDEX voice_calls_state ON voice_calls(state);
'''),
];

/// 本模块全部迁移，供装配处按 700–799 段追加。
const voiceMigrations = <Migration>[
  ...voiceProfileMigrations,
  ...voiceCallMigrations,
];
