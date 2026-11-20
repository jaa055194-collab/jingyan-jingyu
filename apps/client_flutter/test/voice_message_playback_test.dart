import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _Model extends TestShellModel {
  _Model({this.supportsVoicePlayback = true}) {
    connectedAccountId = 'reader';
    online = true;
    selectedConversationId = 'a';
    messages = const [
      ShellMessage(id: 'voice-one', text: '一条语音', voiceAttachment: true),
      ShellMessage(id: 'pending', text: '[audio]', status: '等待补传'),
      ShellMessage(id: 'file', text: '文档'),
      ShellMessage(id: 'voice-two', text: '另一条语音', voiceAttachment: true),
    ];
  }

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    notifyListeners();
  }

  @override
  final bool supportsVoicePlayback;
  @override
  ShellVoicePlayback? voicePlayback;
  final plays = <String>[];
  int stops = 0;
  bool Function()? viewGuard;

  @override
  Future<void> playVoiceMessage(
    String messageId, {
    required bool Function() viewIsCurrent,
    Future<void> Function()? waitForView,
  }) async {
    expect(viewIsCurrent(), isTrue);
    viewGuard = viewIsCurrent;
    plays.add(messageId);
    voicePlayback = ShellVoicePlayback(messageId, ShellVoicePhase.loading);
    notifyListeners();
  }

  @override
  void stopVoicePlayback({bool Function()? viewIsCurrent}) {
    if (voicePlayback == null ||
        (viewIsCurrent != null && !identical(viewIsCurrent, viewGuard))) {
      return;
    }
    stops++;
    voicePlayback = null;
    // The real runtime coordinates its own notification with the frame.
  }
}

Finder play(String id) => find.byKey(Key('play-voice-$id'));
Finder stop(String id) => find.byKey(Key('stop-voice-$id'));

Future<void> _chat(
  WidgetTester tester,
  _Model model, {
  GlobalKey<NavigatorState>? navigator,
}) async {
  tester.view.physicalSize = const Size(360, 720);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.platformDispatcher.textScaleFactorTestValue = 1.35;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Scaffold(body: ChatPane(model: model)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'explicit audio action shows cancellable loading and disables other rows',
    (tester) async {
      final model = _Model();
      await _chat(tester, model);
      expect(play('voice-one').hitTestable(), findsOneWidget);
      expect(play('pending'), findsNothing);
      expect(play('file'), findsNothing);
      expect(model.plays, isEmpty);
      await tester.tap(play('voice-one'));
      await tester.pumpAndSettle();
      expect(model.plays, ['voice-one']);
      expect(stop('voice-one').hitTestable(), findsOneWidget);
      expect(find.text('正在加载语音…'), findsOneWidget);
      expect(tester.widget<TextButton>(play('voice-two')).onPressed, isNull);
      await tester.tap(stop('voice-one'));
      await tester.pumpAndSettle();
      expect(model.stops, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'no control on unsupported platforms or an unauthenticated pane',
    (tester) async {
      await _chat(tester, _Model(supportsVoicePlayback: false));
      expect(play('voice-one'), findsNothing);
      await _chat(tester, _Model()..connectedAccountId = null);
      expect(play('voice-one'), findsNothing);
    },
  );

  testWidgets('a route covering the chat pane stops the current play', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    final model = _Model();
    await _chat(tester, model, navigator: navigator);
    await tester.tap(play('voice-one'));
    await tester.pumpAndSettle();
    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other page')),
      ),
    );
    expect(
      model.viewGuard!(),
      isFalse,
      reason: 'router changed before next frame',
    );
    await tester.pumpAndSettle();
    expect(model.stops, 1);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(model.plays, ['voice-one']);
    expect(stop('voice-one'), findsNothing);
  });

  testWidgets('leaving chat for Settings stops the play in the real shell', (
    tester,
  ) async {
    final model = _Model()
      ..selectedConversationId = null
      ..themeMode = ThemeMode.light;
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pumpAndSettle();
    await tester.tap(play('voice-one'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(model.stops, 1);
    expect(model.viewGuard!(), isFalse);
    expect(find.byType(ChatPane), findsNothing);
  });
}
