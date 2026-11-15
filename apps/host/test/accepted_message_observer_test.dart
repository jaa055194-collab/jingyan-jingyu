import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Member implements MembershipCheck {
  @override
  Future<bool> canPost(String a, String c) async => true;
  @override
  Future<bool> canRead(String a, String c) async => true;
}

class _Observer implements AcceptedMessageObserver {
  int calls = 0;
  bool throws = false;
  @override
  Future<void> onAccepted(StoredMessage message) async {
    calls++;
    if (throws) throw StateError('private detail');
  }
}

void main() {
  test(
    'observer sees only fresh accepted sends and failure preserves input',
    () async {
      final store = InMemoryMessageStore(), observer = _Observer();
      final services = HostServices()
        ..provide<MembershipCheck>(_Member(), owner: 'test')
        ..provide<AcceptedMessageObserver>(observer, owner: 'test');
      final module = MessagesModule(store: store);
      await module.configure(services);
      final router = Router();
      module.mount(router);
      final pipeline = Pipeline(
        router: router,
        authenticate: (_) async =>
            const Principal(accountId: 'human', deviceId: 'device'),
      );
      Future<HostResponse> send(String id) => pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.messages.replaceFirst('{conversationId}', 'group'),
          body: {
            'clientMsgId': id,
            'kind': 'text',
            'body': {'text': '你好'},
          },
        ),
      );
      expect((await send('one')).status, 200);
      expect((await send('one')).status, 200);
      expect(observer.calls, 1);
      observer.throws = true;
      expect((await send('two')).status, 200);
      expect(observer.calls, 2);
      expect(await store.headSeq('group'), 2);
    },
  );
  for (final bad in [
    null,
    'ai',
    1,
    ['ai', 'other'],
    [1],
    ['bad.id'],
  ]) {
    test('reserved mention syntax rejected before append: $bad', () async {
      final store = InMemoryMessageStore();
      final services = HostServices()
        ..provide<MembershipCheck>(_Member(), owner: 'test');
      final module = MessagesModule(store: store);
      await module.configure(services);
      final router = Router();
      module.mount(router);
      final pipeline = Pipeline(
        router: router,
        authenticate: (_) async =>
            const Principal(accountId: 'human', deviceId: 'device'),
      );
      final result = await pipeline.handle(
        HostRequest(
          method: 'POST',
          path: Routes.messages.replaceFirst('{conversationId}', 'group'),
          body: {
            'clientMsgId': 'one',
            'kind': 'text',
            'body': {'text': '你好', 'mentionAccountIds': bad},
          },
        ),
      );
      expect(result.status, 400);
      expect(await store.headSeq('group'), 0);
    });
  }
  test('reserved mention metadata not allowed on nontext', () async {
    final store = InMemoryMessageStore();
    final services = HostServices()
      ..provide<MembershipCheck>(_Member(), owner: 'test');
    final module = MessagesModule(store: store);
    await module.configure(services);
    final router = Router();
    module.mount(router);
    final pipeline = Pipeline(
      router: router,
      authenticate: (_) async =>
          const Principal(accountId: 'human', deviceId: 'device'),
    );
    final result = await pipeline.handle(
      HostRequest(
        method: 'POST',
        path: Routes.messages.replaceFirst('{conversationId}', 'group'),
        body: {
          'clientMsgId': 'one',
          'kind': 'image',
          'body': {
            'mentionAccountIds': ['ai'],
          },
        },
      ),
    );
    expect(result.status, 400);
    expect(await store.headSeq('group'), 0);
  });
}
