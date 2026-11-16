/// [SqliteCleanupStore] 通过统一 [cleanupStoreContract] 契约测试，并验证跨重启持久化。
library;

import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:jingyu_host/src/lifecycle/lifecycle_migrations.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_cleanup_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'cleanup_store_contract.dart';

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase database;

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    path,
    migrations: [...allMigrations, ...lifecycleMigrations],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-lifecycle-cleanup-');
    path = '${dir.path}/host.sqlite';
    database = await openDatabase();
  });
  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  cleanupStoreContract(
    'SqliteCleanupStore',
    () => SqliteCleanupStore(
      database: database,
      clock: FakeClock(DateTime.utc(2026, 1, 1)),
    ),
  );

  test('媒体状态、提醒与占位跨重启保留', () async {
    final store = SqliteCleanupStore(
      database: database,
      clock: FakeClock(DateTime.utc(2026, 1, 1)),
    );
    await store.addAsset(
      MediaAsset(
        id: 'x',
        kind: MediaKind.video,
        createdAt: DateTime.utc(2026, 1, 1),
        holderMessageIds: const {'a': 'm1'},
      ),
    );
    await store.markReminded('x', DateTime.utc(2026, 3, 1));
    await store.deleteBlob('x');
    await store.putPlaceholder(
      const MediaPlaceholder(
        assetId: 'x',
        ownerAccountId: 'a',
        messageId: 'm1',
        reason: '媒体已过期清理（可重新上传）',
      ),
    );

    await database.close();
    database = await openDatabase();
    final restarted = SqliteCleanupStore(database: database);
    final asset = await restarted.asset('x');
    expect(asset!.blobPresent, isFalse);
    expect(await restarted.remindedAt('x'), DateTime.utc(2026, 3, 1));
    expect((await restarted.placeholdersFor('a')).single.assetId, 'x');
  });
}
