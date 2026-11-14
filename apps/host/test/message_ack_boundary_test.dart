import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/db_authenticator.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
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
  late ConversationService conversations;
  late CombinedMembership membership;
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  late Map<String, String> refreshTokens;
  late Map<String, DeviceId> devices;
  late FakeClock clock;
  var messageSerial = 0;
  const password = 'ack-boundary-test-password';

  Future<SqliteDatabase> openDatabase() => SqliteDatabase.open(
    '${directory.path}/host.sqlite',
    migrations: [
      ...allMigrations,
      ...accountsMigrations,
      ...messagesMigrations,
      ...socialMigrations,
      privateConversationMigration,
    ],
  );

  String path(String conversationId) =>
      Routes.messageAck.replaceFirst('{conversationId}', conversationId);

  Future<HostResponse> ack(
    String conversationId,
    String? bearer,
    Object? body, {
    Pipeline? through,
    String? authorization,
  }) => (through ?? pipeline).handle(
    HostRequest(
      method: 'POST',
      path: path(conversationId),
      headers: {
        'authorization': ?authorization,
        if (authorization == null && bearer != null)
          'authorization': 'Bearer $bearer',
      },
      body: body,
    ),
  );

  Future<List<Map<String, Object?>>> ackRows() async => (await db.query(
    'SELECT conversation_id, device_id, seq FROM message_acks '
    'ORDER BY conversation_id, device_id',
  )).map(Map<String, Object?>.from).toList();

  Future<HostResponse> sendMessage(
    String conversationId,
    String bearer,
    String clientMsgId,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'authorization': 'Bearer $bearer'},
      body: {
        'clientMsgId': clientMsgId,
        'kind': 'text',
        'body': {'text': clientMsgId},
      },
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('message-ack-boundary-');
    db = await openDatabase();
    cipher = AesGcmColumnCipher(List<int>.generate(32, (i) => i));
    clock = FakeClock(DateTime.utc(2026, 11, 14));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
    refreshTokens = {};
    devices = {};

    ids['admin'] = (await accounts.bootstrapAdmin(
      displayName: 'Admin',
      password: password,
    )).value;
    final adminTokens = (await accounts.login(
      ids['admin']!,
      password,
      deviceName: 'admin device',
    )).value;
    tokens['admin'] = adminTokens.accessToken;
    refreshTokens['admin'] = adminTokens.refreshToken;
    devices['admin'] = adminTokens.deviceId;
    final admin = (await accounts.scope(tokens['admin']!)).value;
    ids['member'] = (await admin.accounts.createHuman(
      displayName: 'Member',
      password: password,
    )).value;
    ids['other'] = (await admin.accounts.createHuman(
      displayName: 'Other',
      password: password,
    )).value;
    for (final name in ['member', 'other']) {
      final session = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name first device',
      )).value;
      tokens[name] = session.accessToken;
      refreshTokens[name] = session.refreshToken;
      devices[name] = session.deviceId;
    }
    final second = (await accounts.login(
      ids['member']!,
      password,
      deviceName: 'member second device',
    )).value;
    tokens['member2'] = second.accessToken;
    refreshTokens['member2'] = second.refreshToken;
    devices['member2'] = second.deviceId;

    messages = SqliteMessageStore(
      database: db,
      cipher: cipher,
      clock: clock,
      newId: () => 'message-${++messageSerial}',
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
    final direct = PrivateConversations(db: db, clock: clock);
    membership = CombinedMembership(
      db: db,
      group: conversations,
      direct: direct,
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'boundary-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'boundary-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
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

  test(
    'revoked and rotated bearers plus cached principal mismatches are defense-in-depth (not a remote exploit)',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'ACK boundary',
      )).value;
      await sendMessage(group.id, tokens['member']!, 'seed');
      expect((await ack(group.id, tokens['member'], {'seq': 1})).status, 200);
      final beforeRotation = await ackRows();

      final oldBearer = tokens['member2']!;
      final refreshed = (await accounts.refresh(
        refreshTokens['member2']!,
      )).value;
      expect((await ack(group.id, oldBearer, {'seq': 1})).status, 401);
      expect(await ackRows(), beforeRotation);

      final currentBearer = refreshed.accessToken;
      expect((await ack(group.id, currentBearer, {'seq': 1})).status, 200);
      final beforeRevoke = await ackRows();
      final current = (await accounts.authenticate(currentBearer))!;
      final scope = (await accounts.scope(currentBearer)).value;
      expect(
        (await scope.devices.revoke(
          ids['member']!,
          DeviceId.parse(current.deviceId),
        )).isOk,
        isTrue,
      );
      expect((await ack(group.id, currentBearer, {'seq': 1})).status, 401);
      expect(await ackRows(), beforeRevoke);

      final real = (await accounts.authenticate(tokens['member']!))!;
      for (final forged in [
        Principal(accountId: ids['other']!.value, deviceId: real.deviceId),
        Principal(accountId: real.accountId, deviceId: devices['other']!.value),
      ]) {
        final trustedCache = Pipeline(
          router: pipeline.router,
          authenticate: (_) async => forged,
        );
        expect(
          (await ack(group.id, tokens['member'], {
            'seq': 1,
          }, through: trustedCache)).status,
          401,
        );
        expect(await ackRows(), beforeRevoke);
      }
    },
  );

  test(
    'missing policies and malformed or extra-field requests fail closed without ACK rows',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Policy boundary',
      )).value;
      await sendMessage(group.id, tokens['member']!, 'seed');
      final before = await ackRows();

      final noPolicyRouter = Router();
      final noPolicy = MessagesModule(
        store: messages,
        authenticate: DbAuthenticator(accounts).call,
      );
      await noPolicy.configure(HostServices());
      noPolicy.mount(noPolicyRouter);
      final noPolicyPipeline = Pipeline(
        router: noPolicyRouter,
        authenticate: DbAuthenticator(accounts).call,
      );
      expect(
        (await ack(group.id, tokens['member'], {
          'seq': 1,
        }, through: noPolicyPipeline)).status,
        404,
      );
      expect(
        (await noPolicyPipeline.handle(
          HostRequest(
            method: 'POST',
            path: Routes.messages.replaceFirst('{conversationId}', group.id),
            headers: {'authorization': 'Bearer ${tokens['member']}'},
            body: {
              'clientMsgId': 'denied',
              'kind': 'text',
              'body': {'text': 'denied'},
            },
          ),
        )).status,
        404,
      );
      expect(await ackRows(), before);

      final membershipOnlyRouter = Router();
      final membershipOnly = MessagesModule(
        store: messages,
        authenticate: DbAuthenticator(accounts).call,
      );
      final membershipOnlyServices = HostServices()
        ..provide<MembershipCheck>(membership, owner: 'boundary-test');
      await membershipOnly.configure(membershipOnlyServices);
      membershipOnly.mount(membershipOnlyRouter);
      final membershipOnlyPipeline = Pipeline(
        router: membershipOnlyRouter,
        authenticate: DbAuthenticator(accounts).call,
      );
      expect(
        (await ack(group.id, tokens['member'], {
          'seq': 1,
        }, through: membershipOnlyPipeline)).status,
        404,
        reason: 'Missing history policy must fail closed',
      );
      expect(await ackRows(), before);

      for (final body in [
        null,
        [],
        '1',
        {},
        {'seq': '1'},
        {'seq': 1.5},
        {'seq': -1},
        {'seq': 1, 'deviceId': devices['member']!.value},
      ]) {
        expect(
          (await ack(group.id, tokens['member2'], body)).status,
          400,
          reason: '$body',
        );
        expect(await ackRows(), before, reason: '$body');
      }
    },
  );

  test(
    'nonmember, unknown, and ambiguous conversations cannot write acknowledgements',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Membership boundary',
      )).value;
      await sendMessage(group.id, tokens['member']!, 'seed');
      final before = await ackRows();

      expect((await ack(group.id, tokens['other'], {'seq': 1})).status, 404);
      expect(
        (await ack('unknown-conversation', tokens['member'], {
          'seq': 1,
        })).status,
        404,
      );

      const ambiguous = 'ambiguous-conversation';
      await db.execute(
        'INSERT INTO social_conversations '
        '(id, owner_account_id, name, history_visibility, created_at) '
        "VALUES (?, ?, 'ambiguous', 'all', ?)",
        [ambiguous, ids['member']!.value, clock.now().millisecondsSinceEpoch],
      );
      await db.execute(
        'INSERT INTO social_members '
        '(conversation_id, account_id, joined_at, first_visible_seq) VALUES (?, ?, ?, 1)',
        [ambiguous, ids['member']!.value, clock.now().millisecondsSinceEpoch],
      );
      final sorted = [ids['member']!.value, ids['other']!.value]..sort();
      await db.execute(
        'INSERT INTO direct_conversations '
        '(id, account_low, account_high, created_at) VALUES (?, ?, ?, ?)',
        [ambiguous, sorted[0], sorted[1], clock.now().millisecondsSinceEpoch],
      );
      expect((await ack(ambiguous, tokens['member'], {'seq': 1})).status, 404);
      expect(await ackRows(), before);
    },
  );

  test(
    'two devices stay independently monotonic, clamp to head, and persist across reopen',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Monotonic boundary',
      )).value;
      await sendMessage(group.id, tokens['member']!, 'one');
      await sendMessage(group.id, tokens['member']!, 'two');

      expect((await ack(group.id, tokens['member'], {'seq': 2})).json, {
        'acknowledgedSeq': 2,
      });
      expect((await ack(group.id, tokens['member'], {'seq': 1})).json, {
        'acknowledgedSeq': 2,
      });
      expect((await ack(group.id, tokens['member2'], {'seq': 1})).json, {
        'acknowledgedSeq': 1,
      });
      expect((await ack(group.id, tokens['member2'], {'seq': 999})).json, {
        'acknowledgedSeq': 2,
      });
      expect(
        await db.query(
          'SELECT device_id, seq FROM message_acks WHERE conversation_id = ? '
          'ORDER BY device_id',
          [group.id],
        ),
        [
          {'device_id': devices['member']!.value, 'seq': 2},
          {'device_id': devices['member2']!.value, 'seq': 2},
        ]..sort(
          (a, b) =>
              (a['device_id']! as String).compareTo(b['device_id']! as String),
        ),
      );

      await db.close();
      cipher.dispose();
      db = await openDatabase();
      final reopened = await db.query(
        'SELECT device_id, seq FROM message_acks WHERE conversation_id = ? '
        'ORDER BY device_id',
        [group.id],
      );
      expect(reopened, hasLength(2));
      expect(reopened.map((row) => row['seq']), [2, 2]);
    },
  );
}
