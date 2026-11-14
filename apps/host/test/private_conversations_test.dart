import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/friendship_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const migrations = [
  ...allMigrations,
  ...accountsMigrations,
  ...socialMigrations,
  friendshipMigration,
  privateConversationMigration,
];

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late PrivateConversations direct;
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  FriendshipService asActor(String actor) => FriendshipService(
    actorId: AccountId.parse(actor),
    database: db,
    clock: clock,
  );
  Future<void> friends(String a, String b) async {
    expect((await asActor(a).request(AccountId.parse(b))).isOk, isTrue);
    expect((await asActor(b).accept(AccountId.parse(a))).isOk, isTrue);
  }

  Future<PrivateConversation> open() async {
    final result = await direct.open(actorId: 'a', targetId: 'b');
    expect(result.isOk, isTrue);
    return result.value;
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('private-conversations-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    direct = PrivateConversations(db: db, clock: clock);
    for (final name in ['a', 'b', 'c', 'ai_b', 'orphan_ai']) {
      final ai = name.contains('ai');
      await db.execute(
        '''INSERT INTO account
        (id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
        VALUES (?,?,?,0,0,?,0,0)''',
        [name, name, ai ? 'ai' : 'human', ai ? null : 'hash'],
      );
    }
    await db.execute(
      'INSERT INTO ai_operator(ai_id,operator_id) VALUES (?,?)',
      ['ai_b', 'b'],
    );
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('only mutual consent opens one canonical direct pair', () async {
    expect(
      (await direct.open(actorId: 'a', targetId: 'b')).failureOrNull?.code,
      FailureCode.forbidden,
    );
    await asActor('a').request(AccountId.parse('b'));
    expect((await direct.open(actorId: 'a', targetId: 'b')).isErr, isTrue);
    await asActor('b').accept(AccountId.parse('a'));
    final first = await open();
    final reverse = await direct.open(actorId: 'b', targetId: 'a');
    expect(reverse.value.id, first.id);
    expect(first.accountLow, 'a');
    expect(first.accountHigh, 'b');
    expect(first.createdAt, DateTime.utc(2026, 11, 13));
    expect(first.toJson()['kind'], 'direct');
    expect((await db.query('SELECT * FROM direct_conversations')).length, 1);
    expect((await db.query('SELECT * FROM social_conversations')), isEmpty);
    expect((await direct.list('a')).value.single.id, first.id);
    expect((await direct.list('b')).value.single.id, first.id);
    expect((await direct.list('c')).value, isEmpty);
  });

  test(
    'nonmembers get not found and never acquire history or posting rights',
    () async {
      await friends('a', 'b');
      final conversation = await open();
      for (final member in ['a', 'b']) {
        expect(
          (await direct.get(
            accountId: member,
            conversationId: conversation.id,
          )).value.id,
          conversation.id,
        );
        expect(await direct.canRead(member, conversation.id), isTrue);
        expect(await direct.firstVisibleSeq(member, conversation.id), 1);
        expect(await direct.canPost(member, conversation.id), isTrue);
      }
      for (final hidden in [conversation.id, 'unknown']) {
        final result = await direct.get(accountId: 'c', conversationId: hidden);
        expect(result.failureOrNull?.code, FailureCode.notFound);
        expect(await direct.firstVisibleSeq('c', hidden), isNull);
        expect(await direct.canRead('c', hidden), isFalse);
        expect(await direct.canPost('c', hidden), isFalse);
      }
    },
  );

  test(
    'block preserves both members history but fresh accepted friendship is required to post',
    () async {
      await friends('a', 'b');
      final conversation = await open();
      await asActor('a').block(AccountId.parse('b'));
      for (final member in ['a', 'b']) {
        expect(await direct.canPost(member, conversation.id), isFalse);
        expect(await direct.canRead(member, conversation.id), isTrue);
        expect(await direct.firstVisibleSeq(member, conversation.id), 1);
        expect((await direct.list(member)).value.single.id, conversation.id);
        expect(
          (await direct.get(
            accountId: member,
            conversationId: conversation.id,
          )).isOk,
          isTrue,
        );
      }
      expect(
        (await direct.open(actorId: 'a', targetId: 'b')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      // A third party sees the same ordinary lack of consent before/after A's block.
      expect(
        (await direct.open(actorId: 'c', targetId: 'a')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      await asActor('a').unblock(AccountId.parse('b'));
      expect(await direct.canPost('a', conversation.id), isFalse);
      expect(await direct.canPost('b', conversation.id), isFalse);
      await asActor('b').request(AccountId.parse('a'));
      expect(await direct.canPost('b', conversation.id), isFalse);
      await asActor('a').accept(AccountId.parse('b'));
      expect(await direct.canPost('a', conversation.id), isTrue);
      expect(await direct.canPost('b', conversation.id), isTrue);
      expect(
        (await direct.open(actorId: 'b', targetId: 'a')).value.id,
        conversation.id,
      );
    },
  );

  test(
    'active canonical accounts and human initiation are checked each time',
    () async {
      expect(
        (await direct.open(actorId: 'a', targetId: 'a')).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await direct.open(actorId: '', targetId: 'b')).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await direct.open(
          actorId: 'a',
          targetId: 'missing',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await direct.open(actorId: 'ai_b', targetId: 'a')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      await asActor('a').request(AccountId.parse('ai_b'));
      expect(
        (await direct.open(actorId: 'a', targetId: 'ai_b')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(
        (await direct.open(
          actorId: 'a',
          targetId: 'orphan_ai',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await friends('a', 'b');
      final conversation = await open();
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['b']);
      expect(
        (await direct.open(actorId: 'a', targetId: 'b')).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(await direct.canPost('a', conversation.id), isFalse);
      expect(await direct.canPost('b', conversation.id), isFalse);
      expect(await direct.canRead('a', conversation.id), isTrue);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', ['b']);
      expect(await direct.canPost('b', conversation.id), isTrue);
    },
  );

  test(
    'trusted AI member posting requires a valid active operator and inherited blocks',
    () async {
      // No public AI consent exists. Model an existing trusted/internal membership
      // without granting any public API for creating AI friendship or conversations.
      await db.execute('INSERT INTO friendships VALUES (?,?,?)', [
        'a',
        'ai_b',
        0,
      ]);
      await db.execute('INSERT INTO direct_conversations VALUES (?,?,?,?)', [
        'legacy_ai',
        'a',
        'ai_b',
        0,
      ]);
      expect(await direct.canPost('ai_b', 'legacy_ai'), isTrue);
      expect(
        (await direct.open(actorId: 'ai_b', targetId: 'a')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['b']);
      expect(await direct.canPost('ai_b', 'legacy_ai'), isFalse);
      expect(await direct.canPost('a', 'legacy_ai'), isFalse);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', ['b']);
      // Keep the friendship row to independently exercise the inherited-block
      // policy, rather than relying on FriendshipService.block deleting consent.
      await db.execute('INSERT INTO account_blocks VALUES (?,?,?)', [
        'a',
        'b',
        0,
      ]);
      expect(
        (await direct.open(actorId: 'a', targetId: 'ai_b')).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect(await direct.canPost('ai_b', 'legacy_ai'), isFalse);
      expect(await direct.canPost('a', 'legacy_ai'), isFalse);
      expect(await direct.canRead('ai_b', 'legacy_ai'), isTrue);
      expect(await direct.firstVisibleSeq('ai_b', 'legacy_ai'), 1);
      expect((await direct.list('c')).value, isEmpty);
    },
  );

  test(
    'parallel opens converge and reopening SQLite preserves id and creation time',
    () async {
      await friends('a', 'b');
      final results = await Future.wait(
        List.generate(
          8,
          (i) => direct.open(
            actorId: i.isEven ? 'a' : 'b',
            targetId: i.isEven ? 'b' : 'a',
          ),
        ),
      );
      expect(results.every((r) => r.isOk), isTrue);
      expect(results.map((r) => r.value.id).toSet(), hasLength(1));
      final first = results.first.value;
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      direct = PrivateConversations(
        db: db,
        clock: FakeClock(DateTime.utc(2027)),
      );
      final reopened = await open();
      expect(reopened.id, first.id);
      expect(reopened.createdAt, DateTime.utc(2026, 11, 13));
      expect(await direct.firstVisibleSeq('b', first.id), 1);
      expect(await db.integrityCheck(), 'ok');
      expect(
        (await db.query('SELECT * FROM direct_conversations')),
        hasLength(1),
      );
      await expectLater(
        db.execute('INSERT INTO direct_conversations VALUES (?,?,?,?)', [
          'duplicate',
          'a',
          'b',
          0,
        ]),
        throwsA(anything),
      );
      await expectLater(
        db.execute('INSERT INTO direct_conversations VALUES (?,?,?,?)', [
          'reverse',
          'b',
          'a',
          0,
        ]),
        throwsA(anything),
      );
    },
  );

  test(
    'failed open rolls back and a retry can create the conversation',
    () async {
      await friends('a', 'b');
      await db.execute(
        "CREATE TRIGGER reject_direct BEFORE INSERT ON direct_conversations BEGIN SELECT RAISE(ABORT, 'injected'); END",
      );
      await expectLater(
        direct.open(actorId: 'a', targetId: 'b'),
        throwsA(anything),
      );
      expect((await direct.list('a')).value, isEmpty);
      await db.execute('DROP TRIGGER reject_direct');
      expect((await direct.open(actorId: 'a', targetId: 'b')).isOk, isTrue);
    },
  );
}
