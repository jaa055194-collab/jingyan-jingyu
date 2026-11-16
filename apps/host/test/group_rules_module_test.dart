import 'package:jingyu_host/src/brain/group_rules_module.dart';
import 'package:jingyu_host/src/messages/accepted_message_observer.dart';
import 'package:jingyu_host/src/messages/message_store.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('bounded bridge dispatches curated supported text only', () async {
    final replies = <String>[];
    final module = GroupRulesModule(
      dispatch: (message, target, reply) async {
        expect(target, 'ai');
        expect(reply.source, 's1');
        expect(reply.activityRefs, isEmpty);
        replies.add(reply.text);
      },
    );
    final services = HostServices();
    await module.configure(services);
    final observer = services.get<AcceptedMessageObserver>();
    for (final text in ['你好', '短句', '你好怎么做？', '任意不确定的长句']) {
      await observer.onAccepted(
        StoredMessage(
          conversationId: 'group',
          seq: 1,
          messageId: 'msg',
          senderId: 'human',
          clientMsgId: 'one',
          kind: MessageKind.text,
          body: {
            'text': text,
            'mentionAccountIds': ['ai'],
          },
          sentAt: DateTime.utc(2026),
        ),
      );
    }
    expect(replies, ['你好呀']);
  });
}
