import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/config.dart';
import 'package:jingyu_host/src/system/system_module.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/key_provider.dart';
import 'package:jingyu_host/src/storage/storage_module.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

import 'storage_audit_contract.dart';

void main() {
  late Directory dir;
  late String path;
  final opened = <SqliteDatabase>[];
  Future<SqliteDatabase> open({List<Migration>? migrations}) async {
    final db = await SqliteDatabase.open(
      path,
      migrations: migrations ?? allMigrations,
    );
    opened.add(db);
    return db;
  }

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-storage-');
    path = '${dir.path}/nested/host.sqlite';
  });
  tearDown(() async {
    for (final db in opened.reversed) {
      await db.close();
    }
    opened.clear();
    await dir.delete(recursive: true);
  });
  test(
    'M01-1 empty directory creates latest schema and only storage tables',
    () async {
      final db = await open();
      expect(await File(path).exists(), isTrue);
      expect(await db.schemaVersion(), 1);
      expect(
        (await db.query(
          "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ? ORDER BY name",
          ['table', 'sqlite_%'],
        )).map((r) => r['name']),
        ['audit_log', 'key_store', 'schema_migrations'],
      );
      expect(
        (await db.query('PRAGMA journal_mode')).single.values.single,
        'wal',
      );
      expect((await db.query('PRAGMA foreign_keys')).single.values.single, 1);
    },
  );
  test('M01-2 restart does not repeat migrations and preserves data', () async {
    final db = await open();
    await db.execute('INSERT INTO key_store (id, wrapped_dek) VALUES (?, ?)', [
      'probe',
      'sealed',
    ]);
    await db.close();
    final next = await open();
    expect(await next.schemaVersion(), 1);
    expect(
      (await next.query('SELECT wrapped_dek FROM key_store WHERE id = ?', [
        'probe',
      ])).single['wrapped_dek'],
      'sealed',
    );
    expect(
      (await next.query(
        'SELECT COUNT(*) AS n FROM schema_migrations',
      )).single['n'],
      1,
    );
  });
  test(
    'M01-3 failed migration rolls back DDL and data without advancing version',
    () async {
      await (await open()).close();
      await expectLater(
        open(
          migrations: [
            ...allMigrations,
            const Migration(
              3,
              'broken',
              'CREATE TABLE partial (id INTEGER); INSERT INTO missing VALUES (1);',
            ),
          ],
        ),
        throwsA(anything),
      );
      final db = await open();
      expect(await db.schemaVersion(), 1);
      expect(
        await db.query('SELECT name FROM sqlite_master WHERE name = ?', [
          'partial',
        ]),
        isEmpty,
      );
      await db.close();
      final next = await open(
        migrations: [
          ...allMigrations,
          const Migration(3, 'fixed', 'CREATE TABLE partial (id INTEGER);'),
        ],
      );
      expect(await next.schemaVersion(), 3);
    },
  );
  test(
    'M01-4 transaction rolls back all writes and returns callback value',
    () async {
      final db = await open();
      await db.execute(
        'CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)',
      );
      await expectLater(
        db.transaction<void>((tx) async {
          await tx.execute('INSERT INTO sample VALUES (?, ?)', [1, 'first']);
          await tx.execute('INSERT INTO sample VALUES (?, ?)', [2, 'second']);
          throw StateError('abort');
        }),
        throwsStateError,
      );
      expect(await db.query('SELECT * FROM sample'), isEmpty);
      expect(
        await db.transaction((tx) async {
          await tx.execute('INSERT INTO sample VALUES (?, ?)', [
            3,
            "x'); DROP TABLE sample;--",
          ]);
          return 42;
        }),
        42,
      );
      expect(
        (await db.query('SELECT * FROM sample')).single['value'],
        "x'); DROP TABLE sample;--",
      );
    },
  );
  test(
    'M01-4 a transaction cannot leak its Tx handle after completion',
    () async {
      final db = await open();
      await db.execute('CREATE TABLE sample (id INTEGER)');
      late Tx leaked;
      await db.transaction((tx) async {
        leaked = tx;
      });
      await expectLater(
        leaked.execute('INSERT INTO sample VALUES (?)', [1]),
        throwsStateError,
      );
      expect(await db.query('SELECT * FROM sample'), isEmpty);
    },
  );
  test(
    'M01-3 failed migration rolls back the schema_migrations bootstrap',
    () async {
      const broken = Migration(1, 'broken foundation', '''
CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE partial (id INTEGER);
INSERT INTO missing VALUES (1);
''');
      await expectLater(
        SqliteDatabase.open(path, migrations: [broken]),
        throwsA(anything),
      );
      final db = await open();
      expect(await db.schemaVersion(), 1);
      expect(
        await db.query('SELECT name FROM sqlite_master WHERE name = ?', [
          'partial',
        ]),
        isEmpty,
      );
    },
  );
  test(
    'M01-4 concurrent calls do not interleave on the shared connection',
    () async {
      final db = await open();
      await db.execute(
        'CREATE TABLE sample (id INTEGER PRIMARY KEY, value TEXT)',
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      final tx = db.transaction((tx) async {
        await tx.execute('INSERT INTO sample VALUES (?, ?)', [1, 'tx']);
        entered.complete();
        await release.future;
        return tx.query('SELECT id FROM sample');
      });
      final selected = expectLater(tx, completion(hasLength(1)));
      await entered.future;
      final outside = db.query('SELECT id FROM sample');
      release.complete();
      await selected;
      expect(await outside, hasLength(1));
    },
  );

  test(
    'M01-4 unrelated operations wait outside active async transaction',
    () async {
      final db = await open();
      await db.execute('CREATE TABLE sample (id INTEGER)');
      final entered = Completer<void>();
      final release = Completer<void>();
      final tx = db.transaction<void>((tx) async {
        await tx.execute('INSERT INTO sample VALUES (?)', [1]);
        entered.complete();
        await release.future;
        throw StateError('rollback');
      });
      final failed = expectLater(tx, throwsStateError);
      await entered.future;
      final outside = db.execute('INSERT INTO sample VALUES (?)', [2]);
      release.complete();
      await failed;
      await outside;
      expect((await db.query('SELECT id FROM sample')).map((r) => r['id']), [
        2,
      ]);
    },
  );
  test(
    'M01-7 normal database passes integrity check and enforces foreign keys',
    () async {
      final db = await open();
      await db.execute('CREATE TABLE parent (id INTEGER PRIMARY KEY)');
      await db.execute(
        'CREATE TABLE child (parent_id INTEGER REFERENCES parent(id))',
      );
      await expectLater(
        db.execute('INSERT INTO child VALUES (?)', [4]),
        throwsA(anything),
      );
      expect(await db.integrityCheck(), 'ok');
    },
  );
  test(
    'M01-5 encrypted columns roundtrip, randomize, and bind authentication to aad',
    () {
      final cipher = AesGcmColumnCipher(List<int>.filled(32, 9));
      final first = cipher.encrypt('secret paragraph', aad: 'messages:body:m1');
      final second = cipher.encrypt(
        'secret paragraph',
        aad: 'messages:body:m1',
      );
      expect(first, startsWith('v1:'));
      expect(first, isNot(second));
      expect(
        cipher.decrypt(first, aad: 'messages:body:m1').value,
        'secret paragraph',
      );
      expect(cipher.decrypt(first, aad: 'messages:body:m2').isErr, isTrue);
      final bytes = base64.decode(first.substring(3));
      bytes[12] ^= 1;
      expect(
        cipher
            .decrypt('v1:${base64.encode(bytes)}', aad: 'messages:body:m1')
            .isErr,
        isTrue,
      );
    },
  );
  test(
    'M01-6 database and sidecars do not contain encrypted plaintext',
    () async {
      final db = await open();
      final cipher = AesGcmColumnCipher(List<int>.filled(32, 7));
      await db.execute(
        'CREATE TABLE private_data (id TEXT PRIMARY KEY, body TEXT NOT NULL)',
      );
      final secret = 'M01 plaintext unique phrase 53d92ca1';
      await db.execute('INSERT INTO private_data VALUES (?, ?)', [
        'm1',
        cipher.encrypt(secret, aad: 'private_data:body:m1'),
      ]);
      expect(
        cipher
            .decrypt(
              (await db.query('SELECT body FROM private_data')).single['body']
                  as String,
              aad: 'private_data:body:m1',
            )
            .value,
        secret,
      );
      await db.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      await db.close();
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        expect(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true),
          isNot(contains(secret)),
          reason: file.path,
        );
      }
    },
  );
  test(
    'M01-6 encrypted DEK survives restart and corrupt envelope fails closed',
    () async {
      final keyFile = File('${dir.path}/kek.dpapi');
      final storage = StorageModule(
        databasePath: path,
        keyProvider: DpapiKeyProvider(path: keyFile.path),
      );
      await storage.start();
      final cipher = storage.cipher;
      final sealed = cipher.encrypt('persistent', aad: 'messages:body:m1');
      expect(
        (await storage.database.query(
          'SELECT wrapped_dek FROM key_store WHERE id = ?',
          ['primary'],
        )).single['wrapped_dek'],
        isNotEmpty,
      );
      await storage.stop();
      final again = StorageModule(
        databasePath: path,
        keyProvider: DpapiKeyProvider(path: keyFile.path),
      );
      await again.start();
      expect(
        again.cipher.decrypt(sealed, aad: 'messages:body:m1').value,
        'persistent',
      );
      await again.database.execute(
        'UPDATE key_store SET wrapped_dek = ? WHERE id = ?',
        ['corrupt', 'primary'],
      );
      await again.stop();
      final bad = StorageModule(
        databasePath: path,
        keyProvider: DpapiKeyProvider(path: keyFile.path),
      );
      await expectLater(bad.start(), throwsA(anything));
      await bad.stop();
    },
  );
  test(
    'StorageModule registers interfaces and SQLite audit implementation',
    () async {
      final storage = StorageModule(
        databasePath: path,
        keyProvider: EnvKeyProvider(base64.encode(List<int>.filled(32, 4))),
      );
      final system = SystemModule(
        config: const HostConfig(),
        audit: storage.auditLog,
      );
      final registry = Registry()
        ..register(system)
        ..register(storage);
      await registry.boot();
      expect(registry.services.get<Database>(), same(storage.database));
      expect(registry.services.get<ColumnCipher>(), same(storage.cipher));
      expect(registry.services.get<AuditLog>(), isA<SqliteAuditLog>());
      await registry.shutdown();
    },
  );
  storageAuditContract('memory', () => InMemoryAuditLog());
  storageAuditContract('SQLite', () async => SqliteAuditLog(await open()));
  test('M01-8 audit survives database restart', () async {
    final db = await open();
    await SqliteAuditLog(db).record(
      AuditEntry(
        at: DateTime.utc(2026),
        actorId: 'u1',
        action: 'edit',
        targetKind: 'message',
        targetId: 'm1',
      ),
    );
    await db.close();
    expect(
      (await SqliteAuditLog(
        await open(),
      ).forTarget('message', 'm1')).single.actorId,
      'u1',
    );
  });
}
