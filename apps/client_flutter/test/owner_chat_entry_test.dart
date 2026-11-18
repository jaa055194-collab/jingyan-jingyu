import 'dart:async';

import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

const entry = Key('own-ai-direct-chat-ai-owner');
const directId = 'canonical-direct';

class OwnerChatFixture extends TestShellModel {
  OwnerChatFixture() {
    connectedAccountId = 'fixture-owner';
    online = true;
    themeMode = ThemeMode.light;
    conversations = const [
      ShellConversation(id: 'other', title: '私聊', kind: 'direct'),
    ];
  }

  Object epoch = Object();
  bool enabled = true;
  bool visible = true;
  Completer<void>? refreshGate;
  int refreshes = 0, writes = 0, sends = 0;
  final selections = <String>[];

  @override
  bool get ownAiLoaded => true;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(
      accountId: 'ai-owner',
      displayName: 'Fixture Nora',
      disabled: false,
    ),
  ];
  @override
  Object? get ownAiDirectContext => authenticated && !locked ? epoch : null;
  @override
  ShellOwnAiDirectState ownAiDirectState(String account) =>
      ShellOwnAiDirectState(
        phase: ShellOwnAiDirectPhase.ready,
        profileId: 'profile-owner',
        revision: 1,
        enabled: enabled,
        conversationId: directId,
      );

  @override
  Future<bool> refreshForOwnAiChat() async {
    refreshes++;
    await refreshGate?.future;
    if (visible) {
      conversations = [
        ...conversations,
        const ShellConversation(id: directId, title: '私聊', kind: 'direct'),
      ];
    }
    notifyListeners();
    return true;
  }

  @override
  Future<void> selectConversation(String id) async {
    selections.add(id);
    await super.selectConversation(id);
  }

  @override
  Future<void> setOwnAiDirectConsent(
    String aiAccountId, {
    required String profileId,
    required int expectedRevision,
    required bool enabled,
    required Object interactionContext,
  }) async => writes++;

  @override
  Future<void> sendMessage() async => sends++;
}

Future<void> openOwnerSettings(
  WidgetTester tester,
  OwnerChatFixture model,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(390, 844);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  await tester.pumpWidget(WhaleChatApp(model: model));
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(
    find.byKey(const Key('own-ai-direct-refresh-ai-owner')),
    260,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'authorized owner opens the canonical direct chat without a write',
    (tester) async {
      final model = OwnerChatFixture();
      await openOwnerSettings(tester, model);
      expect(model.selections, isEmpty);
      await tester.ensureVisible(find.byKey(entry));
      await tester.tap(find.byKey(entry));
      await tester.pumpAndSettle();
      expect(model.refreshes, 1);
      expect(model.selections, [directId]);
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(model.writes, 0);
      expect(model.sends, 0);
    },
  );

  testWidgets('closed authorization has no chat shortcut', (tester) async {
    final model = OwnerChatFixture()..enabled = false;
    await openOwnerSettings(tester, model);
    expect(find.byKey(entry), findsNothing);
    expect(model.refreshes, 0);
  });

  testWidgets('not returned by refresh does not select or open a chat', (
    tester,
  ) async {
    final model = OwnerChatFixture()..visible = false;
    await openOwnerSettings(tester, model);
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pumpAndSettle();
    expect(model.refreshes, 1);
    expect(model.selections, isEmpty);
    expect(find.byKey(const Key('composer')), findsNothing);
    expect(find.text('未能找到该私聊，请刷新授权状态后再试。'), findsOneWidget);
  });

  for (final interruption in ['lock', 'logout', 'consent change']) {
    testWidgets('$interruption during refresh prevents delayed navigation', (
      tester,
    ) async {
      final model = OwnerChatFixture()..refreshGate = Completer<void>();
      await openOwnerSettings(tester, model);
      await tester.ensureVisible(find.byKey(entry));
      await tester.tap(find.byKey(entry));
      await tester.pump();
      expect(model.refreshes, 1);
      if (interruption == 'lock') model.locked = true;
      if (interruption == 'logout') model.connectedAccountId = null;
      if (interruption == 'consent change') model.enabled = false;
      model.epoch = Object();
      model.notifyListeners();
      await tester.pump();
      model.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(model.selections, isEmpty);
      expect(find.byKey(const Key('composer')), findsNothing);
      expect(model.writes, 0);
      expect(model.sends, 0);
    });
  }
}
