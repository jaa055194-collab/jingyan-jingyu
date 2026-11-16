import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../messages/accepted_message_observer.dart';
import '../messages/message_store.dart';
import 'classifier.dart';
import 'router.dart';
import 's1_responder.dart';

typedef GroupRulesDispatch =
    Future<void> Function(
      StoredMessage incoming,
      String targetAccountId,
      OutgoingPiece reply,
    );

/// Bounded local curated reactions only. The required composition-root callback
/// owns every live identity, visibility, social, budget and posting check.
final class GroupRulesModule extends HostModule
    implements AcceptedMessageObserver {
  GroupRulesModule({required GroupRulesDispatch dispatch})
    : _dispatch = dispatch;
  final GroupRulesDispatch _dispatch;
  static const _rules = RulesS1Responder();
  @override
  String get name => 'group_rules';
  @override
  List<String> get dependsOn => const [
    'messages',
    'social',
    'models',
    'social_level',
  ];
  @override
  Future<void> configure(HostServices services) async {
    services.provide<AcceptedMessageObserver>(this, owner: name);
  }

  @override
  Future<void> onAccepted(StoredMessage message) async {
    final text = message.body['text'],
        mentions = message.body['mentionAccountIds'];
    if (message.kind != MessageKind.text ||
        text is! String ||
        mentions is! List ||
        mentions.length != 1 ||
        mentions.single is! String) {
      return;
    }
    if (!_rules.supports(text) ||
        const RuleClassifier().classify(text, inGroup: true).complexity !=
            Complexity.simple) {
      return;
    }
    final target = mentions.single as String;
    final reply = _rules.curatedReply(text)!;
    await _dispatch(
      message,
      target,
      OutgoingPiece(text: reply.text, source: 's1'),
    );
  }
}
