import 'dart:io';

import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

void main() {
  test('M01-4 transaction body failure rolls back every write', () async {
    final directory = await Directory.systemTemp.createTemp('jingyu-rollback-');
    final db = await SqliteDatabase.open('${directory.path}/rollback.sqlite');
    addTearDown(() async {
      await db.close();
      await directory.delete(recursive: true);
    });
    await db.execute('CREATE TABLE rollback_probe (value TEXT NOT NULL)');

    await expectLater(
      db.transaction((tx) async {
        await tx.execute('INSERT INTO rollback_probe(value) VALUES (?)', ['kept?']);
        throw StateError('rollback requested');
      }),
      throwsStateError,
    );
    expect(await db.query('SELECT value FROM rollback_probe'), isEmpty);
  });
}
