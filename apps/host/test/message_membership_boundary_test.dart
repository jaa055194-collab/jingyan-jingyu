import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _History implements HistoryMembershipCheck {
  @override
  Future<bool> canRead(String account, String conversation) async =>
      account == 'member';
  @override
  Future<bool> canPost(String account, String conversation) =>
      canRead(account, conversation);
  @override
  Future<int?> firstVisibleSeq(String account, String conversation) async =>
      account == 'member' ? 3 : null;
}

void main() {
  test('messages fail closed when membership service is missing', () async {
    final registry = Registry()..register(MessagesModule());
    await registry.boot();
    addTearDown(registry.shutdown);
    final pipeline = Pipeline(
      router: registry.router,
      authenticate: (_) async =>
          const Principal(accountId: 'member', deviceId: 'd'),
    );
    final response = await pipeline.handle(
      HostRequest(method: 'GET', path: '/api/v1/conversations/c/sync'),
    );
    expect(response.status, 404);
  });

  test(
    'sync reports the history lower bound independently of the page',
    () async {
      final services = HostServices();
      final store = InMemoryMessageStore();
      for (var i = 1; i <= 4; i++) {
        await store.append(
          conversationId: 'c',
          senderId: 'owner',
          clientMsgId: 'm$i',
          kind: MessageKind.text,
          body: {'text': 'message $i'},
        );
      }
      services.provide<MembershipCheck>(_History(), owner: 'test');
      services.provide<HistoryMembershipCheck>(_History(), owner: 'test');
      final module = MessagesModule(store: store);
      await module.configure(services);
      final router = Router();
      module.mount(router);
      final pipeline = Pipeline(
        router: router,
        authenticate: (_) async =>
            const Principal(accountId: 'member', deviceId: 'd'),
      );
      for (final (afterSeq, sequences, hasMore) in [
        ('0', [3], true),
        ('3', [4], false),
        ('99', <int>[], false),
      ]) {
        final response = await pipeline.handle(
          HostRequest(
            method: 'GET',
            path: Routes.sync.replaceFirst('{conversationId}', 'c'),
            query: {'afterSeq': afterSeq, 'limit': '1'},
          ),
        );
        expect(response.status, 200);
        final data = response.json as Map;
        expect(data['firstVisibleSeq'], 3, reason: 'afterSeq=$afterSeq');
        expect(
          (data['messages'] as List).map((m) => (m as Map)['seq']),
          sequences,
        );
        expect(data['hasMore'], hasMore);
      }
    },
  );
}
