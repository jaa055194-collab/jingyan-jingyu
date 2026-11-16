/// [SqliteDepartureStore] 通过统一 [departureStoreContract] 契约测试，并验证跨重启持久化。
library;

import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/src/lifecycle/lifecycle_migrations.dart';
import 'package:jingyu_host/src/lifecycle/sqlite_departure_store.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

import 'departure_store_contract.dart';

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase database;

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    path,
    migrations: [...allMigrations, ...lifecycleMigrations],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-lifecycle-departure-');
    path = '${dir.path}/host.sqlite';
    database = await openDatabase();
  });
  tearDown(() async {
    await database.close();
    await dir.delete(recursive: true);
  });

  departureStoreContract(
    'SqliteDepartureStore',
    () => SqliteDepartureStore(database: database),
    (store) async {
      await database.execute(
        'INSERT INTO departure_ledger(account_id, object_counts, moments_to_anonymize) VALUES (?, ?, ?)',
        [
          'u1',
          jsonEncode({
            'conversations': 2,
            'messages': 10,
            'memories': 5,
            'attachments': 4,
          }),
          3,
        ],
      );
    },
  );

  test('对象计数跨重启保留', () async {
    await database.execute(
      'INSERT INTO departure_ledger(account_id, object_counts, moments_to_anonymize) VALUES (?, ?, ?)',
      [
        'u1',
        jsonEncode({'conversations': 2, 'messages': 10}),
        3,
      ],
    );
    await database.close();
    database = await openDatabase();
    final store = SqliteDepartureStore(database: database);
    final survey = await store.survey('u1');
    expect(survey.objectCounts['conversations'], 2);
    expect(survey.objectCounts['messages'], 10);
    expect(survey.momentsToAnonymize, 3);
  });
}
