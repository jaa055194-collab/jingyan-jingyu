import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/features/voice/voice_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

Map<String, Object?> _profileJson() => {
  'aiId': 'profile-1',
  'provider': 'vendor-a',
  'model': 'model-x',
  'voiceId': 'voice-1',
  'params': {'speed': 1.0},
  'revision': 2,
  'consentRef': 'consent-1',
  'activatedAt': '2026-11-17T00:00:00.000Z',
  'pendingRevision': 3,
  'pendingParams': {'pitch': 1.0},
};

VoiceProfileView _profile() =>
    VoiceProfileView.fromJson(_profileJson(), expectedAiId: 'profile-1');

void main() {
  Future<void> pumpScreen(
    WidgetTester tester,
    Future<VoiceProfileView> Function(String aiId)? loadProfile,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: VoiceScreen(loadProfile: loadProfile)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('read-only profile renders and never shows parameter values', (
    tester,
  ) async {
    await pumpScreen(tester, (aiId) async {
      expect(aiId, 'profile-1');
      return _profile();
    });
    await tester.enterText(find.byKey(const Key('voice-ai-id')), 'profile-1');
    await tester.tap(find.byKey(const Key('voice-read')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('voice-profile')), findsOneWidget);
    expect(find.textContaining('provider：vendor-a'), findsOneWidget);
    expect(find.textContaining('model：model-x'), findsOneWidget);
    expect(find.textContaining('voiceId：voice-1'), findsOneWidget);
    expect(find.textContaining('revision：2'), findsOneWidget);
    expect(find.textContaining('待生效 revision：3'), findsOneWidget);
    expect(find.textContaining('参数键：speed'), findsOneWidget);
    // Parameter values and any secret material must not be rendered.
    expect(find.textContaining('1.0'), findsNothing);
    // No ticket/token UI is exposed; only the profile is shown.
    expect(find.textContaining('token'), findsNothing);
    expect(find.textContaining('Token'), findsNothing);
  });

  testWidgets(
    'host not-found is reported as missing, not as a configured profile',
    (tester) async {
      await pumpScreen(tester, (aiId) async {
        throw const HostRequestException(
          Failure(FailureCode.notFound, 'no profile'),
        );
      });
      await tester.enterText(find.byKey(const Key('voice-ai-id')), 'profile-1');
      await tester.tap(find.byKey(const Key('voice-read')));
      await tester.pumpAndSettle();

      expect(find.textContaining('未配置音色档案'), findsOneWidget);
      expect(find.textContaining('不是权限问题'), findsOneWidget);
      expect(find.byKey(const Key('voice-profile')), findsNothing);
    },
  );

  for (final code in [FailureCode.forbidden, FailureCode.unauthenticated]) {
    testWidgets('$code is reported as denied', (tester) async {
      await pumpScreen(tester, (aiId) async {
        throw HostRequestException(Failure(code, 'denied'));
      });
      await tester.enterText(find.byKey(const Key('voice-ai-id')), 'profile-1');
      await tester.tap(find.byKey(const Key('voice-read')));
      await tester.pumpAndSettle();

      expect(find.textContaining('无权读取'), findsOneWidget);
      expect(find.byKey(const Key('voice-profile')), findsNothing);
    });
  }

  testWidgets('malformed response is a safe unknown without leaking details', (
    tester,
  ) async {
    await pumpScreen(tester, (aiId) async {
      throw const FormatException('secret-detail-xyz');
    });
    await tester.enterText(find.byKey(const Key('voice-ai-id')), 'profile-1');
    await tester.tap(find.byKey(const Key('voice-read')));
    await tester.pumpAndSettle();

    expect(find.textContaining('状态未知'), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
    expect(find.byKey(const Key('voice-profile')), findsNothing);
  });

  testWidgets('no host connection loader disables reading and stays honest', (
    tester,
  ) async {
    await pumpScreen(tester, null);
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('voice-read')),
    );
    expect(button.onPressed, isNull);
    expect(find.byKey(const Key('voice-ai-id')), findsOneWidget);
  });

  testWidgets(
    'voice polish: help text explains id sourcing and metadata-only scope',
    (tester) async {
      await pumpScreen(tester, null);
      expect(find.byKey(const Key('voice-help')), findsOneWidget);
      expect(find.textContaining('ai_'), findsOneWidget);
      expect(find.textContaining('不代表音色可用'), findsOneWidget);
      expect(find.textContaining('当前入口未接线宿主连接'), findsOneWidget);
      // The entry help text (settings) explains why the id is explicit.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SettingsScreen(model: TestShellModel(), onBack: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('open-voice-profile'));
      await tester.scrollUntilVisible(entry, 300);
      await tester.pumpAndSettle();
      expect(find.textContaining('宿主按档案而非账户寻址'), findsOneWidget);
      expect(find.textContaining('仅元数据'), findsOneWidget);
    },
  );

  testWidgets('settings developer entry opens the read-only voice screen', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: TestShellModel(), onBack: () {}),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final entry = find.byKey(const Key('open-voice-profile'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.text('语音音色'), findsOneWidget);
    // Test model is not the runtime: no connection, reading disabled.
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('voice-read')))
          .onPressed,
      isNull,
    );
  });
}
