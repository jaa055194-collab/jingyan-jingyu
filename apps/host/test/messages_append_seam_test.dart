import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/blind_index.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host/src/messages/messages_migrations.dart';
import 'package:jingyu_host/src/messages/messages_module.dart';
import 'package:jingyu_host/src/storage/cipher.dart';
import 'package:jingyu_host/src/storage/migrations.dart';
import 'package:jingyu_host/src/storage/sqlite_database.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Membership implements MembershipCheck {
  bool allowed = true;

  @override
  Future<bool> canPost(String accountId, String conversationId) async =>
      allowed;

  @override
  Future<bool> canRead(String accountId, String conversationId) async =>
      allowed;
}

class _Observer implements AcceptedMessageObserver {
  final messages = <StoredMessage>[];

  @override
  Future<void> onAccepted(StoredMessage message) async => messages.add(message);
}

void main() {
  late SqliteDatabase database;
  late AesGcmColumnCipher cipher;
  late BlindIndexService blind;
  late InMemoryMessageStore defaultStore;
  late InMemoryMessageStore checkedStore;
  late _Membership membership;
  late _Observer observer;

  setUp(() async {
    database = await SqliteDatabase.open(
      ':memory:',
      migrations: [...allMigrations, ...messagesMigrations],
    );
    cipher = AesGcmColumnCipher(List<int>.filled(32, 31));
    blind = BlindIndexService(database: database, cipher: cipher);
    defaultStore = InMemoryMessageStore(newId: () => 'default-message');
    checkedStore = InMemoryMessageStore(newId: () => 'checked-message');
    membership = _Membership();
    observer = _Observer();
  });

  tearDown(() async {
    await database.close();
    cipher.dispose();
  });

  Future<Pipeline> pipeline({IncomingMessageAppend? appendIncoming}) async {
    final services = HostServices()
      ..provide<MembershipCheck>(membership, owner: 'test')
      ..provide<AcceptedMessageObserver>(observer, owner: 'test');
    final module = MessagesModule(
      store: defaultStore,
      blind: blind,
      appendIncoming: appendIncoming,
    );
    await module.configure(services);
    // The seam does not replace the registered MessageStore used by other paths.
    expect(identical(services.get<MessageStore>(), defaultStore), isTrue);
    final router = Router();
    module.mount(router);
    return Pipeline(
      router: router,
      authenticate: (request) async =>
          request.headers['authorization'] == 'Bearer test-token'
          ? const Principal(accountId: 'human', deviceId: 'device')
          : null,
    );
  }

  Future<HostResponse> send(
    Pipeline pipeline, {
    String conversation = 'group',
    Object? body = const {
      'clientMsgId': 'one',
      'kind': 'text',
      'body': {'text': 'canonical message'},
    },
    bool authenticated = true,
  }) => pipeline.handle(
    HostRequest(
      method: 'POST',
      path: Routes.messages.replaceFirst('{conversationId}', conversation),
      headers: authenticated
          ? const {'authorization': 'Bearer test-token'}
          : const {},
      body: body,
    ),
  );

  Future<void> expectNoIndex() async {
    expect(
      await database.query('SELECT * FROM message_search_tokens'),
      isEmpty,
    );
    expect(await database.query('SELECT * FROM search_index_key'), isEmpty);
  }

  test(
    'omitted callback preserves default append, canonical response and duplicate observer semantics',
    () async {
      final app = await pipeline();
      final first = await send(app);
      expect(first.status, 200);
      final payload = first.json as Map;
      expect(payload['duplicate'], isFalse);
      final message = payload['message'] as Map;
      expect(message['messageId'], 'default-message');
      expect(message['senderId'], 'human');
      expect(message['conversationId'], 'group');
      expect(message['seq'], 1);
      final duplicate = await send(app);
      expect(duplicate.status, 200);
      expect((duplicate.json as Map)['duplicate'], isTrue);
      expect(await defaultStore.headSeq('group'), 1);
      expect(observer.messages.map((m) => m.messageId), ['default-message']);
      expect((await blind.candidates('canonical')).value, ['default-message']);
    },
  );

  test(
    'injected append commits to its real store and supplies response/index/observer canonical message',
    () async {
      var calls = 0;
      final app = await pipeline(
        appendIncoming:
            ({
              required conversationId,
              required senderId,
              required clientMsgId,
              required kind,
              required body,
            }) async {
              calls++;
              expect(conversationId, 'group');
              expect(senderId, 'human');
              expect(clientMsgId, 'one');
              expect(kind, MessageKind.text);
              expect(body, {'text': 'canonical message'});
              return checkedStore.append(
                conversationId: conversationId,
                senderId: senderId,
                clientMsgId: clientMsgId,
                kind: kind,
                body: body,
              );
            },
      );
      final first = await send(app);
      expect(first.status, 200);
      expect(
        ((first.json as Map)['message'] as Map)['messageId'],
        'checked-message',
      );
      expect(await checkedStore.headSeq('group'), 1);
      expect(await defaultStore.headSeq('group'), 0);
      expect(observer.messages.map((m) => m.messageId), ['checked-message']);
      expect((await blind.candidates('canonical')).value, ['checked-message']);

      final duplicate = await send(app);
      expect((duplicate.json as Map)['duplicate'], isTrue);
      expect(calls, 2);
      expect(await checkedStore.headSeq('group'), 1);
      expect(await defaultStore.headSeq('group'), 0);
      expect(observer.messages.length, 1);
    },
  );

  test(
    'checked refusal after prechecks never falls back, indexes or observes',
    () async {
      var calls = 0;
      final app = await pipeline(
        appendIncoming:
            ({
              required conversationId,
              required senderId,
              required clientMsgId,
              required kind,
              required body,
            }) async {
              calls++;
              return err(FailureCode.notFound, 'private current-grant detail');
            },
      );
      final response = await send(app);
      expect(calls, 1);
      expect(response.status, 404);
      expect(response.json, {'error': 'not_found'});
      expect(await defaultStore.headSeq('group'), 0);
      expect(await checkedStore.headSeq('group'), 0);
      expect(observer.messages, isEmpty);
      await expectNoIndex();
    },
  );

  test(
    'callback exception passes through real Pipeline safe-500 boundary without append/index/observer',
    () async {
      final app = await pipeline(
        appendIncoming:
            ({
              required conversationId,
              required senderId,
              required clientMsgId,
              required kind,
              required body,
            }) async => throw StateError('private callback credential detail'),
      );
      final response = await send(app);
      expect(response.status, 500);
      expect(response.json, {'error': 'internal'});
      expect(await defaultStore.headSeq('group'), 0);
      expect(observer.messages, isEmpty);
      await expectNoIndex();
    },
  );

  test(
    'unauthenticated and membership-denied requests cannot reach injected append',
    () async {
      var calls = 0;
      final app = await pipeline(
        appendIncoming:
            ({
              required conversationId,
              required senderId,
              required clientMsgId,
              required kind,
              required body,
            }) async {
              calls++;
              return checkedStore.append(
                conversationId: conversationId,
                senderId: senderId,
                clientMsgId: clientMsgId,
                kind: kind,
                body: body,
              );
            },
      );
      expect((await send(app, authenticated: false)).status, 401);
      membership.allowed = false;
      expect((await send(app)).status, 404);
      expect(calls, 0);
      expect(await defaultStore.headSeq('group'), 0);
      expect(await checkedStore.headSeq('group'), 0);
      expect(observer.messages, isEmpty);
      await expectNoIndex();
    },
  );

  final invalidRequests = <(String, Object?, int)>[
    ('bad.id', const {'clientMsgId': 'one', 'kind': 'text', 'body': {}}, 400),
    ('group', null, 400),
    ('group', const {'clientMsgId': 1, 'kind': 'text', 'body': {}}, 400),
    ('group', const {'clientMsgId': 'one', 'kind': 'unknown', 'body': {}}, 400),
    (
      'group',
      const {
        'clientMsgId': 'one',
        'kind': 'text',
        'body': {
          'mentionAccountIds': ['ai', 'other'],
        },
      },
      400,
    ),
    (
      'group',
      const {
        'clientMsgId': 'one',
        'kind': 'text',
        'body': {'attachmentId': 1},
      },
      400,
    ),
    (
      'group',
      const {
        'clientMsgId': 'one',
        'kind': 'text',
        'body': {'attachmentId': 'missing'},
      },
      500,
    ),
  ];
  for (var i = 0; i < invalidRequests.length; i++) {
    test(
      'existing validation/attachment precheck $i prevents callback and side effects',
      () async {
        var calls = 0;
        final app = await pipeline(
          appendIncoming:
              ({
                required conversationId,
                required senderId,
                required clientMsgId,
                required kind,
                required body,
              }) async {
                calls++;
                return checkedStore.append(
                  conversationId: conversationId,
                  senderId: senderId,
                  clientMsgId: clientMsgId,
                  kind: kind,
                  body: body,
                );
              },
        );
        final (conversation, body, status) = invalidRequests[i];
        expect(
          (await send(app, conversation: conversation, body: body)).status,
          status,
        );
        expect(calls, 0);
        expect(await defaultStore.headSeq('group'), 0);
        expect(await checkedStore.headSeq('group'), 0);
        expect(observer.messages, isEmpty);
        await expectNoIndex();
      },
    );
  }
}
