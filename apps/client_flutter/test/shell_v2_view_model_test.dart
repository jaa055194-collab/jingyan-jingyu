import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only the own-AI members are real. Everything else forwards to
/// noSuchMethod, so the test sees the inherited ShellViewModel defaults.
class _DefaultsModel extends ShellViewModel {
  _DefaultsModel({
    this.accounts = const <ShellOwnedAi>[],
    this.direct = const <String, ShellOwnAiDirectState>{},
  });

  final List<ShellOwnedAi> accounts;
  final Map<String, ShellOwnAiDirectState> direct;

  @override
  List<ShellOwnedAi> get ownAiAccounts => accounts;

  @override
  ShellOwnAiDirectState ownAiDirectState(String aiAccountId) =>
      direct[aiAccountId] ?? const ShellOwnAiDirectState();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ShellOwnedAi _ai(String id) =>
    ShellOwnedAi(accountId: id, displayName: id, disabled: false);

void main() {
  test('new members keep the pre-v2 behaviour by default', () async {
    final model = _DefaultsModel();
    addTearDown(model.dispose);

    expect(model.reduceMotion, isFalse);
    expect(model.conversationsLoaded, isTrue);
    expect(model.partnerConversationId, isNull);
    await model.setReduceMotion(true);
    expect(model.reduceMotion, isFalse);
  });

  test('partner conversation is the first own AI direct chat with an id', () {
    final model = _DefaultsModel(
      accounts: [_ai('ai-1'), _ai('ai-2'), _ai('ai-3')],
      direct: const {
        'ai-1': ShellOwnAiDirectState(conversationId: ''),
        'ai-2': ShellOwnAiDirectState(
          phase: ShellOwnAiDirectPhase.ready,
          conversationId: 'dm-2',
        ),
        'ai-3': ShellOwnAiDirectState(
          phase: ShellOwnAiDirectPhase.ready,
          conversationId: 'dm-3',
        ),
      },
    );
    addTearDown(model.dispose);

    expect(model.partnerConversationId, 'dm-2');
  });

  test('partner conversation stays null until a direct state names one', () {
    final model = _DefaultsModel(
      accounts: [_ai('ai-1')],
      direct: const {
        'ai-1': ShellOwnAiDirectState(phase: ShellOwnAiDirectPhase.loading),
      },
    );
    addTearDown(model.dispose);

    expect(model.partnerConversationId, isNull);
  });

  test('conversation rows carry an optional last activity time', () {
    const plain = ShellConversation(id: 'a', title: 'A');
    expect(plain.lastActivityAt, isNull);

    final at = DateTime.utc(2026, 11, 25, 5, 30);
    final dated = ShellConversation(id: 'b', title: 'B', lastActivityAt: at);
    expect(dated.lastActivityAt, at);
  });
}
