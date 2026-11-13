import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/friendship_service.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:test/test.dart';

const baseMigrations = [
  ...allMigrations,
  ...accountsMigrations,
  Migration(
    504,
    'existing higher version',
    'CREATE TABLE existing_high (id TEXT);',
  ),
];
const migrations = [...baseMigrations, friendshipMigration];
AccountId id(String value) => AccountId.parse(value);

void main() {
  late Directory directory;
  late SqliteDatabase db;
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  FriendshipService asActor(String actor) =>
      FriendshipService(actorId: id(actor), database: db, clock: clock);
  Future<void> friends(String a, String b) async {
    expect((await asActor(a).request(id(b))).isOk, isTrue);
    expect((await asActor(b).accept(id(a))).isOk, isTrue);
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('friendship-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: baseMigrations,
    );
    await db.close();
    // 301 must be applied even when the existing database has reached 504.
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: migrations,
    );
    for (final name in ['a', 'b', 'c', 'ai_a', 'ai_b', 'ai_b2']) {
      final ai = name.startsWith('ai_');
      await db.execute(
        '''INSERT INTO account
        (id,display_name,kind,is_admin,disabled,password_hash,failed_passwords,locked_until)
        VALUES (?,?,?,0,0,?,0,0)''',
        [name, name, ai ? 'ai' : 'human', ai ? null : 'hash'],
      );
      if (ai) {
        await db.execute(
          'INSERT INTO ai_operator(ai_id,operator_id) VALUES (?,?)',
          [name, name == 'ai_a' ? 'a' : 'b'],
        );
      }
    }
  });
  tearDown(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'pending requires target consent, is idempotent, and isolates C',
    () async {
      final a = asActor('a');
      expect((await a.request(id('b'))).isOk, isTrue);
      expect((await a.request(id('b'))).isOk, isTrue);
      expect(
        (await a.getState(id('b'))).value,
        FriendshipState.outgoingPending,
      );
      expect(
        (await asActor('b').getState(id('a'))).value,
        FriendshipState.incomingPending,
      );
      expect(await a.areFriends(id('a'), id('b')), isFalse);
      expect((await asActor('c').accept(id('a'))).isErr, isTrue);
      expect((await a.accept(id('b'))).isErr, isTrue);
      expect(
        (await asActor('c').getState(id('a'))).value,
        FriendshipState.none,
      );
      expect((await asActor('b').accept(id('a'))).isOk, isTrue);
      expect((await asActor('b').accept(id('a'))).isOk, isTrue);
      expect(await a.areFriends(id('b'), id('a')), isTrue);
      expect((await a.getState(id('b'))).value, FriendshipState.friends);
      expect((await db.query('SELECT * FROM friendships')).length, 1);
      expect((await db.query('SELECT * FROM friend_requests')).length, 1);
    },
  );

  test(
    'crossed requests do not silently become consent; deny permits a new application',
    () async {
      await asActor('a').request(id('b'));
      await asActor('b').request(id('a'));
      expect(await asActor('a').areFriends(id('a'), id('b')), isFalse);
      expect((await asActor('c').deny(id('a'))).isErr, isTrue);
      expect((await asActor('b').deny(id('a'))).isOk, isTrue);
      expect((await asActor('b').deny(id('a'))).isOk, isTrue);
      expect((await asActor('b').accept(id('a'))).isErr, isTrue);
      expect((await asActor('a').request(id('b'))).isOk, isTrue);
      expect((await asActor('b').accept(id('a'))).isOk, isTrue);
    },
  );

  test(
    'AI cannot initiate or consent and operator cannot consent on its behalf',
    () async {
      expect(
        (await asActor('ai_a').request(id('b'))).failureOrNull?.code,
        FailureCode.forbidden,
      );
      expect((await asActor('a').request(id('ai_b'))).isOk, isTrue);
      expect((await asActor('ai_b').accept(id('a'))).isErr, isTrue);
      expect((await asActor('b').accept(id('a'))).isErr, isTrue);
      expect(await asActor('a').areFriends(id('a'), id('ai_b')), isFalse);
      expect(
        (await asActor('a').getState(id('ai_b'))).value,
        FriendshipState.outgoingPending,
      );
    },
  );

  test(
    'block is bilateral, invalidates consent, and unblock requires new application',
    () async {
      await friends('a', 'b');
      expect((await asActor('a').block(id('b'))).isOk, isTrue);
      expect((await asActor('a').block(id('b'))).isOk, isTrue);
      expect(await asActor('b').isBlocked(id('b'), id('a')), isTrue);
      expect(await asActor('b').areFriends(id('a'), id('b')), isFalse);
      expect((await asActor('b').request(id('a'))).isErr, isTrue);
      expect((await asActor('b').accept(id('a'))).isErr, isTrue);
      expect(
        (await asActor('b').getState(id('a'))).value,
        FriendshipState.blocked,
      );
      await asActor('b').unblock(id('a')); // Cannot remove A's block.
      expect(await asActor('a').isBlocked(id('a'), id('b')), isTrue);
      await asActor('a').unblock(id('b'));
      await asActor('a').unblock(id('b'));
      expect(await asActor('a').isBlocked(id('a'), id('b')), isFalse);
      expect(await asActor('a').areFriends(id('a'), id('b')), isFalse);
      expect((await asActor('b').accept(id('a'))).isErr, isTrue);
      await friends('a', 'b');
    },
  );

  test(
    'human block inherits through canonical operator mapping; single AI block does not',
    () async {
      await asActor('a').request(id('ai_b'));
      await asActor('a').block(id('b'));
      for (final other in ['b', 'ai_b', 'ai_b2']) {
        expect(await asActor('a').isBlocked(id('a'), id(other)), isTrue);
        expect(await asActor('a').isBlocked(id(other), id('a')), isTrue);
      }
      expect(await asActor('c').isBlocked(id('c'), id('ai_b')), isFalse);
      await asActor('a').unblock(id('b'));
      expect(
        (await asActor('a').getState(id('ai_b'))).value,
        FriendshipState.none,
      );
      await asActor('a').block(id('ai_b'));
      expect(await asActor('a').isBlocked(id('a'), id('ai_b')), isTrue);
      expect(await asActor('a').isBlocked(id('a'), id('b')), isFalse);
      expect(await asActor('a').isBlocked(id('a'), id('ai_b2')), isFalse);
    },
  );

  test(
    'checks current account and operator active state after service construction',
    () async {
      final a = asActor('a');
      await a.request(id('b'));
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['a']);
      expect((await asActor('b').accept(id('a'))).isErr, isTrue);
      expect((await a.request(id('c'))).isErr, isTrue);
      expect((await a.block(id('c'))).isErr, isTrue);
      expect((await a.unblock(id('c'))).isErr, isTrue);
      expect((await a.getState(id('b'))).isErr, isTrue);
      await db.execute('UPDATE account SET disabled=0 WHERE id=?', ['a']);
      await asActor('b').accept(id('a'));
      await db.execute('UPDATE account SET disabled=1 WHERE id=?', ['b']);
      expect(await a.areFriends(id('a'), id('b')), isFalse);
      expect((await a.request(id('ai_b'))).isErr, isTrue);
      expect((await a.request(id('missing'))).isErr, isTrue);
      expect(
        (await a.request(id('a'))).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    },
  );

  test(
    'friendship and blocking persist and migration is safely reapplied',
    () async {
      await friends('a', 'b');
      await asActor('c').block(id('ai_a'));
      await db.close();
      db = await SqliteDatabase.open(
        '${directory.path}/host.sqlite',
        migrations: migrations,
      );
      expect(await db.schemaVersion(), 504);
      expect(await asActor('a').areFriends(id('a'), id('b')), isTrue);
      expect(await asActor('c').isBlocked(id('c'), id('ai_a')), isTrue);
      expect(await db.integrityCheck(), 'ok');
    },
  );

  test(
    'accept rollback does not consume pending request when friendship write fails',
    () async {
      await asActor('a').request(id('b'));
      await db.execute(
        "CREATE TRIGGER reject_friend BEFORE INSERT ON friendships BEGIN SELECT RAISE(ABORT, 'injected failure'); END",
      );
      await expectLater(asActor('b').accept(id('a')), throwsA(anything));
      expect(
        (await asActor('b').getState(id('a'))).value,
        FriendshipState.incomingPending,
      );
      expect(await asActor('a').areFriends(id('a'), id('b')), isFalse);
      await db.execute('DROP TRIGGER reject_friend');
      expect((await asActor('b').accept(id('a'))).isOk, isTrue);
    },
  );

  test(
    'concurrent duplicate acceptance creates one unordered friendship',
    () async {
      await asActor('a').request(id('b'));
      final results = await Future.wait(
        List.generate(6, (_) => asActor('b').accept(id('a'))),
      );
      expect(results.every((r) => r.isOk), isTrue);
      expect((await db.query('SELECT * FROM friendships')).length, 1);
    },
  );
}
