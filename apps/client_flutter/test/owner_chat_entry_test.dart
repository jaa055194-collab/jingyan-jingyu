import 'dart:async';

import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/features/world/world_status_screen.dart';
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
  OwnAiChatEntry? entryResult;
  bool multipleAccounts = false;
  Completer<void>? refreshGate;
  int refreshes = 0, writes = 0, sends = 0;
  final selections = <String>[];

  @override
  bool get ownAiLoaded => true;
  @override
  List<ShellOwnedAi> get ownAiAccounts => [
    const ShellOwnedAi(
      accountId: 'ai-owner',
      displayName: 'Fixture Nora',
      disabled: false,
    ),
    if (multipleAccounts)
      const ShellOwnedAi(
        accountId: 'ai-other',
        displayName: 'Fixture Mira',
        disabled: false,
      ),
  ];
  @override
  Object? get ownAiDirectContext => authenticated && !locked ? epoch : null;
  @override
  ShellOwnAiDirectState ownAiDirectState(String account) =>
      ShellOwnAiDirectState(
        phase: ShellOwnAiDirectPhase.ready,
        profileId: account == 'ai-owner' ? 'profile-owner' : 'profile-other',
        revision: 1,
        enabled: enabled,
        conversationId: account == 'ai-owner' ? directId : 'other',
      );

  @override
  Future<OwnAiChatEntry> checkOwnAiChatEntry(String aiAccountId) async {
    refreshes++;
    await refreshGate?.future;
    if (entryResult case final result?) return result;
    if (visible) {
      conversations = [
        ...conversations,
        const ShellConversation(id: directId, title: '私聊', kind: 'direct'),
      ];
    }
    notifyListeners();
    return visible ? OwnAiChatEntry.ready : OwnAiChatEntry.notVisible;
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
  OwnerChatFixture model, {
  double width = 390,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
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
    expect(find.text('此私聊在当前会话列表中不可见。'), findsOneWidget);
  });

  for (final (result, notice) in [
    (OwnAiChatEntry.consentChanged, '宿主的私聊授权已变化，未打开会话。'),
    (OwnAiChatEntry.busy, '正在更新会话，请稍后再试。'),
    (OwnAiChatEntry.unavailable, '暂时无法核对私聊，请检查连接或登录状态后再试。'),
  ]) {
    testWidgets('$result is shown without selecting a conversation', (
      tester,
    ) async {
      final model = OwnerChatFixture()
        ..entryResult = result
        ..refreshGate = Completer<void>();
      await openOwnerSettings(tester, model);
      await tester.ensureVisible(find.byKey(entry));
      await tester.tap(find.byKey(entry));
      if (result == OwnAiChatEntry.busy) {
        model.busy = true;
        model.notifyListeners();
      }
      model.refreshGate!.complete();
      // The busy indicator animates continuously; don't wait for it to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(notice), findsOneWidget);
      expect(model.selections, isEmpty);
      expect(find.byKey(const Key('composer')), findsNothing);
    });
  }

  for (final interruption in [
    'revoke dialog',
    'revoke dialog then return',
    'settings page',
    'settings page then return',
  ]) {
    testWidgets('$interruption invalidates pending owner-chat navigation', (
      tester,
    ) async {
      final model = OwnerChatFixture()..refreshGate = Completer<void>();
      await openOwnerSettings(tester, model);
      await tester.ensureVisible(find.byKey(entry));
      await tester.tap(find.byKey(entry));
      await tester.pump();
      expect(model.refreshes, 1);

      if (interruption.startsWith('revoke dialog')) {
        final toggle = find.byKey(const Key('own-ai-direct-toggle-ai-owner'));
        await tester.ensureVisible(toggle);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(find.text('确认撤销私聊授权'), findsOneWidget);
        if (interruption.endsWith('return')) {
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
          expect(find.byType(SettingsScreen), findsOneWidget);
        }
      } else {
        final page = find.byKey(const Key('open-world-status'));
        final settings = find.byType(SettingsScreen);
        final status = find.byType(WorldStatusScreen);
        await tester.scrollUntilVisible(
          page,
          -260,
          scrollable: find
              .descendant(of: settings, matching: find.byType(Scrollable))
              .first,
        );
        await tester.tap(page);
        await tester.pumpAndSettle();
        expect(status, findsOneWidget);
        expect(settings, findsNothing);
        if (interruption.endsWith('return')) {
          await tester.pageBack();
          await tester.pumpAndSettle();
          expect(status, findsNothing);
          expect(settings, findsOneWidget);
        }
      }

      model.refreshGate!.complete();
      await tester.pumpAndSettle();
      expect(model.selections, isEmpty);
      expect(model.writes, 0);
      expect(model.sends, 0);
      expect(
        find.byKey(const Key('composer'), skipOffstage: false),
        findsNothing,
      );
      if (interruption == 'revoke dialog') {
        expect(find.text('确认撤销私聊授权'), findsOneWidget);
      } else if (!interruption.endsWith('return')) {
        expect(find.text('世界状态'), findsOneWidget);
      }
    });
  }

  testWidgets('wide Settings tab navigation supersedes a pending chat check', (
    tester,
  ) async {
    final model = OwnerChatFixture()..refreshGate = Completer<void>();
    await openOwnerSettings(tester, model, width: 1000);
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pump();
    expect(model.refreshes, 1);

    final rail = find.byType(NavigationRail);
    await tester.tap(find.descendant(of: rail, matching: find.text('联系人')));
    await tester.pumpAndSettle();
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
    expect(find.byType(SettingsScreen), findsNothing);
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    model.refreshGate!.complete();
    await tester.pumpAndSettle();
    expect(model.selections, isEmpty);
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(tester.widget<NavigationRail>(rail).selectedIndex, 1);
  });

  testWidgets('owner chat controls visibly wait during another AI check', (
    tester,
  ) async {
    final model = OwnerChatFixture()
      ..multipleAccounts = true
      ..refreshGate = Completer<void>();
    await openOwnerSettings(tester, model);
    await tester.ensureVisible(find.byKey(entry));
    await tester.tap(find.byKey(entry));
    await tester.pump();
    final other = find.byKey(const Key('own-ai-direct-chat-ai-other'));
    await tester.ensureVisible(other);
    expect(find.text('正在核对私聊…'), findsOneWidget);
    expect(tester.widget<TextButton>(other).onPressed, isNull);
    expect(model.refreshes, 1);
    model.refreshGate!.complete();
    await tester.pumpAndSettle();
    expect(model.selections, [directId]);
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
