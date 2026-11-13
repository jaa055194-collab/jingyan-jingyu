import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
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
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...socialMigrations,
      ],
    );
    await database.execute(
      'CREATE TABLE IF NOT EXISTS test_heads (id TEXT PRIMARY KEY, seq INTEGER NOT NULL)',
    );
    // Real canonical identities, including an unrelated administrator.
    for (final id in ['alice', 'bob', 'charlie', 'admin']) {
      await database.execute(
        'INSERT OR IGNORE INTO account (id, display_name, kind, is_admin, disabled, '
        'password_hash, failed_passwords, locked_until) '
        "VALUES (?, ?, 'human', ?, 0, 'unused-fixture', 0, 0)",
        [id, id, id == 'admin' ? 1 : 0],
      );
    }
    for (final pair in [
      ['alice_ai', 'alice'],
      ['bob_ai', 'bob'],
      ['unmapped_ai', null],
    ]) {
      await database.execute(
        'INSERT OR IGNORE INTO account (id, display_name, kind, is_admin, disabled, '
        'password_hash, failed_passwords, locked_until) '
        "VALUES (?, ?, 'ai', 0, 0, NULL, 0, 0)",
        [pair[0], pair[0]],
      );
      if (pair[1] != null) {
        await database.execute(
          'INSERT OR IGNORE INTO ai_operator (ai_id, operator_id) VALUES (?, ?)',
          pair,
        );
      }
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
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
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
      await database.execute('UPDATE account SET disabled = ? WHERE id = ?', [
        1,
        'bob',
      ]);
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
    'transfer keeps membership and gives the new owner add authority',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'transfer',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
        group.id,
        7,
      ]);
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      expect(
        (await service.transferOwnership(
          actorId: 'alice',
          conversationId: group.id,
          newOwnerId: 'bob',
        )).isOk,
        isTrue,
      );
      expect((await service.list('alice')).value.single.ownerAccountId, 'bob');
      expect(await service.firstVisibleSeq('bob', group.id), 8);
      expect(await service.firstVisibleSeq('alice', group.id), 1);
      expect(
        (await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: 'charlie',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service.addMember(
          actorAccountId: 'bob',
          conversationId: group.id,
          memberAccountId: 'charlie',
        )).isOk,
        isTrue,
      );
      await database.close();
      await open();
      expect((await service.list('bob')).value.single.ownerAccountId, 'bob');
      expect(
        (await service.leave(actorId: 'alice', conversationId: group.id)).isOk,
        isTrue,
      );
      expect(await service.canRead('alice', group.id), isFalse);
      expect(await service.canPost('alice', group.id), isFalse);
      expect(await service.canPost('bob', group.id), isTrue);
    },
  );

  test(
    'only current owner can transfer to an existing active human member',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'transfer checks',
      )).value;
      for (final id in ['bob', 'alice_ai']) {
        await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: id,
        );
      }
      for (final actor in ['bob', 'charlie', 'admin', 'missing']) {
        expect(
          (await service.transferOwnership(
            actorId: actor,
            conversationId: group.id,
            newOwnerId: 'bob',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      for (final target in ['charlie', 'missing', 'alice_ai']) {
        expect(
          (await service.transferOwnership(
            actorId: 'alice',
            conversationId: group.id,
            newOwnerId: target,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
        'bob',
      ]);
      expect(
        (await service.transferOwnership(
          actorId: 'alice',
          conversationId: group.id,
          newOwnerId: 'bob',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await database.execute('UPDATE account SET disabled=0 WHERE id=?', [
        'bob',
      ]);
      await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
        'alice',
      ]);
      expect(
        (await service.transferOwnership(
          actorId: 'alice',
          conversationId: group.id,
          newOwnerId: 'bob',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await database.execute('UPDATE account SET disabled=0 WHERE id=?', [
        'alice',
      ]);
      await database.execute(
        'DELETE FROM social_members WHERE conversation_id=? AND account_id=?',
        [group.id, 'alice'],
      );
      expect(
        (await service.transferOwnership(
          actorId: 'alice',
          conversationId: group.id,
          newOwnerId: 'bob',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect((await service.list('bob')).value.single.ownerAccountId, 'alice');
    },
  );

  test('owner cannot leave or remove itself and orphan the group', () async {
    final group = (await service.createGroup(
      ownerAccountId: 'alice',
      name: 'no orphan',
    )).value;
    expect(
      (await service.leave(
        actorId: 'alice',
        conversationId: group.id,
      )).failureOrNull?.code,
      FailureCode.forbidden,
    );
    expect(
      (await service.removeMember(
        actorId: 'alice',
        conversationId: group.id,
        targetId: 'alice',
      )).failureOrNull?.code,
      FailureCode.forbidden,
    );
    expect(await service.canPost('alice', group.id), isTrue);
    expect((await service.list('alice')).value.single.ownerAccountId, 'alice');
  });

  test(
    'leave deletes membership, revokes access and resets joined rejoin boundary',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'leave rejoin',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
        group.id,
        7,
      ]);
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      expect(await service.firstVisibleSeq('bob', group.id), 8);
      expect(
        (await service.leave(actorId: 'bob', conversationId: group.id)).isOk,
        isTrue,
      );
      expect(await service.canRead('bob', group.id), isFalse);
      expect(await service.canPost('bob', group.id), isFalse);
      expect(await service.firstVisibleSeq('bob', group.id), isNull);
      expect((await service.list('bob')).value, isEmpty);
      expect(
        await database.query(
          'SELECT * FROM social_members WHERE conversation_id=? AND account_id=?',
          [group.id, 'bob'],
        ),
        isEmpty,
      );
      expect(
        (await service.leave(
          actorId: 'bob',
          conversationId: group.id,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await database.execute('UPDATE test_heads SET seq=12 WHERE id=?', [
        group.id,
      ]);
      clock.advance(const Duration(seconds: 1));
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      expect(await service.firstVisibleSeq('bob', group.id), 13);
      expect(
        (await database.query(
          'SELECT joined_at FROM social_members WHERE conversation_id=? AND account_id=?',
          [group.id, 'bob'],
        )).single['joined_at'],
        clock.now().millisecondsSinceEpoch,
      );
      await database.close();
      await open();
      expect(await service.firstVisibleSeq('bob', group.id), 13);
    },
  );

  test(
    'owner removes human or AI and removal resets joined rejoin boundary',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'remove rejoin',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
        group.id,
        7,
      ]);
      for (final target in ['bob', 'bob_ai']) {
        await service.addMember(
          actorAccountId: 'alice',
          conversationId: group.id,
          memberAccountId: target,
        );
        expect(
          (await service.removeMember(
            actorId: 'alice',
            conversationId: group.id,
            targetId: target,
          )).isOk,
          isTrue,
        );
        expect(await service.canRead(target, group.id), isFalse);
        expect(await service.canPost(target, group.id), isFalse);
        expect(await service.firstVisibleSeq(target, group.id), isNull);
      }
      await database.execute('UPDATE test_heads SET seq=12 WHERE id=?', [
        group.id,
      ]);
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      expect(await service.firstVisibleSeq('bob', group.id), 13);
      // Disabled targets still count as members that the owner may remove.
      await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
        'bob',
      ]);
      expect(
        (await service.removeMember(
          actorId: 'alice',
          conversationId: group.id,
          targetId: 'bob',
        )).isOk,
        isTrue,
      );
      expect(
        await database.query(
          'SELECT * FROM social_members WHERE conversation_id=? AND account_id=?',
          [group.id, 'bob'],
        ),
        isEmpty,
      );
    },
  );

  test(
    'nonowners and admins cannot remove and inactive actors cannot exit',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'alice',
        name: 'denials',
      )).value;
      await service.addMember(
        actorAccountId: 'alice',
        conversationId: group.id,
        memberAccountId: 'bob',
      );
      for (final actor in ['bob', 'charlie', 'admin', 'missing']) {
        expect(
          (await service.removeMember(
            actorId: actor,
            conversationId: group.id,
            targetId: 'bob',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      for (final actor in ['charlie', 'admin', 'missing']) {
        expect(
          (await service.leave(
            actorId: actor,
            conversationId: group.id,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
      }
      expect(
        (await service.removeMember(
          actorId: 'alice',
          conversationId: group.id,
          targetId: 'charlie',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      for (final actor in ['alice', 'bob']) {
        await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
          actor,
        ]);
        expect(
          (await service.leave(
            actorId: actor,
            conversationId: group.id,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await service.removeMember(
            actorId: actor,
            conversationId: group.id,
            targetId: 'bob',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        await database.execute('UPDATE account SET disabled=0 WHERE id=?', [
          actor,
        ]);
      }
      expect(await service.canPost('bob', group.id), isTrue);
    },
  );

  test('operator outside group withdraws only its own canonical AI', () async {
    final group = (await service.createGroup(
      ownerAccountId: 'charlie',
      name: 'AI exit',
      historyVisibility: HistoryVisibility.joined,
    )).value;
    for (final target in ['alice_ai', 'bob_ai', 'bob']) {
      await service.addMember(
        actorAccountId: 'charlie',
        conversationId: group.id,
        memberAccountId: target,
      );
    }
    expect(await service.canRead('alice', group.id), isFalse);
    for (final operator in ['bob', 'admin', 'charlie', 'missing', 'alice_ai']) {
      expect(
        (await service.withdrawAi(
          operatorId: operator,
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    }
    // A malformed canonical mapping cannot turn a human into an AI.
    await database.execute('INSERT INTO ai_operator VALUES (?, ?)', [
      'bob',
      'alice',
    ]);
    for (final target in ['bob', 'bob_ai', 'missing', 'unmapped_ai']) {
      expect(
        (await service.withdrawAi(
          operatorId: 'alice',
          conversationId: group.id,
          aiAccountId: target,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    }
    expect(
      (await service.withdrawAi(
        operatorId: 'alice',
        conversationId: group.id,
        aiAccountId: 'alice_ai',
      )).isOk,
      isTrue,
    );
    expect(await service.canRead('alice_ai', group.id), isFalse);
    expect(await service.canPost('alice_ai', group.id), isFalse);
    expect(await service.firstVisibleSeq('alice_ai', group.id), isNull);
    expect(await service.canPost('bob_ai', group.id), isTrue);
    expect(
      (await service.withdrawAi(
        operatorId: 'alice',
        conversationId: group.id,
        aiAccountId: 'alice_ai',
      )).failureOrNull?.code,
      FailureCode.notFound,
    );
    await database.execute('INSERT INTO test_heads VALUES (?, ?)', [
      group.id,
      12,
    ]);
    await service.addMember(
      actorAccountId: 'charlie',
      conversationId: group.id,
      memberAccountId: 'alice_ai',
    );
    expect(await service.firstVisibleSeq('alice_ai', group.id), 13);
  });

  test(
    'withdraw checks current mapping and active AI and human operator',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'charlie',
        name: 'current mapping',
      )).value;
      await service.addMember(
        actorAccountId: 'charlie',
        conversationId: group.id,
        memberAccountId: 'alice_ai',
      );
      for (final account in ['alice', 'alice_ai']) {
        await database.execute('UPDATE account SET disabled=1 WHERE id=?', [
          account,
        ]);
        expect(
          (await service.withdrawAi(
            operatorId: 'alice',
            conversationId: group.id,
            aiAccountId: 'alice_ai',
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        await database.execute('UPDATE account SET disabled=0 WHERE id=?', [
          account,
        ]);
      }
      await database.execute('DELETE FROM ai_operator WHERE ai_id=?', [
        'alice_ai',
      ]);
      expect(
        (await service.withdrawAi(
          operatorId: 'alice',
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await database.execute('INSERT INTO ai_operator VALUES (?, ?)', [
        'alice_ai',
        'bob_ai',
      ]);
      expect(
        (await service.withdrawAi(
          operatorId: 'bob_ai',
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      await database.execute(
        'UPDATE ai_operator SET operator_id=? WHERE ai_id=?',
        ['bob', 'alice_ai'],
      );
      expect(
        (await service.withdrawAi(
          operatorId: 'alice',
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service.withdrawAi(
          operatorId: 'bob',
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        )).isOk,
        isTrue,
      );
    },
  );

  test('AI owner cannot be withdrawn and leave the group orphaned', () async {
    // Existing creation semantics allow AI owners; exit must still preserve owner.
    final group = (await service.createGroup(
      ownerAccountId: 'alice_ai',
      name: 'legacy AI owner',
    )).value;
    expect(
      (await service.withdrawAi(
        operatorId: 'alice',
        conversationId: group.id,
        aiAccountId: 'alice_ai',
      )).failureOrNull?.code,
      FailureCode.forbidden,
    );
    expect(await service.canPost('alice_ai', group.id), isTrue);
  });

  test(
    'new mutation APIs validate IDs and hide missing conversations',
    () async {
      for (final conversation in ['missing', "x' OR 1=1 --"]) {
        final expected = conversation == 'missing'
            ? FailureCode.notFound
            : FailureCode.invalidArgument;
        final results = [
          await service.transferOwnership(
            actorId: 'alice',
            conversationId: conversation,
            newOwnerId: 'bob',
          ),
          await service.leave(actorId: 'alice', conversationId: conversation),
          await service.removeMember(
            actorId: 'alice',
            conversationId: conversation,
            targetId: 'bob',
          ),
          await service.withdrawAi(
            operatorId: 'alice',
            conversationId: conversation,
            aiAccountId: 'alice_ai',
          ),
        ];
        expect(
          results.map((r) => r.failureOrNull?.code),
          everyElement(expected),
        );
      }
      final results = [
        await service.transferOwnership(
          actorId: '',
          conversationId: 'group',
          newOwnerId: 'bob',
        ),
        await service.transferOwnership(
          actorId: 'alice',
          conversationId: 'group',
          newOwnerId: '',
        ),
        await service.leave(actorId: '', conversationId: 'group'),
        await service.removeMember(
          actorId: '',
          conversationId: 'group',
          targetId: 'bob',
        ),
        await service.removeMember(
          actorId: 'alice',
          conversationId: 'group',
          targetId: '',
        ),
        await service.withdrawAi(
          operatorId: '',
          conversationId: 'group',
          aiAccountId: 'alice_ai',
        ),
        await service.withdrawAi(
          operatorId: 'alice',
          conversationId: 'group',
          aiAccountId: '',
        ),
      ];
      expect(
        results.map((r) => r.failureOrNull?.code),
        everyElement(FailureCode.invalidArgument),
      );
    },
  );

  test(
    'SQLite failure rolls back transfer and every membership exit',
    () async {
      final group = (await service.createGroup(
        ownerAccountId: 'charlie',
        name: 'rollback',
      )).value;
      for (final target in ['bob', 'alice_ai']) {
        await service.addMember(
          actorAccountId: 'charlie',
          conversationId: group.id,
          memberAccountId: target,
        );
      }
      await database.execute('''
CREATE TRIGGER fail_transfer AFTER UPDATE OF owner_account_id ON social_conversations
BEGIN
  INSERT INTO test_heads VALUES (NEW.id, 99);
  SELECT RAISE(FAIL, 'injected transfer failure');
END
''');
      await expectLater(
        service.transferOwnership(
          actorId: 'charlie',
          conversationId: group.id,
          newOwnerId: 'bob',
        ),
        throwsA(isA<Exception>()),
      );
      expect(
        (await service.list('charlie')).value.single.ownerAccountId,
        'charlie',
      );
      expect(await database.query('SELECT * FROM test_heads'), isEmpty);
      await database.execute('''
CREATE TRIGGER fail_exit AFTER DELETE ON social_members
BEGIN
  INSERT INTO test_heads VALUES (OLD.conversation_id, 99);
  SELECT RAISE(FAIL, 'injected exit failure');
END
''');
      for (final operation in <Future<Result<void>> Function()>[
        () => service.leave(actorId: 'bob', conversationId: group.id),
        () => service.removeMember(
          actorId: 'charlie',
          conversationId: group.id,
          targetId: 'bob',
        ),
        () => service.withdrawAi(
          operatorId: 'alice',
          conversationId: group.id,
          aiAccountId: 'alice_ai',
        ),
      ]) {
        await expectLater(operation(), throwsA(isA<Exception>()));
        expect(await service.canPost('bob', group.id), isTrue);
        expect(await service.canPost('alice_ai', group.id), isTrue);
        expect(await database.query('SELECT * FROM test_heads'), isEmpty);
      }
      expect(await database.integrityCheck(), 'ok');
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
