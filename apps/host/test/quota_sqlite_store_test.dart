/// [SqliteQuotaStore] 通过统一 [quotaStoreContract] 契约测试，并验证跨重启持久化。
library;

import 'dart:io';

import 'package:jingyu_host/src/lifecycle/lifecycle_migrations.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_quota_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'quota_store_contract.dart';

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase database;

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    path,
    migrations: [...allMigrations, ...lifecycleMigrations],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-lifecycle-quota-');
    path = '${dir.path}/host.sqlite';
    database = await openDatabase();
  });
  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  quotaStoreContract(
    'SqliteQuotaStore',
    () => SqliteQuotaStore(database: database),
  );

  test('用量与磁盘状态跨重启保留', () async {
    final store = SqliteQuotaStore(database: database);
    await store.addUsage('a', 42);
    await store.setDiskSpace(freeBytes: 7, totalBytes: 10);

    await database.close();
    database = await openDatabase();
    final restarted = SqliteQuotaStore(database: database);
    expect(await restarted.usedBytes('a'), 42);
    final disk = await restarted.diskSpace();
    expect(disk.freeBytes, 7);
    expect(disk.totalBytes, 10);
  });

  test('并发 addUsage 通过事务累加不丢失', () async {
    final store = SqliteQuotaStore(database: database);
    await Future.wait(List.generate(20, (_) => store.addUsage('a', 5)));
    expect(await store.usedBytes('a'), 100);
  });
}
