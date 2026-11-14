import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'message_store_contract.dart';

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase database;
  late AesGcmColumnCipher cipher;

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    path,
    migrations: [...allMigrations, ...messagesMigrations],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-messages-');
    path = '${dir.path}/host.sqlite';
    database = await openDatabase();
    cipher = AesGcmColumnCipher(List<int>.filled(32, 11));
  });
  tearDown(() async {
    await database.close();
    cipher.dispose();
    await dir.delete(recursive: true);
  });

  messageStoreContract('SQLite', () {
    var id = 0;
    return SqliteMessageStore(
      database: database,
      cipher: cipher,
      clock: FakeClock(DateTime.utc(2026, 1, 2)),
      newId: () => 'message-${++id}',
    );
  });

  test(
    'transactional head reads the caller transaction without a second connection operation',
    () async {
      final store = SqliteMessageStore(database: database, cipher: cipher);
      await database.transaction((tx) async {
        await tx.execute(
          'INSERT INTO message_heads(conversation_id, seq) VALUES (?, ?)',
          ['c', 9],
        );
        expect(await store.headSeqInTransaction(tx, 'c'), 9);
        expect(await store.headSeqInTransaction(tx, 'missing'), 0);
      });
    },
  );

  test(
    'parallel retries of the same client id allocate one sequence',
    () async {
      var id = 0;
      final store = SqliteMessageStore(
        database: database,
        cipher: cipher,
        newId: () => 'parallel-${++id}',
      );
      final results = await Future.wait(
        List.generate(
          12,
          (_) => store.append(
            conversationId: 'c',
            senderId: 'u',
            clientMsgId: 'retry',
            kind: MessageKind.text,
            body: const {'text': 'once'},
          ),
        ),
      );

      expect(results.where((r) => r.isOk).length, 12);
      expect(results.where((r) => r.value.duplicate).length, 11);
      expect(results.map((r) => r.value.message.seq).toSet(), {1});
      expect(await store.headSeq('c'), 1);
    },
  );

  test(
    'parallel distinct messages remain ordered and use injected clock',
    () async {
      final clock = FakeClock(DateTime.utc(2026, 3, 4, 5, 6, 7));
      final store = SqliteMessageStore(
        database: database,
        cipher: cipher,
        clock: clock,
      );
      final results = await Future.wait(
        List.generate(
          20,
          (i) => store.append(
            conversationId: "c'); DROP TABLE messages;--",
            senderId: 'u',
            clientMsgId: 'unique-$i',
            kind: MessageKind.text,
            body: {
              'nested': {'count': i},
            },
          ),
        ),
      );
      expect(results.every((r) => r.isOk), isTrue);
      final page = (await store.since(
        conversationId: "c'); DROP TABLE messages;--",
        afterSeq: 0,
      )).value;
      expect(page.messages.map((m) => m.seq), List.generate(20, (i) => i + 1));
      expect(
        page.messages.every(
          (m) => m.sentAt == DateTime.utc(2026, 3, 4, 5, 6, 7),
        ),
        isTrue,
      );
    },
  );

  test('ciphertext moved to a different row fails authentication', () async {
    final store = SqliteMessageStore(database: database, cipher: cipher);
    for (final id in ['one', 'two']) {
      await store.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: id,
        kind: MessageKind.text,
        body: {'text': id},
      );
    }
    await database.execute(
      'UPDATE messages SET body = (SELECT body FROM messages WHERE seq = ?) WHERE seq = ?',
      [1, 2],
    );
    expect((await store.since(conversationId: 'c', afterSeq: 1)).isErr, isTrue);
  });

  test(
    'invalid JSON input returns invalidArgument without allocating sequence',
    () async {
      final store = SqliteMessageStore(database: database, cipher: cipher);
      final invalid = await store.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'bad',
        kind: MessageKind.text,
        body: {'unsupported': Object()},
      );
      expect(invalid.failureOrNull!.code, FailureCode.invalidArgument);
      expect(await store.headSeq('c'), 0);
    },
  );

  test('plaintext is absent from database and sidecars', () async {
    const secret = 'private message plaintext 9bf14c';
    final store = SqliteMessageStore(database: database, cipher: cipher);
    final written = await store.append(
      conversationId: 'c',
      senderId: 'u',
      clientMsgId: 'secret',
      kind: MessageKind.text,
      body: const {'text': secret},
    );
    expect(written.isOk, isTrue);
    expect(
      (await store.since(
        conversationId: 'c',
        afterSeq: 0,
      )).value.messages.single.body['text'],
      secret,
    );
    await database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      expect(
        utf8.decode(file.readAsBytesSync(), allowMalformed: true),
        isNot(contains(secret)),
      );
    }
  });

  test('messages, sequence and acknowledgements survive restart', () async {
    final store = SqliteMessageStore(database: database, cipher: cipher);
    final appended = await store.append(
      conversationId: 'c',
      senderId: 'u',
      clientMsgId: 'persist',
      kind: MessageKind.text,
      body: const {'text': 'persistent'},
    );
    expect(appended.isOk, isTrue);
    expect(await store.ack(conversationId: 'c', deviceId: 'd', seq: 1), 1);
    await database.close();
    database = await openDatabase();

    final restarted = SqliteMessageStore(database: database, cipher: cipher);
    expect(await restarted.headSeq('c'), 1);
    expect(
      (await restarted.since(
        conversationId: 'c',
        afterSeq: 0,
      )).value.messages.single.body['text'],
      'persistent',
    );
    expect(await restarted.ack(conversationId: 'c', deviceId: 'd', seq: 0), 1);
  });

  test(
    'failed transaction is propagated and leaves no partial sequence',
    () async {
      final failing = _FailAfterBodyDatabase(database);
      final store = SqliteMessageStore(database: failing, cipher: cipher);
      await expectLater(
        store.append(
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'rollback',
          kind: MessageKind.text,
          body: const {'text': 'x'},
        ),
        throwsStateError,
      );
      final healthy = SqliteMessageStore(database: database, cipher: cipher);
      expect(await healthy.headSeq('c'), 0);
      expect(
        (await healthy.since(conversationId: 'c', afterSeq: 0)).value.messages,
        isEmpty,
      );
    },
  );

  test('malformed decrypted body returns internal failure result', () async {
    await database.execute(
      '''
      INSERT INTO messages(conversation_id, seq, message_id, sender_id, client_msg_id, kind, body, sent_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ''',
      [
        'c',
        1,
        'bad',
        'u',
        'bad-client',
        'text',
        cipher.encrypt('[]', aad: 'messages:body:bad'),
        '2026-01-02T00:00:00.000Z',
      ],
    );
    final result = await SqliteMessageStore(
      database: database,
      cipher: cipher,
    ).since(conversationId: 'c', afterSeq: 0);
    expect(result.isErr, isTrue);
    expect(result.failureOrNull!.code, FailureCode.internal);
  });
}

class _FailAfterBodyDatabase implements Database {
  _FailAfterBodyDatabase(this.inner);
  final Database inner;
  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) =>
      inner.transaction<T>((tx) async {
        await body(tx);
        throw StateError('forced commit failure');
      });
  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      inner.execute(sql, args);
  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) => inner.query(sql, args);
  @override
  Future<int> schemaVersion() => inner.schemaVersion();
  @override
  Future<String> integrityCheck() => inner.integrityCheck();
}
