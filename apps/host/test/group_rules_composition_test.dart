import 'package:jingyu_host/src/brain/group_rules_module.dart';
import 'package:jingyu_host/src/messages/accepted_message_fanout.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

class _Recorder implements AcceptedMessageObserver {
  final accepted = <StoredMessage>[];
  @override
  Future<void> onAccepted(StoredMessage message) async => accepted.add(message);
}

StoredMessage _greeting() => StoredMessage(
  conversationId: 'group',
  seq: 1,
  messageId: 'message',
  senderId: 'human',
  clientMsgId: 'one',
  kind: MessageKind.text,
  body: const {
    'text': '你好',
    'mentionAccountIds': ['ai'],
  },
  sentAt: DateTime.utc(2026),
);

void main() {
  test('default constructor registers the unchanged rules instance', () async {
    final module = GroupRulesModule(dispatch: (_, target, reply) async {});
    final services = HostServices();
    await module.configure(services);
    expect(identical(services.get<AcceptedMessageObserver>(), module), isTrue);
    expect(services.describe(), {'AcceptedMessageObserver': 'group_rules'});
  });

  test(
    'compose receives rules once and registers exactly one fanout provider',
    () async {
      var compositions = 0;
      AcceptedMessageObserver? received;
      final recorder = _Recorder();
      final dispatched = <String>[];
      final module = GroupRulesModule(
        dispatch: (incoming, target, reply) async {
          dispatched.add('$target:${reply.source}:${reply.text}');
        },
        composeObserver: (rules) {
          compositions++;
          received = rules;
          return AcceptedMessageFanout([rules, recorder]);
        },
      );
      final services = HostServices();
      await module.configure(services);
      expect(compositions, 1);
      expect(identical(received, module), isTrue);
      expect(services.describe(), {'AcceptedMessageObserver': 'group_rules'});
      final observer = services.get<AcceptedMessageObserver>();
      expect(observer, isA<AcceptedMessageFanout>());
      final message = _greeting();
      await observer.onAccepted(message);
      expect(dispatched, ['ai:s1:你好呀']);
      expect(recorder.accepted, [same(message)]);
    },
  );

  test(
    'real rules dispatch failure still allows next child to accept message',
    () async {
      final recorder = _Recorder();
      final attempts = <String>[];
      final module = GroupRulesModule(
        dispatch: (incoming, target, reply) async {
          attempts.add(reply.text);
          throw StateError('synthetic dispatch failure; no message logging');
        },
        composeObserver: (rules) => AcceptedMessageFanout([rules, recorder]),
      );
      final services = HostServices();
      await module.configure(services);
      final message = _greeting();
      await services.get<AcceptedMessageObserver>().onAccepted(message);
      expect(attempts, ['你好呀']);
      expect(recorder.accepted, [same(message)]);
    },
  );
}
