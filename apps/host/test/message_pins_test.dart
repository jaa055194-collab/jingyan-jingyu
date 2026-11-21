import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/pins.dart';
import 'package:jingyu_host/src/messages/sqlite_message_store.dart';
import 'package:jingyu_host/src/social/combined_membership.dart';
import 'package:jingyu_host/src/social/conversation_service.dart';
import 'package:jingyu_host/src/social/friendship_migrations.dart';
import 'package:jingyu_host/src/social/friendship_service.dart';
import 'package:jingyu_host/src/social/private_conversation_migration.dart';
import 'package:jingyu_host/src/social/private_conversations.dart';
import 'package:jingyu_host/src/social/social_migrations.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_audit_log.dart';
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
  late Pipeline pipeline;
  late Map<String, AccountId> ids;
  late Map<String, String> tokens;
  const password = 'ack-boundary-test-password';

  String pinPath(String conversationId, String messageId) => Routes.messagePin
      .replaceFirst('{conversationId}', conversationId)
      .replaceFirst('{messageId}', messageId);
  String pinsPath(String conversationId) =>
      Routes.conversationPins.replaceFirst('{conversationId}', conversationId);

  Future<HostResponse> pin(
    String conversationId,
    String messageId,
    String? bearer, {
    String method = 'POST',
  }) => pipeline.handle(
    HostRequest(
      method: method,
      path: pinPath(conversationId, messageId),
      headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
    ),
  );

  Future<HostResponse> listPins(String conversationId, String bearer) =>
      pipeline.handle(
        HostRequest(
          method: 'GET',
          path: pinsPath(conversationId),
          headers: {'authorization': 'Bearer $bearer'},
        ),
      );

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
    directory = await Directory.systemTemp.createTemp('message-pins-');
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
    final clock = FakeClock(DateTime.utc(2026, 11, 14, 9));
    accounts = AccountsDomain(
      store: SqlAccountsStore(db),
      clock: clock,
      hasher: _FastHasher(),
    );
    ids = {};
    tokens = {};
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
      tokens[name] = (await accounts.login(
        ids[name]!,
        password,
        deviceName: '$name device',
      )).value.accessToken;
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
    final membership = CombinedMembership(
      db: db,
      group: conversations,
      direct: PrivateConversations(db: db, clock: clock),
      groupHistoryInTransaction: conversations.firstVisibleSeqInTransaction,
      groupPostingHistoryInTransaction:
          conversations.firstVisibleSeqInTransaction,
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'pins-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'pins-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      pins: PinsService(
        database: db,
        historyAccess: membership.firstVisibleSeqInTransaction,
        writeAudit: SqliteAuditLog.recordInTransaction,
        clock: clock,
        maxPins: 2,
      ),
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

  test('pinning is idempotent and unpinning removes it', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Pins group',
    )).value;
    final sent = await sendMessage(group.id, tokens['member']!, 'p1');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;

    final first = await pin(group.id, messageId, tokens['member']);
    expect(first.status, 200);
    expect(first.json, {'pinned': true, 'duplicate': false});
    final again = await pin(group.id, messageId, tokens['member']);
    expect(again.json, {'pinned': true, 'duplicate': true});

    final listed = await listPins(group.id, tokens['member']!);
    expect((listed.json! as Map)['pins'], hasLength(1));

    final removed = await pin(
      group.id,
      messageId,
      tokens['member'],
      method: 'DELETE',
    );
    expect(removed.status, 200);
    final empty = await listPins(group.id, tokens['member']!);
    expect((empty.json! as Map)['pins'], isEmpty);
    final alreadyRemoved = await pin(
      group.id,
      messageId,
      tokens['member'],
      method: 'DELETE',
    );
    expect(alreadyRemoved.status, 200);
    expect(alreadyRemoved.json, {'pinned': false});
    final audit = await db.query(
      'SELECT actor_id, action, target_kind, meta FROM audit_log WHERE target_id=? ORDER BY id',
      [messageId],
    );
    expect(audit, [
      {
        'actor_id': ids['member']!.value,
        'action': 'message.pin',
        'target_kind': 'message',
        'meta': '{"conversationId":"${group.id}"}',
      },
      {
        'actor_id': ids['member']!.value,
        'action': 'message.unpin',
        'target_kind': 'message',
        'meta': '{"conversationId":"${group.id}"}',
      },
    ]);
  });

  test('a failed audit cannot publish a pin without its record', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Pin audit',
    )).value;
    final sent = await sendMessage(
      group.id,
      tokens['member']!,
      'commit-with-audit',
    );
    final messageId = (sent.json as Map)['message']['messageId'] as String;
    await db.execute('''
CREATE TRIGGER reject_pin_audit BEFORE INSERT ON audit_log
WHEN NEW.action='message.pin' BEGIN SELECT RAISE(ABORT, 'fixture audit failure'); END
''');
    await expectLater(
      pin(group.id, messageId, tokens['member']),
      throwsA(isA<Exception>()),
    );
    final listed = await listPins(group.id, tokens['member']!);
    expect((listed.json as Map)['pins'], isEmpty);
  });

  test('a joined group lists only pins from readable history', () async {
    final owner = ids['member']!.value;
    final group = (await conversations.createGroup(
      ownerAccountId: owner,
      name: 'Joined pins',
      historyVisibility: HistoryVisibility.joined,
    )).value;
    Future<String> send(String clientId) async {
      final sent = await sendMessage(group.id, tokens['member']!, clientId);
      expect(sent.status, 200);
      return (sent.json as Map)['message']['messageId'] as String;
    }

    final older = await send('before-join');
    expect((await pin(group.id, older, tokens['member'])).status, 200);
    expect(
      (await conversations.addMember(
        actorAccountId: owner,
        conversationId: group.id,
        memberAccountId: ids['other']!.value,
      )).isOk,
      isTrue,
    );
    final visible = await send('after-join');
    expect((await pin(group.id, visible, tokens['other'])).status, 200);

    final listed = await listPins(group.id, tokens['other']!);
    expect(listed.status, 200);
    expect((listed.json as Map)['pins'], [containsPair('messageId', visible)]);
    expect(
      ((await listPins(group.id, tokens['member']!)).json as Map)['pins'],
      hasLength(2),
    );
  });

  test(
    'a late member cannot pin or remove a pin outside readable history',
    () async {
      final owner = ids['member']!.value;
      final group = (await conversations.createGroup(
        ownerAccountId: owner,
        name: 'Joined mutations',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      Future<String> send(String clientId) async {
        final sent = await sendMessage(group.id, tokens['member']!, clientId);
        expect(sent.status, 200);
        return (sent.json as Map)['message']['messageId'] as String;
      }

      final pinned = await send('older-pinned');
      final unpinned = await send('older-unpinned');
      expect((await pin(group.id, pinned, tokens['member'])).status, 200);
      expect(
        (await conversations.addMember(
          actorAccountId: owner,
          conversationId: group.id,
          memberAccountId: ids['other']!.value,
        )).isOk,
        isTrue,
      );

      final insert = await pin(group.id, unpinned, tokens['other']);
      final delete = await pin(
        group.id,
        pinned,
        tokens['other'],
        method: 'DELETE',
      );
      final missing = await pin(
        group.id,
        'nonexistent-message',
        tokens['other'],
      );
      expect([insert.status, delete.status, missing.status], [404, 404, 404]);
      expect(insert.json, missing.json);
      expect(delete.json, missing.json);
      expect(
        ((await listPins(group.id, tokens['member']!)).json as Map)['pins'],
        [containsPair('messageId', pinned)],
      );
    },
  );

  test(
    'a recalled message no longer appears in pins or accepts a pin',
    () async {
      final owner = ids['member']!.value;
      final group = (await conversations.createGroup(
        ownerAccountId: owner,
        name: 'Recalled pins',
      )).value;
      final sent = await sendMessage(group.id, tokens['member']!, 'to-recall');
      final recalled = (sent.json as Map)['message']['messageId'] as String;
      expect((await pin(group.id, recalled, tokens['member'])).status, 200);
      expect(
        (await messages.recall(
          conversationId: group.id,
          messageId: recalled,
          senderId: owner,
        )).isOk,
        isTrue,
      );

      expect(
        ((await listPins(group.id, tokens['member']!)).json as Map)['pins'],
        isEmpty,
      );
      expect((await pin(group.id, recalled, tokens['member'])).status, 404);
    },
  );

  test('stale pins do not consume an active slot', () async {
    final owner = ids['member']!.value;
    final group = (await conversations.createGroup(
      ownerAccountId: owner,
      name: 'Pin cap',
    )).value;
    final idsToPin = <String>[];
    for (var i = 0; i < 3; i++) {
      final sent = await sendMessage(group.id, tokens['member']!, 'limit-$i');
      expect(sent.status, 200);
      idsToPin.add((sent.json as Map)['message']['messageId'] as String);
    }
    final [first, second, third] = idsToPin;
    expect((await pin(group.id, first, tokens['member'])).status, 200);
    expect((await pin(group.id, second, tokens['member'])).status, 200);
    expect((await pin(group.id, third, tokens['member'])).status, 400);
    expect(
      (await messages.recall(
        conversationId: group.id,
        messageId: first,
        senderId: owner,
      )).isOk,
      isTrue,
    );
    expect((await pin(group.id, third, tokens['member'])).status, 200);
    expect(
      ((await listPins(group.id, tokens['member']!)).json as Map)['pins'],
      [containsPair('messageId', second), containsPair('messageId', third)],
    );
    final stored = await db.query(
      'SELECT message_id FROM message_pins WHERE conversation_id=? ORDER BY rowid',
      [group.id],
    );
    expect(stored.map((row) => row['message_id']), [second, third]);
  });

  test(
    'blocked direct participants can read pins but cannot mutate them',
    () async {
      final alice = ids['member']!;
      final bob = ids['other']!;
      FriendshipService friend(AccountId account) => FriendshipService(
        actorId: account,
        database: db,
        clock: FakeClock(DateTime.utc(2026, 11, 14, 9)),
      );
      expect((await friend(alice).request(bob)).isOk, isTrue);
      expect((await friend(bob).accept(alice)).isOk, isTrue);
      final direct = PrivateConversations(db: db, clock: const SystemClock());
      final pair = (await direct.open(
        actorId: alice.value,
        targetId: bob.value,
      )).value;
      final sent = await sendMessage(pair.id, tokens['member']!, 'initial-pin');
      expect(sent.status, 200);
      final existing = (sent.json as Map)['message']['messageId'] as String;
      expect((await pin(pair.id, existing, tokens['other'])).status, 200);
      expect((await friend(alice).block(bob)).isOk, isTrue);

      for (final token in [tokens['member']!, tokens['other']!]) {
        final listed = await listPins(pair.id, token);
        expect(listed.status, 200);
        expect((listed.json as Map)['pins'], [
          containsPair('messageId', existing),
        ]);
        expect((await pin(pair.id, existing, token)).status, 404);
        expect(
          (await pin(pair.id, existing, token, method: 'DELETE')).status,
          404,
        );
      }
      expect(
        ((await listPins(pair.id, tokens['member']!)).json as Map)['pins'],
        hasLength(1),
      );
    },
  );

  test('nonmember, unknown message and anonymous pins are rejected', () async {
    final group = (await conversations.createGroup(
      ownerAccountId: ids['member']!.value,
      name: 'Pins group',
    )).value;
    final sent = await sendMessage(group.id, tokens['member']!, 'p2');
    final messageId =
        ((sent.json! as Map)['message']! as Map)['messageId'] as String;
    final foreign = (await conversations.createGroup(
      ownerAccountId: ids['other']!.value,
      name: 'Foreign',
    )).value;

    expect((await pin(foreign.id, messageId, tokens['member'])).status, 404);
    expect(
      (await pin(group.id, 'missing-message', tokens['member'])).status,
      404,
    );
    expect((await pin(group.id, messageId, null)).status, 401);
    expect((await listPins(group.id, tokens['other']!)).status, 404);
  });
}
