import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/scheduled.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/database.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _ScheduledReadGate implements Database {
  _ScheduledReadGate(this.inner);

  final Database inner;
  final observed = Completer<List<Map<String, Object?>>>();
  final release = Completer<void>();
  bool _armed = false;

  void arm() => _armed = true;

  @override
  Future<T> transaction<T>(Future<T> Function(Tx tx) body) =>
      inner.transaction(body);

  @override
  Future<int> execute(String sql, [List<Object?> args = const []]) =>
      inner.execute(sql, args);

  @override
  Future<int> schemaVersion() => inner.schemaVersion();

  @override
  Future<String> integrityCheck() => inner.integrityCheck();

  @override
  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> args = const [],
  ]) async {
    final rows = await inner.query(sql, args);
    if (_armed &&
        sql.contains('FROM scheduled_messages') &&
        sql.contains('pending')) {
      _armed = false;
      observed.complete(rows);
      await release.future;
    }
    return rows;
  }
}

class _FastHasher extends PasswordHasher {
  @override
  Future<String> hashAsync(String value) async => 'test:$value';

  @override
  Future<bool> verifyAsync(String value, String encodedHash) async =>
      encodedHash == 'test:$value';
}

void main() {
  late Directory directory;
  late SqliteDatabase db;
  late AesGcmColumnCipher cipher;
  late AccountsDomain accounts;
  late SqliteMessageStore messages;
  late ScheduledMessageService scheduled;
  late ConversationService conversations;
  late CombinedMembership membership;
  late Pipeline pipeline;
  late FakeClock clock;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  late Map<String, String> refreshTokens;
  const password = 'ack-boundary-test-password';

  Future<HostResponse> postSchedule(
    String conversationId,
    String? bearer,
    Object? body,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.scheduledMessages.replaceFirst(
        '{conversationId}',
        conversationId,
      ),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
      body: body,
    ),
  );

  Future<HostResponse> deleteScheduled(
    String conversationId,
    String scheduledId,
    String? bearer,
  ) => pipeline.handle(
    HostRequest(
      method: 'DELETE',
      path: Routes.scheduledMessage
          .replaceFirst('{conversationId}', conversationId)
          .replaceFirst('{scheduledId}', scheduledId),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
    ),
  );

  Future<HostResponse> readScheduled(
    String conversationId,
    String bearer,
    Map<String, String> query,
  ) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.scheduledMessages.replaceFirst(
        '{conversationId}',
        conversationId,
      ),
      query: query,
      headers: {'authorization': 'Bearer $bearer'},
    ),
  );

  Future<List<Map<String, Object?>>> syncMessages(
    String conversationId,
    String bearer,
  ) async {
    final response = await pipeline.handle(
      HostRequest(
        method: 'GET',
        path: Routes.sync.replaceFirst('{conversationId}', conversationId),
        query: const {'afterSeq': '0'},
        headers: {'authorization': 'Bearer $bearer'},
      ),
    );
    expect(response.status, 200);
    return [
      for (final message in (response.json! as Map)['messages'] as List)
        (message as Map).cast<String, Object?>(),
    ];
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-scheduled-');
    db = await SqliteDatabase.open(
      '${directory.path}/host.sqlite',
      migrations: [
        ...allMigrations,
        ...accountsMigrations,
        ...messagesMigrations,
        ...socialMigrations,
        friendshipMigration,
        privateConversationMigration,
      ],
    );
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    refreshTokens = {};
    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final adminLogin = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin device',
    )).value;
    final admin = (await accounts.scope(adminLogin.accessToken)).value;
    ids['member'] = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).value;
    ids['other'] = (await admin.accounts.createHuman(
      displayName: 'Other',
      password: password,
    )).value;
    for (final name in ['member', 'other']) {
      final login = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name device',
      )).value;
      tokens[name] = login.accessToken;
      refreshTokens[name] = login.refreshToken;
    }
    messages = SqliteMessageStore(database: db, cipher: cipher, clock: clock);
    conversations = ConversationService(
      database: db,
      clock: clock,
      headSeq: (tx, id) async {
        final rows = await tx.query(
          'SELECT seq FROM message_heads WHERE conversation_id = ?',
          [id],
        );
        return rows.isEmpty ? 0 : rows.single['seq'] as int;
      },
      accountExists: (tx, id) async => (await tx.query(
        'SELECT id FROM account WHERE id = ? AND disabled = 0',
        [id],
      )).isNotEmpty,
    );
    membership = CombinedMembership(
      db: db,
      group: conversations,
      direct: PrivateConversations(db: db, clock: clock),
      groupHistoryInTransaction: conversations.firstVisibleSeqInTransaction,
      groupPostingHistoryInTransaction:
          conversations.firstVisibleSeqInTransaction,
    );
    scheduled = ScheduledMessageService(
      database: db,
      cipher: cipher,
      store: messages,
      historyAccess: (tx, account, conversation, {required requirePost}) =>
          membership.firstVisibleSeqInTransaction(
            tx,
            account,
            conversation,
            requirePost: requirePost,
          ),
      clock: clock,
      newId: () => 'scheduled_${clock.now().microsecondsSinceEpoch}',
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'scheduled-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'scheduled-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      scheduled: scheduled,
      clock: clock,
    );
    await module.configure(services);
    module.mount(router);
    pipeline = Pipeline(
      router: router,
      authenticate: DbAuthenticator(accounts).call,
      onError: (error, stack, request) =>
          Error.throwWithStackTrace(error, stack),
    );
  });

  tearDown(() async {
    cipher.dispose();
    await db.close();
    await directory.delete(recursive: true);
  });

  Future<String> createGroup() async => (await conversations.createGroup(
    ownerAccountId: ids['member']!.value,
    name: 'Scheduled group',
  )).value.id;

  Future<HostResponse> scheduleText(
    String conversationId,
    String text,
    DateTime deliverAt,
  ) => postSchedule(conversationId, tokens['member'], {
    'kind': 'text',
    'body': {'text': text},
    'deliverAt': deliverAt.toUtc().toIso8601String(),
  });

  test(
    'sender-only scheduled status readback is bounded and never scans a missing conversation',
    () async {
      final group = await createGroup();
      final other = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Other owner group',
      )).value.id;
      final created = await scheduleText(
        group,
        'private scheduled body',
        clock.now().add(const Duration(hours: 1)),
      );
      final id = (created.json! as Map)['id'] as String;
      final ownList = await readScheduled(group, tokens['member']!, const {});
      expect(ownList.status, 200);
      expect(ownList.json, {
        'scheduledMessages': [
          {
            'id': id,
            'conversationId': group,
            'deliverAt': (created.json! as Map)['deliverAt'],
            'status': 'pending',
          },
        ],
        'hasMore': false,
      });
      final ownStatus = await readScheduled(group, tokens['member']!, {
        'scheduledId': id,
      });
      expect(ownStatus.json, {
        'scheduledMessages': [
          {
            'id': id,
            'conversationId': group,
            'deliverAt': (created.json! as Map)['deliverAt'],
            'status': 'pending',
          },
        ],
        'hasMore': false,
      });
      final noOwnRows = await readScheduled(other, tokens['member']!, const {});
      expect(noOwnRows.status, 200);
      expect((noOwnRows.json! as Map)['scheduledMessages'], isEmpty);
      final absent = await readScheduled(
        'syntactically-valid-absent-conversation',
        tokens['member']!,
        const {},
      );
      expect(absent.status, 200);
      expect((absent.json! as Map)['scheduledMessages'], isEmpty);
      final otherList = await readScheduled(group, tokens['other']!, const {});
      expect(otherList.status, 200);
      expect((otherList.json! as Map)['scheduledMessages'], isEmpty);
      expect(
        (await readScheduled(group, tokens['other']!, {
          'scheduledId': id,
        })).status,
        404,
      );
      expect(
        (await readScheduled(group, tokens['member']!, {'other': 'x'})).status,
        400,
      );
      expect(
        (await readScheduled(group, tokens['member']!, {
          'scheduledId': 'missing',
        })).status,
        404,
      );
    },
  );

  test('a due scheduled message is delivered exactly once', () async {
    final group = await createGroup();
    final created = await scheduleText(
      group,
      '定时内容',
      clock.now().add(const Duration(hours: 1)),
    );
    expect(created.status, 200);
    final id = (created.json! as Map)['id'] as String;
    expect(await syncMessages(group, tokens['member']!), isEmpty);

    clock.advance(const Duration(hours: 1, seconds: 1));
    expect(await scheduled.deliverDue(), 1);
    final refreshed = (await accounts.refresh(refreshTokens['member']!)).value;
    final delivered = await syncMessages(group, refreshed.accessToken);
    expect((delivered.single['body'] as Map)['text'], '定时内容');
    expect(
      (await db.query('SELECT status FROM scheduled_messages WHERE id = ?', [
        id,
      ])).single['status'],
      'delivered',
    );
    expect(await scheduled.deliverDue(), 0);
    expect(await syncMessages(group, refreshed.accessToken), hasLength(1));
  });

  test(
    'legacy non-text scheduled kinds remain accepted and delivered',
    () async {
      final group = await createGroup();
      final created = await postSchedule(group, tokens['member'], {
        'kind': 'card',
        'body': {'title': 'legacy card'},
        'deliverAt': clock
            .now()
            .add(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      });
      expect(created.status, 200);
      clock.advance(const Duration(minutes: 1));
      expect(await scheduled.deliverDue(), 1);
      final delivered = await syncMessages(group, tokens['member']!);
      expect(delivered.single['kind'], 'card');
      expect(delivered.single['body'], {'title': 'legacy card'});
    },
  );

  test('cancelling a pending scheduled message prevents delivery', () async {
    final group = await createGroup();
    final created = await scheduleText(
      group,
      '将取消',
      clock.now().add(const Duration(minutes: 10)),
    );
    final id = (created.json! as Map)['id'] as String;
    final cancelled = await deleteScheduled(group, id, tokens['member']);
    expect(cancelled.status, 200);
    clock.advance(const Duration(hours: 1));
    expect(await scheduled.deliverDue(), 0);
    final refreshed = (await accounts.refresh(refreshTokens['member']!)).value;
    expect(await syncMessages(group, refreshed.accessToken), isEmpty);
  });

  test(
    'past, malformed, anonymous, nonmember and non-sender requests are rejected',
    () async {
      final group = await createGroup();
      expect(
        (await scheduleText(
          group,
          '过去',
          clock.now().subtract(const Duration(minutes: 1)),
        )).status,
        400,
      );
      for (final body in [
        null,
        [],
        {},
        {
          'kind': 'nope',
          'body': {'text': 'x'},
          'deliverAt': '2030-01-01T00:00:00Z',
        },
        {'kind': 'text', 'body': 'x', 'deliverAt': '2030-01-01T00:00:00Z'},
        {
          'kind': 'text',
          'body': {'text': 'x'},
          'deliverAt': 'not-a-date',
        },
      ]) {
        expect(
          (await postSchedule(group, tokens['member'], body)).status,
          400,
          reason: '$body',
        );
      }
      expect((await postSchedule(group, null, {})).status, 401);
      final foreign = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Foreign',
      )).value.id;
      expect(
        (await scheduleText(
          foreign,
          'x',
          clock.now().add(const Duration(hours: 1)),
        )).status,
        404,
      );

      await conversations.addMember(
        actorAccountId: ids['member']!.value,
        conversationId: group,
        memberAccountId: ids['other']!.value,
      );
      final created = await scheduleText(
        group,
        '别人的',
        clock.now().add(const Duration(hours: 1)),
      );
      final id = (created.json! as Map)['id'] as String;
      expect((await deleteScheduled(group, id, tokens['other'])).status, 403);
    },
  );

  test(
    'removed sender is terminally withheld and rejoin does not revive the due job',
    () async {
      final group = await createGroup();
      await conversations.addMember(
        actorAccountId: ids['member']!.value,
        conversationId: group,
        memberAccountId: ids['other']!.value,
      );
      final created = await postSchedule(group, tokens['other'], {
        'kind': 'text',
        'body': {'text': 'withheld after removal'},
        'deliverAt': clock
            .now()
            .add(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      });
      final id = (created.json! as Map)['id'] as String;
      await conversations.removeMember(
        actorId: ids['member']!.value,
        conversationId: group,
        targetId: ids['other']!.value,
      );
      clock.advance(const Duration(minutes: 1));

      expect(await scheduled.deliverDue(), 0);
      expect(await syncMessages(group, tokens['member']!), isEmpty);
      expect(
        (await db.query('SELECT status FROM scheduled_messages WHERE id=?', [
          id,
        ])).single['status'],
        'cancelled',
      );
      final status = await readScheduled(group, tokens['other']!, {
        'scheduledId': id,
      });
      expect(status.status, 200);
      expect(
        ((status.json! as Map)['scheduledMessages']! as List).single['status'],
        'cancelled',
      );

      await conversations.addMember(
        actorAccountId: ids['member']!.value,
        conversationId: group,
        memberAccountId: ids['other']!.value,
      );
      expect(await scheduled.deliverDue(), 0);
      expect(await syncMessages(group, tokens['member']!), isEmpty);
      final readback = await readScheduled(group, tokens['other']!, const {});
      expect(readback.status, 200);
      expect((readback.json! as Map)['scheduledMessages'], hasLength(1));
    },
  );

  test(
    'cancel committed after a due-row scan prevents stale-snapshot delivery',
    () async {
      final group = await createGroup();
      final created = await scheduleText(
        group,
        'cancel race',
        clock.now().add(const Duration(seconds: 1)),
      );
      final id = (created.json! as Map)['id'] as String;
      clock.advance(const Duration(seconds: 1));

      final gate = _ScheduledReadGate(db);
      scheduled = ScheduledMessageService(
        database: gate,
        cipher: cipher,
        store: messages,
        historyAccess: (tx, account, conversation, {required requirePost}) =>
            membership.firstVisibleSeqInTransaction(
              tx,
              account,
              conversation,
              requirePost: requirePost,
            ),
        clock: clock,
      );
      gate.arm();
      final dispatch = scheduled.deliverDue();
      int? dispatchResult;
      try {
        final candidates = await gate.observed.future;
        expect(candidates.map((row) => row['id']), contains(id));

        final cancel = await deleteScheduled(group, id, tokens['member']);
        expect(cancel.status, 200);
      } finally {
        if (!gate.release.isCompleted) gate.release.complete();
      }
      dispatchResult = await dispatch;
      expect(dispatchResult, 0);
      expect(await syncMessages(group, tokens['member']!), isEmpty);
      expect(
        (await db.query('SELECT status FROM scheduled_messages WHERE id=?', [
          id,
        ])).single['status'],
        'cancelled',
      );
    },
  );

  test(
    'messages missed by more than 24h are marked expired, not delivered',
    () async {
      final group = await createGroup();
      final created = await scheduleText(
        group,
        '太晚了',
        clock.now().add(const Duration(hours: 1)),
      );
      final id = (created.json! as Map)['id'] as String;
      clock.advance(const Duration(hours: 26));
      expect(await scheduled.deliverDue(), 0);
      expect(
        (await db.query('SELECT status FROM scheduled_messages WHERE id = ?', [
          id,
        ])).single['status'],
        'expired',
      );
      final refreshed = (await accounts.refresh(
        refreshTokens['member']!,
      )).value;
      expect(await syncMessages(group, refreshed.accessToken), isEmpty);
    },
  );

  test(
    'sub-second deliverAt is not delivered early (no ISO text ordering)',
    () async {
      final group = await createGroup();
      final base = clock.now();
      final deliverAt = base.add(
        const Duration(milliseconds: 500, microseconds: 123),
      );
      final created = await scheduleText(group, '亚秒', deliverAt);
      expect(created.status, 200);

      expect(await scheduled.deliverDue(now: base), 0);
      expect(
        await scheduled.deliverDue(
          now: base.add(const Duration(milliseconds: 600)),
        ),
        1,
      );
    },
  );
}
