import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_flutter/app/shell_app.dart';

import 'ui_test.dart'
    show
        TestShellModel,
        enterOnboardingField,
        fillNewAccountCredentials,
        submitHostConnection;

/// Opt-in harness renders, not native-window or live-host acceptance evidence.
/// Copy this unchanged test into exact baseline 7c5405f for the before render.
void main() {
  const capture = bool.fromEnvironment('CAPTURE_CHAT_FIRST');
  const baseline = bool.fromEnvironment('CHAT_FIRST_BASELINE');
  testWidgets('render authenticated optional world setup comparison', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final font = File('${Platform.environment['WINDIR']}/Fonts/msyh.ttc');
    if (font.existsSync()) {
      final bytes = font.readAsBytesSync();
      for (final family in ['Ahem', 'Roboto']) {
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
    }
    final model = TestShellModel()
      ..onboarded = false
      ..themeMode = ThemeMode.light;
    const imageKey = Key('chat-first-render');
    await tester.pumpWidget(
      RepaintBoundary(
        key: imageKey,
        child: WhaleChatApp(model: model),
      ),
    );
    await enterOnboardingField(tester, 'host-address', 'https://host.example');
    await enterOnboardingField(tester, 'host-invite', 'synthetic-invite');
    await fillNewAccountCredentials(tester);
    await submitHostConnection(tester);
    expect(find.text('选择你的形象'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await expectLater(
      find.byKey(imageKey),
      matchesGoldenFile(
        baseline
            ? '../evidence/chat-first-before-7c5405f-step2.png'
            : '../evidence/chat-first-after-step2.png',
      ),
    );
    if (!baseline) {
      await tester.tap(find.byKey(const Key('defer-world-setup')));
      await tester.pumpAndSettle();
      expect(find.text('好友'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byKey(imageKey),
        matchesGoldenFile('../evidence/chat-first-after-chat.png'),
      );
    }
  }, skip: !capture);
}
