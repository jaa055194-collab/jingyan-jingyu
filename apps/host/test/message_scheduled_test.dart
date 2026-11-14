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
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

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
    scheduled = ScheduledMessageService(
      database: db,
      cipher: cipher,
      store: messages,
      clock: clock,
      newId: () => 'scheduled-${DateTime.now().microsecondsSinceEpoch}',
    );
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
    final membership = CombinedMembership(
      db: db,
      group: conversations,
      direct: PrivateConversations(db: db, clock: clock),
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
}
