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

  test(
    '904 avatar rows upgrade without retaining legacy param_map bytes',
    () async {
      final path = '${directory.path}/upgrade.sqlite';
      final legacy = await SqliteDatabase.open(
        path,
        migrations: [
          ...allMigrations,
          ...worldMigrations.where((m) => m.version <= 904),
        ],
      );
      await legacy.execute(
        'INSERT INTO world_avatars(avatar_id, owner_id, kind, model_id, profile_rev, param_map, updated_at) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          'av_legacy',
          'owner',
          'live2d',
          'https://example.invalid/models/avatar.moc3',
          7,
          '{"mouthOpen":"SecretLegacyParam"}',
          DateTime.utc(2026, 11, 16).toIso8601String(),
        ],
      );
      for (final row in [
        ['av_windows_path', r'C:\\users\\owner\\avatar.model3.json'],
        ['av_traversal', '../avatar.model3.json'],
      ]) {
        await legacy.execute(
          'INSERT INTO world_avatars(avatar_id, owner_id, kind, model_id, profile_rev, param_map, updated_at) '
          'VALUES(?,?,?,?,?,?,?)',
          [
            row[0], 'owner', 'live2d', row[1], 2, '{}',
            DateTime.utc(2026, 11, 16).toIso8601String(),
          ],
        );
      }
      await legacy.execute(
        'INSERT INTO world_avatars(avatar_id, owner_id, kind, model_id, profile_rev, param_map, updated_at) '
        'VALUES(?,?,?,?,?,?,?)',
        [
          'legacy',
          'owner',
          'live2d',
          'legacy_61765f6c6567616379',
          3,
          '{}',
          DateTime.utc(2026, 11, 16).toIso8601String(),
        ],
      );
      await legacy.execute(
        'INSERT INTO world_avatar_active(owner_id, avatar_id, profile_rev) VALUES(?,?,?)',
        ['owner', 'av_legacy', 7],
      );
      await legacy.close();

      final upgraded = await SqliteDatabase.open(
        path,
        migrations: [...allMigrations, ...worldMigrations],
      );
      final columns = await upgraded.query('PRAGMA table_info(world_avatars)');
      expect(columns.map((row) => row['name']), isNot(contains('param_map')));
      await upgraded.close();

      final reopened = await SqliteDatabase.open(
        path,
        migrations: [...allMigrations, ...worldMigrations],
      );
      try {
        final registry = SqliteAvatarRegistry(database: reopened, clock: clock);
        final profile = (await registry.get(
          ownerId: 'owner',
          avatarId: 'av_legacy',
        )).value;
        expect(profile.modelId, matches(RegExp(r'^legacy_[0-9a-f]+$')));
        expect(profile.modelId, isNot(contains('https')));
        expect(profile.profileRev, 7);
        expect(profile.toJson().keys, isNot(contains('paramMap')));
        final active = (await registry.active('owner')).value;
        expect(active.modelId, profile.modelId);
        expect(active.profileRev, 7);
        final aliases = await registry.list('owner');
        expect(aliases, hasLength(4));
        expect(aliases.map((item) => item.modelId).toSet().length, 4);
        for (final item in aliases.where((item) => item.avatarId != 'av_legacy')) {
          expect(item.modelId, matches(RegExp(r'^(legacy|legacyref)_[0-9a-f]+$')));
          expect(item.modelId, isNot(contains('C:')));
          expect(item.modelId, isNot(contains('..')));
          expect(item.modelId, isNot(contains('https')));
        }
        expect(
          aliases.singleWhere((item) => item.avatarId == 'legacy').modelId,
          'legacy_6c6567616379',
        );
      } finally {
        await reopened.close();
      }
    },
  );
}
