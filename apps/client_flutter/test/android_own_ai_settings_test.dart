import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/ai_config/ai_config_editor.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'test-token');

  final requests = <(String, String)>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    requests.add((method, path));
    throw StateError('Opening Settings must not contact the host');
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection host) {
    connection = host;
  }

  var interaction = Object();

  @override
  String get connectedAccountId => 'test-owner';
  @override
  Object get ownAiSessionContext => 1;
  @override
  Object get ownAiDirectContext => interaction;
  @override
  bool get online => true;
  @override
  bool get ownAiLoaded => true;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(accountId: 'ai-a', displayName: 'Nora', disabled: false),
    ShellOwnedAi(accountId: 'ai-b', displayName: 'Jo', disabled: false),
    ShellOwnedAi(accountId: 'ai-c', displayName: 'Lin', disabled: true),
  ];
}

Future<void> _open(
  WidgetTester tester,
  _Runtime runtime,
  TargetPlatform platform,
) async {
  addTearDown(runtime.dispose);
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(375, 812);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SettingsScreen(model: runtime, onBack: () {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Android Settings leads to the selected AI without a host write',
    (tester) async {
      final host = _Connection();
      await _open(tester, _Runtime(host), TargetPlatform.android);
      expect(find.text('我的 AI 配置'), findsOneWidget);
      final directory = find.byKey(const Key('open-android-ai-directory'));
      await tester.ensureVisible(directory);
      await tester.tap(directory);
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('android-ai-open-config-ai-b'));
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();

      final editor = tester.widget<AiConfigEditor>(find.byType(AiConfigEditor));
      expect(editor.ownedAiAccountIds, ['ai-b']);
      expect(editor.androidDetails?.aiLabel, 'Jo');
      expect(editor.socialLevel, isNotNull);
      expect(host.requests, isEmpty);
      expect(find.text('读取配置'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'an Android row rendered before interaction invalidation cannot open',
    (tester) async {
      final host = _Connection();
      final runtime = _Runtime(host);
      await _open(tester, runtime, TargetPlatform.android);
      final directory = find.byKey(const Key('open-android-ai-directory'));
      await tester.ensureVisible(directory);
      await tester.tap(directory);
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('android-ai-open-config-ai-b'));
      await tester.ensureVisible(entry);
      // Invalidate after render, before a queued tap can use the old row.
      runtime.interaction = Object();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.byType(AiConfigEditor), findsNothing);
      expect(host.requests, isEmpty);
    },
  );

  testWidgets(
    'Windows keeps its existing Settings and has no Android AI links',
    (tester) async {
      final host = _Connection();
      await _open(tester, _Runtime(host), TargetPlatform.windows);
      expect(find.text('我的 AI'), findsNothing);
      final previousRow = find.text('Jo · 未停用');
      await tester.scrollUntilVisible(
        previousRow,
        220,
        scrollable: find.byType(Scrollable).first,
      );
      expect(previousRow, findsOneWidget);
      expect(find.widgetWithText(ListTile, 'Jo'), findsNothing);
      expect(host.requests, isEmpty);
    },
  );
}
