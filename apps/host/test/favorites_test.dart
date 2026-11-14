import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/accounts/accounts_migrations.dart';
import 'package:jingyu_host/src/accounts/accounts_sql_store.dart';
import 'package:jingyu_host/src/accounts/password_hasher.dart';
import 'package:jingyu_host/src/messages/favorites.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
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

class _CountingCipher implements ColumnCipher {
  _CountingCipher(this.delegate);
  final ColumnCipher delegate;
  int decryptCalls = 0;
  @override
  String encrypt(String plaintext, {required String aad}) =>
      delegate.encrypt(plaintext, aad: aad);
  @override
  Result<String> decrypt(String sealed, {required String aad}) {
    decryptCalls++;
    return delegate.decrypt(sealed, aad: aad);
  }
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

  Future<HostResponse> addFavorite(String? bearer, Object? body) =>
      pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.favorites,
          headers: {if (bearer != null) 'authorization': 'Bearer $bearer'},
          body: body,
        ),
      );

  Future<HostResponse> listFavorites(String bearer) => pipeline.handle(
    HostRequest(
      method: 'GET',
      path: Routes.favorites,
      headers: {'authorization': 'Bearer $bearer'},
    ),
  );

  Future<HostResponse> removeFavorite(String id, String bearer) =>
      pipeline.handle(
        HostRequest(
          method: 'DELETE',
          path: Routes.favorite.replaceFirst('{favoriteId}', id),
          headers: {'authorization': 'Bearer $bearer'},
        ),
      );

  Future<HostResponse> searchFavorites(String bearer, String q) =>
      pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.search,
          query: {'q': q, 'type': 'favorite'},
          headers: {'authorization': 'Bearer $bearer'},
        ),
      );

  Future<HostResponse> sendMessage(
    String conversationId,
    String bearer,
    String clientMsgId,
    String text,
  ) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversationId),
      headers: {'authorization': 'Bearer $bearer'},
      body: {
        'clientMsgId': clientMsgId,
        'kind': 'text',
        'body': {'text': text},
      },
    ),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('favorites-');
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
    );
    final router = Router();
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'favorites-test')
      ..provide<HistoryMembershipCheck>(membership, owner: 'favorites-test');
    final module = MessagesModule(
      store: messages,
      authenticate: DbAuthenticator(accounts).call,
      favorites: FavoritesService(
        database: db,
        cipher: cipher,
        clock: clock,
        newId: () => 'fav-${DateTime.now().microsecondsSinceEpoch}',
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

  List<Map<String, Object?>> items(HostResponse response) =>
      ((response.json! as Map)['favorites'] as List)
          .cast<Map<String, Object?>>();

  test('untitled favorites do not match the synthetic string null', () async {
    expect(
      (await addFavorite(tokens['member'], {
        'kind': 'text',
        'content': 'hello',
      })).status,
      200,
    );
    final response = await searchFavorites(tokens['member']!, 'null');
    expect(response.status, 200);
    expect((response.json! as Map)['hits'], isEmpty);
  });

  test('text favorite is private, searchable and removable', () async {
    final added = await addFavorite(tokens['member'], {
      'kind': 'text',
      'title': '书摘',
      'content': '项目代号鲸落',
    });
    expect(added.status, 200);
    final id = (added.json! as Map)['id'] as String;

    final listed = await listFavorites(tokens['member']!);
    expect(items(listed), hasLength(1));
    expect(items(listed).single['content'], '项目代号鲸落');

    final found = await searchFavorites(tokens['member']!, '鲸落');
    expect(found.status, 200);
    expect(((found.json! as Map)['hits'] as List), hasLength(1));

    expect((await listFavorites(tokens['other']!)).json, {'favorites': []});
    expect((await removeFavorite(id, tokens['other']!)).status, 404);
    expect((await removeFavorite(id, tokens['member']!)).status, 200);
    expect(items(await listFavorites(tokens['member']!)), isEmpty);
  });

  test(
    'message favorites are references and stop exposing content after recall',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Favorites group',
      )).value;
      final sent = await sendMessage(
        group.id,
        tokens['member']!,
        'f1',
        '会消失的正文',
      );
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;

      final added = await addFavorite(tokens['member'], {
        'kind': 'message',
        'messageId': messageId,
        'conversationId': group.id,
        'title': '收藏的消息',
      });
      expect(added.status, 200);
      final found = await searchFavorites(tokens['member']!, '消失');
      expect(((found.json! as Map)['hits'] as List), hasLength(1));

      await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.messageRecall
              .replaceFirst('{conversationId}', group.id)
              .replaceFirst('{messageId}', messageId),
          headers: {'authorization': 'Bearer ${tokens['member']}'},
        ),
      );
      final stored = (await db.query(
        'SELECT content FROM favorites WHERE id = ?',
        [(added.json! as Map)['id']],
      )).single;
      expect(
        stored['content'],
        isNull,
        reason: 'Message favorites must not keep a plaintext-source snapshot',
      );
      final again = await searchFavorites(tokens['member']!, '消失');
      expect(again.status, 200);
      expect(((again.json! as Map)['hits'] as List), isEmpty);
      expect(items(await listFavorites(tokens['member']!)), isEmpty);
    },
  );

  test(
    'foreign and pre-join messages cannot become favorite references',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Private joined history',
        historyVisibility: HistoryVisibility.joined,
      )).value;
      final sent = await sendMessage(
        group.id,
        tokens['other']!,
        'hidden',
        'hidden-source',
      );
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;
      Future<void> denied() async {
        final response = await addFavorite(tokens['member'], {
          'kind': 'message',
          'conversationId': group.id,
          'messageId': messageId,
        });
        expect(response.status, 404);
        expect(await db.query('SELECT id FROM favorites'), isEmpty);
      }

      await denied();
      await conversations.addMember(
        actorAccountId: ids['other']!.value,
        conversationId: group.id,
        memberAccountId: ids['member']!.value,
      );
      await denied();
    },
  );

  test(
    'message favorites follow source edits and disappear after membership revocation',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['other']!.value,
        name: 'Accessible group',
      )).value;
      await conversations.addMember(
        actorAccountId: ids['other']!.value,
        conversationId: group.id,
        memberAccountId: ids['member']!.value,
      );
      final sent = await sendMessage(
        group.id,
        tokens['other']!,
        'live',
        'old-live-text',
      );
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;
      final added = await addFavorite(tokens['member'], {
        'kind': 'message',
        'conversationId': group.id,
        'messageId': messageId,
        'title': 'private-favorite-title',
      });
      expect(added.status, 200);
      final favoriteId = (added.json! as Map)['id'];
      final row = (await db.query(
        'SELECT content, title FROM favorites WHERE id = ?',
        [favoriteId],
      )).single;
      expect(row['content'], isNull);
      expect(row['title'], isNot('private-favorite-title'));
      expect((await searchFavorites(tokens['other']!, 'old-live-text')).json, {
        'type': 'favorite',
        'hits': [],
      });
      final edited = await messages.edit(
        conversationId: group.id,
        messageId: messageId,
        senderId: ids['other']!.value,
        body: {'text': 'new-live-text'},
      );
      expect(edited.isOk, isTrue);
      expect(
        ((await searchFavorites(tokens['member']!, 'old-live-text')).json!
            as Map)['hits'],
        isEmpty,
      );
      expect(
        ((await searchFavorites(tokens['member']!, 'new-live-text')).json!
            as Map)['hits'],
        hasLength(1),
      );
      expect(
        (await conversations.leave(
          actorId: ids['member']!.value,
          conversationId: group.id,
        )).isOk,
        isTrue,
      );
      expect(items(await listFavorites(tokens['member']!)), isEmpty);
      expect(
        ((await searchFavorites(
              tokens['member']!,
              'private-favorite-title',
            )).json!
            as Map)['hits'],
        isEmpty,
      );
    },
  );

  test(
    'missing visibility cannot decrypt message favorites or add new references',
    () async {
      final group = (await conversations.createGroup(
        ownerAccountId: ids['member']!.value,
        name: 'Private source',
      )).value;
      final sent = await sendMessage(
        group.id,
        tokens['member']!,
        'denied-source',
        'secret',
      );
      final messageId =
          ((sent.json! as Map)['message']! as Map)['messageId'] as String;
      expect(
        (await addFavorite(tokens['member'], {
          'kind': 'message',
          'messageId': messageId,
          'conversationId': group.id,
          'title': 'sensitive-title',
        })).status,
        200,
      );
      final counter = _CountingCipher(cipher);
      final service = FavoritesService(database: db, cipher: counter);
      expect(
        (await service.add(
          ownerAccountId: ids['member']!.value,
          kind: 'message',
          messageId: messageId,
          conversationId: group.id,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await service.list(ownerAccountId: ids['member']!.value)).value,
        isEmpty,
      );
      expect(
        (await service.search(
          ownerAccountId: ids['member']!.value,
          query: 'sensitive-title',
        )).value,
        isEmpty,
      );
      expect(counter.decryptCalls, 0);
      await db.execute(
        'UPDATE messages SET body = ?, recalled_at = ? WHERE message_id = ?',
        ['damaged', '2026-11-14T10:00:00Z', messageId],
      );
      expect(
        (await service.list(
          ownerAccountId: ids['member']!.value,
          firstVisibleSeq: (_, _) async => 1,
        )).value,
        isEmpty,
      );
      expect(counter.decryptCalls, 0);
      expect(
        (await addFavorite(tokens['member'], {
          'kind': 'message',
          'messageId': messageId,
          'conversationId': group.id,
        })).status,
        404,
      );
    },
  );

  test(
    'malformed optional fields and unknown favorite fields are rejected without writes',
    () async {
      for (final body in [
        {'kind': 'text', 'content': 'hello', 'title': 3},
        {'kind': 'text', 'content': 'hello', 'messageId': 3},
        {'kind': 'text', 'content': 'hello', 'conversationId': []},
        {'kind': 'text', 'content': 'hello', 'actorId': ids['other']!.value},
      ]) {
        expect((await addFavorite(tokens['member'], body)).status, 400);
      }
      expect(await db.query('SELECT id FROM favorites'), isEmpty);
    },
  );

  test(
    'corrupt stored favorites return safe internal errors without partial data',
    () async {
      final added = await addFavorite(tokens['member'], {
        'kind': 'text',
        'title': 'private',
        'content': 'secret',
      });
      expect(added.status, 200);
      final id = (added.json! as Map)['id'];
      await db.execute('UPDATE favorites SET content = ? WHERE id = ?', [
        'damaged',
        id,
      ]);
      final listed = await listFavorites(tokens['member']!);
      expect(listed.status, 500);
      expect(listed.json, {'error': 'internal'});
    },
  );

  test(
    'invalid kinds, missing content, anonymous and bad search type are rejected',
    () async {
      expect(
        (await addFavorite(tokens['member'], {
          'kind': 'nope',
          'content': 'x',
        })).status,
        400,
      );
      expect(
        (await addFavorite(tokens['member'], {'kind': 'text'})).status,
        400,
      );
      expect(
        (await addFavorite(null, {'kind': 'text', 'content': 'x'})).status,
        401,
      );
      final badType = await pipeline.handle(
        HostRequest(
          method: 'GET',
          path: Routes.search,
          query: {'q': 'x', 'type': 'nope'},
          headers: {'authorization': 'Bearer ${tokens['member']}'},
        ),
      );
      expect(badType.status, 400);
    },
  );
}
