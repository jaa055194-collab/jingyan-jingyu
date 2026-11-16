/// M10 world SQLite 实现：复用同一组契约测试（内存与 SQLite 必须一致通过）。
///
/// 每个测试用独立临时数据库，应用全部迁移 + world 迁移（900–999）。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/world/sqlite_avatar_registry.dart';
import 'package:jingyu_host/src/world/sqlite_presence_service.dart';
import 'package:jingyu_host/src/world/sqlite_space_layout_store.dart';
import 'package:jingyu_host/src/world/world_migrations.dart';
import 'package:test/test.dart';

import 'world_avatar_registry_contract.dart';
import 'world_layout_store_contract.dart';
import 'world_presence_service_contract.dart';

void main() {
  late Directory directory;
  late SqliteDatabase database;
  late FakeClock clock;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('world-sqlite-');
    database = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...worldMigrations],
    );
    clock = FakeClock(DateTime.utc(2026, 11, 16, 12));
  });

  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  spaceLayoutStoreContract('SQLite', () {
    return (
      store: SqliteSpaceLayoutStore(database: database, clock: clock),
      clock: clock,
    );
  });

  presenceServiceContract('SQLite', () {
    final policy = FakeVisitAccessPolicy();
    return PresenceFixture(
      SqlitePresenceService(database: database, clock: clock, policy: policy),
      policy,
      clock,
    );
  });

  avatarRegistryContract('SQLite', () {
    return (
      registry: SqliteAvatarRegistry(database: database, clock: clock),
      clock: clock,
    );
  });
}
