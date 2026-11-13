import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/social/social_module.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  late SqliteDatabase database;
  late ConversationService service;
  final clock = FakeClock(DateTime.utc(2026, 11, 13));
  var serial = 0;
  Future<void> open() async {
    database = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [...allMigrations, ...socialMigrations],
    );
    // Real SQLite fixtures model the two transaction-aware host capabilities.
    await database.execute(
      'CREATE TABLE IF NOT EXISTS test_accounts (id TEXT PRIMARY KEY, active INTEGER NOT NULL)',
    );
    await database.execute(
      'CREATE TABLE IF NOT EXISTS test_heads (id TEXT PRIMARY KEY, seq INTEGER NOT NULL)',
    );
    for (final id in ['alice', 'bob', 'charlie']) {
      await database.execute(
        'INSERT OR IGNORE INTO test_accounts VALUES (?, ?)',
        [id, 1],
      );
    }
    service = ConversationService(
      database: database,
      clock: clock,
      newId: () => 'group_${++serial}',
      headSeq: (tx, id) async {
        final rows = await tx.query('SELECT seq FROM test_heads WHERE id = ?', [
          id,
        ]);
        return rows.isEmpty ? 0 : rows.single['seq'] as int;
      },
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM test_accounts WHERE id = ? AND active = ?',
        [id, 1],
      )).isNotEmpty,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('jingyu-social-');
    await open();
  });
  tearDown(() async {
    await database.close();
    await directory.delete(recursive: true);
  });

  test('new groups are private and list/read/post isolate A from B', () async {
    final group = (await service.createGroup(
      ownerAccountId: 'alice',
      name: "A's group",
    )).value;
    expect(group.name, "A's group");
    expect(group.ownerAccountId, 'alice');
    expect(group.createdAt, clock.now());
    expect((await service.list('alice')).value.map((g) => g.id), [group.id]);
    expect((await service.list('bob')).value, isEmpty);
    expect(await service.canRead('alice', group.id), isTrue);
    expect(await service.canPost('alice', group.id), isTrue);
    expect(await service.canRead('bob', group.id), isFalse);
    expect(await service.canPost('bob', group.id), isFalse);
    expect(await service.firstVisibleSeq('bob', group.id), isNull);
    expect(await service.canRead('alice', 'missing'), isFalse);
    expect(await service.canPost('alice', 'missing'), isFalse);
    expect(await service.firstVisibleSeq('alice', group.id), 1);
  });

  test(
    'only owner can add members and outsiders cannot discover a group',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'group',
      )).value;
      final denied = await service.addMember(
        actorAccountId: 'bob',
        conversationId: group.id,
        memberAccountId: 'charlie',
      );
      expect(denied.failureOrNull?.code, FailureCode.notFound);
      expect(await service.canRead('charlie', group.id), isFalse);
      expect(
        (await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: 'bob',
        )).isOk,
        isTrue,
      );
      expect(await service.canRead('bob', group.id), isTrue);
      expect(await service.canPost('bob', group.id), isTrue);
      expect((await service.list('bob')).value.single.id, group.id);
      expect(
        (await service.addMember(
          actorAccountId: 'bob',
          conversationId: group.id,
          memberAccountId: 'charlie',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: 'bob',
        )).isOk,
        isTrue,
      );
      expect((await service.list('bob')).value.length, 1);
    },
  );

  test(
    'joined history starts after persisted head and duplicate invite preserves boundary on restart',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'joined',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
        group.id,
        7,
      ]);
      expect(
        (await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: 'bob',
        )).isOk,
        isTrue,
      );
      expect(await service.firstVisibleSeq('bob', group.id), 8);
      await database.execute('UPDATE test_heads SET seq = ? WHERE id = ?', [
        12,
        group.id,
      ]);
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      await database.close();
      await open();
      expect(await database.schemaVersion(), 300);
      expect(
        (await database.query(
          'SELECT version FROM schema_migrations WHERE version = ?',
          [300],
        )).length,
        1,
      );
      expect(await service.firstVisibleSeq('alice', group.id), 1);
      expect(await service.firstVisibleSeq('bob', group.id), 8);
      expect(await service.canPost('charlie', group.id), isFalse);
      expect(
        (await service.list('bob')).value.single.historyVisibility,
        HistoryVisibility.joined,
      );
      expect(await database.integrityCheck(), 'ok');
    },
  );

  test(
    'all history gives new members sequence one even with existing messages',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'all',
      )).value;
      await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
        group.id,
        9,
      ]);
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      expect(await service.firstVisibleSeq('bob', group.id), 1);
    },
  );

  test(
    'unknown and disabled accounts cannot become owners or members',
    () async {
      expect(
        (await service.createGroup(
          ownerAccountId: 'unknown',
          name: 'group',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'group',
      )).value;
      await database.execute(
        'UPDATE test_accounts SET active = ? WHERE id = ?',
        [0, 'bob'],
      );
      for (final id in ['unknown', 'bob']) {
        expect(
          (await service.addMember(
            actorAccountId: 'alice',
            conversationId: group.id,
            memberAccountId: id,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(await service.canRead(id, group.id), isFalse);
      }
      expect(
        (await service.createGroup(
          ownerAccountId: 'alice',
          name: '  ',
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        (await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: "x' OR 1=1 --",
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    },
  );

  test(
    'social registers membership abstractions and does not expose unauthenticated routes',
    () async {
      final services = HostServices();
      final module = SocialModule(conversations: service);
      await module.configure(services);
      expect(services.get<MembershipCheck>(), same(service));
      expect(services.get<HistoryMembershipCheck>(), same(service));
      expect(
        await services.get<MembershipCheck>().canPost('bob', 'unknown'),
        isFalse,
      );
    },
  );
}
