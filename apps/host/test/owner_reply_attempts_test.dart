import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts.dart';
import 'package:jingyu_host/src/brain/owner_reply_attempts_migration.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const ledger = OwnerReplyAttempts();

OwnerReplyAttemptClaim claim({
  String source = 'source-1',
  String profile = 'profile-1',
  String owner = 'owner-1',
  String request = 'request-1',
  int revision = 1,
}) => OwnerReplyAttemptClaim(
  sourceMessageId: source,
  aiProfileId: profile,
  ownerAccountId: owner,
  aiAccountId: 'ai-account-1',
  conversationId: 'conversation-1',
  grantRevision: revision,
  requestId: request,
);

Future<OwnerReplyAttempt?> read(
  SqliteDatabase db, {
  String owner = 'owner-1',
  String source = 'source-1',
  String profile = 'profile-1',
}) => db.transaction(
  (tx) => ledger.getForOwnerInTx(
    tx,
    ownerAccountId: owner,
    sourceMessageId: source,
    aiProfileId: profile,
  ),
);

Future<bool> finish(
  SqliteDatabase db,
  OwnerReplyAttemptStatus status, {
  String owner = 'owner-1',
  String request = 'request-1',
  String? replyId,
  FailureCode? failureCode,
}) => db.transaction(
  (tx) => ledger.finishInTx(
    tx,
    ownerAccountId: owner,
    sourceMessageId: 'source-1',
    aiProfileId: 'profile-1',
    requestId: request,
    status: status,
    replyId: replyId,
    failureCode: failureCode,
  ),
);

// A separate isolate is necessary: BEGIN IMMEDIATE/busy_timeout is synchronous;
// two connections on the same event loop cannot release a lock while blocked.
Future<void> concurrentWorker((String, SendPort, bool) args) async {
  final control = ReceivePort();
  SqliteDatabase? db;
  try {
    db = await SqliteDatabase.open(
      args.$1,
      migrations: [...allMigrations, ownerReplyAttemptsMigration],
    );
    args.$2.send(control.sendPort);
    await control.first;
    final won = await db.transaction(
      (tx) => args.$3
          ? ledger.finishInTx(
              tx,
              ownerAccountId: 'owner-1',
              sourceMessageId: 'source-1',
              aiProfileId: 'profile-1',
              requestId: 'request-1',
              status: OwnerReplyAttemptStatus.completed,
              replyId: 'reply-1',
            )
          : ledger.claimInTx(tx, claim: claim()),
    );
    await db.close();
    db = null;
    args.$2.send(won);
  } catch (error) {
    args.$2.send(error.runtimeType.toString());
  } finally {
    control.close();
    await db?.close();
  }
}

void main() {
  late Directory dir;
  late String path;
  late SqliteDatabase db;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('reply-attempt-ledger-');
    path = '${dir.path}/test.sqlite';
    db = await SqliteDatabase.open(
      path,
      migrations: [...allMigrations, ownerReplyAttemptsMigration],
    );
  });
  tearDown(() async {
    await db.close();
    await dir.delete(recursive: true);
  });

  test(
    'claim persists only metadata and cannot replay under a new revision/owner/request',
    () async {
      expect(
        await db.transaction((tx) => ledger.claimInTx(tx, claim: claim())),
        isTrue,
      );
      expect(
        await db.transaction(
          (tx) => ledger.claimInTx(
            tx,
            claim: claim(revision: 2, owner: 'owner-2', request: 'request-2'),
          ),
        ),
        isFalse,
      );
      final attempt = (await read(db))!;
      expect(attempt.claim.sourceMessageId, 'source-1');
      expect(attempt.claim.aiProfileId, 'profile-1');
      expect(attempt.claim.ownerAccountId, 'owner-1');
      expect(attempt.claim.aiAccountId, 'ai-account-1');
      expect(attempt.claim.conversationId, 'conversation-1');
      expect(attempt.claim.grantRevision, 1);
      expect(attempt.claim.requestId, 'request-1');
      expect(attempt.status, OwnerReplyAttemptStatus.pending);
      expect(attempt.replyId, isNull);
      expect(attempt.failureCode, isNull);
      final columns = await db.query('PRAGMA table_info(owner_reply_attempts)');
      expect(columns.map((row) => row['name']).toSet(), {
        'source_message_id',
        'ai_profile_id',
        'owner_account_id',
        'ai_account_id',
        'conversation_id',
        'grant_revision',
        'request_id',
        'status',
        'reply_id',
        'safe_failure_code',
      });
    },
  );

  test(
    'different source/profile keys are independent; owner read fails closed',
    () async {
      await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
      expect(
        await db.transaction(
          (tx) => ledger.claimInTx(
            tx,
            claim: claim(source: 'source-2', owner: 'owner-2'),
          ),
        ),
        isTrue,
      );
      expect(
        await db.transaction(
          (tx) => ledger.claimInTx(tx, claim: claim(profile: 'profile-2')),
        ),
        isTrue,
      );
      expect(await read(db, owner: 'owner-2'), isNull);
      expect(await read(db, source: 'missing'), isNull);
      expect(await read(db, owner: 'owner-2', source: 'source-2'), isNotNull);
    },
  );

  test(
    'claim participates in caller rollback, leaving the key unclaimed',
    () async {
      await expectLater(
        db.transaction<void>((tx) async {
          expect(await ledger.claimInTx(tx, claim: claim()), isTrue);
          throw StateError('caller rollback');
        }),
        throwsStateError,
      );
      expect(await read(db), isNull);
      expect(
        await db.transaction((tx) => ledger.claimInTx(tx, claim: claim())),
        isTrue,
      );
    },
  );

  for (final target in [
    OwnerReplyAttemptStatus.completed,
    OwnerReplyAttemptStatus.failed,
    OwnerReplyAttemptStatus.discarded,
  ]) {
    test(
      'pending -> ${target.name} is one-shot, durable, and cannot be reclaimed',
      () async {
        await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
        final reply = target == OwnerReplyAttemptStatus.completed
            ? 'reply-1'
            : null;
        final failure = target == OwnerReplyAttemptStatus.failed
            ? FailureCode.unavailable
            : null;
        expect(
          await finish(db, target, replyId: reply, failureCode: failure),
          isTrue,
        );
        expect(
          await finish(db, target, replyId: reply, failureCode: failure),
          isFalse,
        );
        expect(await finish(db, OwnerReplyAttemptStatus.discarded), isFalse);
        expect(
          await db.transaction(
            (tx) => ledger.claimInTx(
              tx,
              claim: claim(revision: 99, request: 'new-request'),
            ),
          ),
          isFalse,
        );
        await db.close();
        db = await SqliteDatabase.open(
          path,
          migrations: [...allMigrations, ownerReplyAttemptsMigration],
        );
        final attempt = (await read(db))!;
        expect(attempt.status, target);
        expect(attempt.replyId, reply);
        expect(attempt.failureCode, failure);
        expect(await db.integrityCheck(), 'ok');
      },
    );
  }

  test(
    'finish checks owner/request and rolls back with caller transaction',
    () async {
      await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
      expect(
        await finish(
          db,
          OwnerReplyAttemptStatus.completed,
          owner: 'wrong-owner',
          replyId: 'reply-1',
        ),
        isFalse,
      );
      expect(
        await finish(
          db,
          OwnerReplyAttemptStatus.completed,
          request: 'wrong-request',
          replyId: 'reply-1',
        ),
        isFalse,
      );
      await expectLater(
        db.transaction<void>((tx) async {
          expect(
            await ledger.finishInTx(
              tx,
              ownerAccountId: 'owner-1',
              sourceMessageId: 'source-1',
              aiProfileId: 'profile-1',
              requestId: 'request-1',
              status: OwnerReplyAttemptStatus.completed,
              replyId: 'reply-1',
            ),
            isTrue,
          );
          throw StateError('rollback completion');
        }),
        throwsStateError,
      );
      expect((await read(db))!.status, OwnerReplyAttemptStatus.pending);
      expect(
        await finish(db, OwnerReplyAttemptStatus.completed, replyId: 'reply-1'),
        isTrue,
      );
    },
  );

  test('invalid claim/finish input does not change storage', () async {
    for (final invalid in [
      claim(source: ''),
      claim(owner: 'owner/invalid'),
      claim(request: 'secret with spaces'),
      claim(request: List<String>.filled(65, 'x').join()),
      claim(revision: -1),
    ]) {
      await expectLater(
        db.transaction((tx) => ledger.claimInTx(tx, claim: invalid)),
        throwsA(anyOf(isA<ArgumentError>(), isA<FormatException>())),
      );
    }
    expect(await read(db), isNull);
    await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
    await expectLater(
      finish(db, OwnerReplyAttemptStatus.pending),
      throwsArgumentError,
    );
    await expectLater(
      finish(db, OwnerReplyAttemptStatus.completed),
      throwsArgumentError,
    );
    await expectLater(
      finish(
        db,
        OwnerReplyAttemptStatus.completed,
        replyId: 'reply-1',
        failureCode: FailureCode.internal,
      ),
      throwsArgumentError,
    );
    await expectLater(
      finish(db, OwnerReplyAttemptStatus.failed),
      throwsArgumentError,
    );
    await expectLater(
      finish(db, OwnerReplyAttemptStatus.discarded, replyId: 'reply-1'),
      throwsArgumentError,
    );
    expect((await read(db))!.status, OwnerReplyAttemptStatus.pending);
    expect(
      await finish(
        db,
        OwnerReplyAttemptStatus.discarded,
        failureCode: FailureCode.forbidden,
      ),
      isTrue,
    );
    expect((await read(db))!.failureCode, FailureCode.forbidden);
  });

  test(
    'database rejects invalid status, unsafe failure text and invalid terminal shape',
    () async {
      await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
      for (final sql in [
        "UPDATE owner_reply_attempts SET status='retry'",
        "UPDATE owner_reply_attempts SET status='failed',safe_failure_code='private provider error'",
        "UPDATE owner_reply_attempts SET status='completed'",
      ]) {
        await expectLater(db.execute(sql), throwsA(isA<Exception>()));
      }
      expect(
        await finish(db, OwnerReplyAttemptStatus.completed, replyId: 'reply-1'),
        isTrue,
      );
    },
  );

  test(
    'corrupt stored enum fails safely without reflecting private text',
    () async {
      await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
      // Deliberately corrupt a controlled fixture; ordinary writes cannot do this.
      await db.execute('PRAGMA ignore_check_constraints=ON');
      try {
        for (final patch in [
          "status='private-corrupt-status'",
          "status='failed',safe_failure_code='private-provider-secret'",
        ]) {
          await db.execute('UPDATE owner_reply_attempts SET $patch');
          expect(await read(db, owner: 'other-owner'), isNull);
          await expectLater(
            read(db),
            throwsA(
              isA<StateError>().having(
                (error) => error.message,
                'message',
                'Invalid stored reply attempt',
              ),
            ),
          );
        }
      } finally {
        await db.execute('PRAGMA ignore_check_constraints=OFF');
      }
    },
  );

  test('request id length 64 is accepted, 65 is rejected by schema', () async {
    expect(
      await db.transaction(
        (tx) => ledger.claimInTx(
          tx,
          claim: claim(request: List<String>.filled(64, 'x').join()),
        ),
      ),
      isTrue,
    );
    await expectLater(
      db.execute('UPDATE owner_reply_attempts SET request_id=?', [
        List<String>.filled(65, 'x').join(),
      ]),
      throwsA(isA<Exception>()),
    );
  });

  // Raw SQL bypasses validateId: schema must independently reject NUL/BLOB.
  for (final column in [
    'source_message_id',
    'ai_profile_id',
    'owner_account_id',
    'ai_account_id',
    'conversation_id',
    'request_id',
    'reply_id',
  ]) {
    for (final asBlob in [false, true]) {
      test('schema rejects ${asBlob ? 'BLOB' : 'NUL'} in $column', () async {
        await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
        if (column == 'reply_id') {
          await finish(
            db,
            OwnerReplyAttemptStatus.completed,
            replyId: 'reply-1',
          );
        }
        final Object invalid = asBlob
            ? Uint8List.fromList([97, 98, 99])
            : 'abc\u0000hidden suffix';
        await expectLater(
          db.execute('UPDATE owner_reply_attempts SET $column=?', [invalid]),
          throwsA(isA<Exception>()),
        );
        final row = (await db.query(
          'SELECT * FROM owner_reply_attempts',
        )).single;
        expect(row[column], isNot(invalid));
      });
    }
  }

  for (final finishing in [false, true]) {
    test(
      'two independent SQLite connections race: exactly one ${finishing ? 'finish' : 'claim'} wins',
      () async {
        if (finishing) {
          await db.transaction((tx) => ledger.claimInTx(tx, claim: claim()));
        }
        final events = ReceivePort();
        final messages = StreamIterator<dynamic>(events);
        final isolates = <Isolate>[];
        try {
          for (var i = 0; i < 2; i++) {
            isolates.add(
              await Isolate.spawn(concurrentWorker, (
                path,
                events.sendPort,
                finishing,
              )),
            );
          }
          final starts = <SendPort>[];
          while (starts.length < 2) {
            expect(
              await messages.moveNext().timeout(const Duration(seconds: 15)),
              isTrue,
            );
            expect(messages.current, isA<SendPort>());
            starts.add(messages.current as SendPort);
          }
          for (final start in starts) {
            start.send(null);
          }
          final outcomes = <dynamic>[];
          while (outcomes.length < 2) {
            expect(
              await messages.moveNext().timeout(const Duration(seconds: 15)),
              isTrue,
            );
            outcomes.add(messages.current);
          }
          expect(outcomes.where((value) => value == true).length, 1);
          expect(outcomes.where((value) => value == false).length, 1);
          expect(
            (await db.query('SELECT * FROM owner_reply_attempts')).length,
            1,
          );
        } finally {
          for (final isolate in isolates) {
            isolate.kill(priority: Isolate.immediate);
          }
          await messages.cancel();
          events.close();
        }
      },
    );
  }
}
