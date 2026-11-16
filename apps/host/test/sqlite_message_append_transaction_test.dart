import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase database;
  late AesGcmColumnCipher cipher;
  late SqliteMessageStore store;
  final sentAt = DateTime.utc(2026, 11, 17, 3);

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    path,
    migrations: [...allMigrations, ...messagesMigrations],
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('jingyu-message-tx-');
    path = '${dir.path}/host.sqlite';
    database = await openDatabase();
    await database.execute(
      'CREATE TABLE caller_changes (id TEXT PRIMARY KEY, allowed INTEGER NOT NULL)',
    );
    cipher = AesGcmColumnCipher(List<int>.filled(32, 17));
    var id = 0;
    store = SqliteMessageStore(
      database: database,
      cipher: cipher,
      clock: FakeClock(sentAt),
      newId: () => 'tx-message-${++id}',
    );
  });

  tearDown(() async {
    await database.close();
    cipher.dispose();
    await dir.delete(recursive: true);
  });

  test(
    'caller write and read compose with append using only the supplied Tx',
    () async {
      final result = await database.transaction((tx) async {
        await tx.execute(
          'INSERT INTO caller_changes(id, allowed) VALUES (?, ?)',
          ['caller', 1],
        );
        expect(
          (await tx.query('SELECT allowed FROM caller_changes WHERE id = ?', [
            'caller',
          ])).single['allowed'],
          1,
        );
        final result = await store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'one',
          kind: MessageKind.text,
          body: const {'text': 'accepted'},
        );
        expect(await store.headSeqInTransaction(tx, 'c'), 1);
        return result;
      });

      expect(result.isOk, isTrue);
      expect(result.value.duplicate, isFalse);
      expect(result.value.message.seq, 1);
      expect(result.value.message.sentAt, sentAt);
      expect((await database.query('SELECT * FROM caller_changes')).length, 1);
      expect(
        (await store.since(
          conversationId: 'c',
          afterSeq: 0,
        )).value.messages.single.body,
        {'text': 'accepted'},
      );
    },
  );

  test(
    'caller revocation check can decline append with zero sequence writes',
    () async {
      await database.execute(
        'INSERT INTO caller_changes(id, allowed) VALUES (?, ?)',
        ['authorization', 1],
      );
      final denied = await database.transaction<Result<AppendResult>>((
        tx,
      ) async {
        await tx.execute('UPDATE caller_changes SET allowed = 0 WHERE id = ?', [
          'authorization',
        ]);
        final current = await tx.query(
          'SELECT allowed FROM caller_changes WHERE id = ?',
          ['authorization'],
        );
        if (current.single['allowed'] != 1) {
          return err(FailureCode.forbidden, 'caller declined append');
        }
        return store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'declined',
          kind: MessageKind.text,
          body: const {'text': 'must not append'},
        );
      });
      expect(denied.failureOrNull?.code, FailureCode.forbidden);
      expect(await database.query('SELECT * FROM message_heads'), isEmpty);
      expect(await database.query('SELECT * FROM messages'), isEmpty);
      expect(
        (await database.query(
          'SELECT allowed FROM caller_changes',
        )).single['allowed'],
        0,
      );
    },
  );

  test(
    'caller exception rolls back caller changes, append and sequence allocation',
    () async {
      await expectLater(
        database.transaction<void>((tx) async {
          await tx.execute(
            'INSERT INTO caller_changes(id, allowed) VALUES (?, ?)',
            ['rollback', 1],
          );
          final result = await store.appendInTransaction(
            tx,
            conversationId: 'c',
            senderId: 'u',
            clientMsgId: 'rolled-back',
            kind: MessageKind.text,
            body: const {'text': 'must not persist'},
          );
          expect(result.isOk, isTrue);
          throw StateError('caller rejects transaction');
        }),
        throwsStateError,
      );
      expect(await database.query('SELECT * FROM caller_changes'), isEmpty);
      expect(await database.query('SELECT * FROM messages'), isEmpty);
      expect(await database.query('SELECT * FROM message_heads'), isEmpty);
      final retry = await store.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'rolled-back',
        kind: MessageKind.text,
        body: const {'text': 'retry'},
      );
      expect(retry.value.duplicate, isFalse);
      expect(retry.value.message.seq, 1);
    },
  );

  test(
    'SQL failure after head allocation rolls back caller write and head',
    () async {
      await database.execute('''
CREATE TRIGGER reject_append BEFORE INSERT ON messages
BEGIN SELECT RAISE(ABORT, 'forced message insert failure'); END
''');
      await expectLater(
        database.transaction((tx) async {
          await tx.execute(
            'INSERT INTO caller_changes(id, allowed) VALUES (?, ?)',
            ['failed-insert', 1],
          );
          return store.appendInTransaction(
            tx,
            conversationId: 'c',
            senderId: 'u',
            clientMsgId: 'sql-failure',
            kind: MessageKind.text,
            body: const {'text': 'fails after head allocation'},
          );
        }),
        throwsA(isA<Exception>()),
      );
      expect(await database.query('SELECT * FROM caller_changes'), isEmpty);
      expect(await database.query('SELECT * FROM message_heads'), isEmpty);
      expect(await database.query('SELECT * FROM messages'), isEmpty);
    },
  );

  test(
    'invalid client ids do not allocate a sequence or insert a message',
    () async {
      for (final clientId in ['', 'x' * 65]) {
        await database.transaction((tx) async {
          final result = await store.appendInTransaction(
            tx,
            conversationId: 'c',
            senderId: 'u',
            clientMsgId: clientId,
            kind: MessageKind.text,
            body: const {},
          );
          expect(result.failureOrNull?.code, FailureCode.invalidArgument);
          expect(await store.headSeqInTransaction(tx, 'c'), 0);
        });
      }
      expect(await database.query('SELECT * FROM message_heads'), isEmpty);
      expect(await database.query('SELECT * FROM messages'), isEmpty);
    },
  );

  test(
    'unserializable body leaves head unchanged and does not undo caller writes',
    () async {
      await store.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'existing',
        kind: MessageKind.text,
        body: const {'text': 'one'},
      );
      await database.transaction((tx) async {
        await tx.execute(
          'INSERT INTO caller_changes(id, allowed) VALUES (?, ?)',
          ['caller-controls-commit', 1],
        );
        final result = await store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'invalid-body',
          kind: MessageKind.text,
          body: {'unsupported': Object()},
        );
        expect(result.failureOrNull?.code, FailureCode.invalidArgument);
        expect(await store.headSeqInTransaction(tx, 'c'), 1);
      });
      expect(await store.headSeq('c'), 1);
      expect((await database.query('SELECT * FROM messages')).length, 1);
      expect((await database.query('SELECT * FROM caller_changes')).length, 1);
    },
  );

  test(
    'transaction helper and wrapper share sender-scoped idempotency',
    () async {
      late AppendResult first;
      await database.transaction((tx) async {
        first = (await store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'same',
          kind: MessageKind.text,
          body: const {'text': 'first'},
        )).value;
        // Existing append checks idempotency before attempting serialization.
        final duplicate = (await store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'same',
          kind: MessageKind.file,
          body: {'unsupported': Object()},
        )).value;
        expect(duplicate.duplicate, isTrue);
        expect(duplicate.message.messageId, first.message.messageId);
        expect(duplicate.message.kind, MessageKind.text);
        expect(duplicate.message.body, {'text': 'first'});
        final otherSender = (await store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'other',
          clientMsgId: 'same',
          kind: MessageKind.text,
          body: const {'text': 'other sender'},
        )).value;
        expect(otherSender.duplicate, isFalse);
        expect(otherSender.message.seq, 2);
      });
      final wrapperDuplicate = (await store.append(
        conversationId: 'c',
        senderId: 'u',
        clientMsgId: 'same',
        kind: MessageKind.text,
        body: const {'text': 'ignored retry'},
      )).value;
      expect(wrapperDuplicate.duplicate, isTrue);
      expect(wrapperDuplicate.message.messageId, first.message.messageId);
      expect(await store.headSeq('c'), 2);
    },
  );

  test(
    'serialized snapshot is detached and top-level body stays unmodifiable',
    () async {
      final nested = <String, Object?>{'value': 'original'};
      final callerBody = <String, Object?>{'nested': nested};
      final result = (await database.transaction(
        (tx) => store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'snapshot',
          kind: MessageKind.text,
          body: callerBody,
        ),
      )).value;
      nested['value'] = 'caller mutation';
      callerBody['added'] = true;
      expect(result.message.body, {
        'nested': {'value': 'original'},
      });
      expect(() => result.message.body['added'] = true, throwsUnsupportedError);
      final duplicate = (await database.transaction(
        (tx) => store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'snapshot',
          kind: MessageKind.text,
          body: const {},
        ),
      )).value;
      expect(duplicate.message.body, {
        'nested': {'value': 'original'},
      });
      expect(() => duplicate.message.body.clear(), throwsUnsupportedError);
    },
  );

  test(
    'caller-transaction append persists ciphertext and survives restart',
    () async {
      const secret = 'transaction body private 72719c';
      await database.transaction(
        (tx) => store.appendInTransaction(
          tx,
          conversationId: 'c',
          senderId: 'u',
          clientMsgId: 'persist',
          kind: MessageKind.text,
          body: const {'text': secret},
        ),
      );
      final sealed = (await database.query(
        'SELECT body FROM messages',
      )).single['body'];
      expect(sealed, isA<String>());
      expect(sealed as String, isNot(contains(secret)));
      await database.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      for (final file in dir.listSync(recursive: true).whereType<File>()) {
        expect(
          utf8.decode(file.readAsBytesSync(), allowMalformed: true),
          isNot(contains(secret)),
        );
      }
      await database.close();
      database = await openDatabase();
      final restarted = SqliteMessageStore(database: database, cipher: cipher);
      expect(await restarted.headSeq('c'), 1);
      final page = (await restarted.since(
        conversationId: 'c',
        afterSeq: 0,
      )).value;
      expect(page.messages.single.body, {'text': secret});
    },
  );
}
