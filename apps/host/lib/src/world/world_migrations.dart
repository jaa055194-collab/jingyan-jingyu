import '../storage/migrations.dart';

/// M10 world 迁移（预留号段 900–999）。
///
/// 本切片仅交付内存实现；这些 schema 供后续接入 SQLite 持久化时并入
/// `apps/host/lib/jingyu_host.dart` 的迁移列表（属装配建议，见交付报告）。
/// 已发布迁移号与 SQL 为 append-only，不得改动语义。
const List<Migration> worldMigrations = [
  Migration(900, 'world space layout', '''
CREATE TABLE world_space_layouts (
  space_id TEXT PRIMARY KEY NOT NULL,
  version INTEGER NOT NULL CHECK(version > 0),
  style TEXT NOT NULL,
  main_color TEXT,
  updated_at TEXT NOT NULL
);
CREATE TABLE world_space_rooms (
  space_id TEXT NOT NULL,
  room_id TEXT NOT NULL,
  name TEXT NOT NULL,
  sort_order INTEGER NOT NULL,
  PRIMARY KEY(space_id, room_id)
);
CREATE TABLE world_room_furniture (
  space_id TEXT NOT NULL,
  room_id TEXT NOT NULL,
  item_id TEXT NOT NULL,
  asset_id TEXT NOT NULL,
  x REAL NOT NULL,
  y REAL NOT NULL,
  z REAL NOT NULL,
  rotation REAL NOT NULL,
  PRIMARY KEY(space_id, room_id, item_id)
);
'''),
  Migration(901, 'world presence positions', '''
CREATE TABLE world_presence (
  resident_id TEXT PRIMARY KEY NOT NULL,
  space_id TEXT NOT NULL,
  home_space_id TEXT NOT NULL,
  x REAL NOT NULL,
  y REAL NOT NULL,
  z REAL NOT NULL,
  motion TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_world_presence_space ON world_presence(space_id);
'''),
  Migration(902, 'world visit sessions and events', '''
CREATE TABLE world_visits (
  visit_id TEXT PRIMARY KEY NOT NULL,
  visitor_id TEXT NOT NULL,
  host_owner_id TEXT NOT NULL,
  location TEXT NOT NULL CHECK(location IN ('yard','indoor')),
  status TEXT NOT NULL CHECK(status IN ('active','ended','timed_out','denied')),
  started_at TEXT NOT NULL,
  ended_at TEXT
);
CREATE INDEX idx_world_visits_host ON world_visits(host_owner_id, status);
CREATE TABLE world_presence_events (
  id INTEGER PRIMARY KEY,
  action TEXT NOT NULL,
  visitor_id TEXT,
  host_owner_id TEXT,
  visit_id TEXT,
  at TEXT NOT NULL,
  details TEXT NOT NULL
);
CREATE INDEX idx_world_presence_events_host
  ON world_presence_events(host_owner_id, id);
'''),
  Migration(903, 'world avatar registry', '''
CREATE TABLE world_avatars (
  avatar_id TEXT PRIMARY KEY NOT NULL,
  owner_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('vrm','live2d')),
  model_id TEXT NOT NULL,
  profile_rev INTEGER NOT NULL CHECK(profile_rev > 0),
  param_map TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX idx_world_avatars_owner ON world_avatars(owner_id);
CREATE TABLE world_avatar_active (
  owner_id TEXT PRIMARY KEY NOT NULL,
  avatar_id TEXT NOT NULL,
  profile_rev INTEGER NOT NULL
);
'''),
  Migration(904, 'world visit invitations', '''
CREATE TABLE world_invitations (
  token TEXT PRIMARY KEY NOT NULL,
  visitor_id TEXT NOT NULL,
  host_owner_id TEXT NOT NULL,
  created_at TEXT NOT NULL
);
CREATE INDEX idx_world_invitations_pair
  ON world_invitations(host_owner_id, visitor_id);
'''),
];
