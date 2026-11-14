import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/src/storage/key_provider.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/storage_module.dart';
import 'package:test/test.dart';

void main() {
  test(
    'StorageModule accepts module migrations without changing M01 defaults',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'jingyu-module-migration-',
      );
      final storage = StorageModule(
        databasePath: '${dir.path}/host.sqlite',
        keyProvider: EnvKeyProvider(base64Encode(List<int>.filled(32, 4))),
        migrations: [
          ...allMigrations,
          const Migration(
            200,
            'probe',
            'CREATE TABLE module_probe (id TEXT PRIMARY KEY);',
          ),
        ],
      );
      addTearDown(() async {
        await storage.stop();
        await dir.delete(recursive: true);
      });
      await storage.start();
      expect(await storage.database.schemaVersion(), 200);
      await storage.database.execute('INSERT INTO module_probe VALUES (?)', [
        'saved',
      ]);
      expect(
        (await storage.database.query(
          'SELECT id FROM module_probe',
        )).single['id'],
        'saved',
      );
    },
  );
}
