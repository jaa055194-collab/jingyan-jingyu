import 'dart:async';

import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/features/world/world_status_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

WorldStatusSnapshot _snapshot() => const WorldStatusSnapshot('home', [
  WorldSection('世界布局', WorldReadStatus.present, [
    '空间：home · 版本 3',
    '风格：warm',
    '房间 1 个',
    '· 客厅（2 件家具）',
  ]),
  WorldSection('在场', WorldReadStatus.missing, ['未找到（可能不存在或不可见）']),
  WorldSection('形象', WorldReadStatus.denied, ['未认证或无权限']),
]);

Future<void> _pump(
  WidgetTester tester,
  Future<WorldStatusSnapshot> Function(String spaceId)? load, {
  String initialSpaceId = '',
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: WorldStatusScreen(initialSpaceId: initialSpaceId, load: load),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders read-only sections with honest present/missing/denied', (
    tester,
  ) async {
    await _pump(tester, (spaceId) async => _snapshot());
    expect(find.textContaining('不做 3D 渲染'), findsOneWidget);
    expect(find.textContaining('密钥'), findsOneWidget);
    expect(find.byKey(const Key('world-section-世界布局')), findsOneWidget);
    expect(find.byKey(const Key('world-section-在场')), findsOneWidget);
    expect(find.byKey(const Key('world-section-形象')), findsOneWidget);
    expect(find.text('已读取'), findsOneWidget);
    expect(find.text('未找到'), findsOneWidget);
    expect(find.text('无权限'), findsOneWidget);
    expect(find.textContaining('客厅'), findsOneWidget);
  });

  testWidgets('null loader shows unknown and disables refresh', (tester) async {
    await _pump(tester, null);
    expect(find.byKey(const Key('world-status-unknown')), findsOneWidget);
    expect(find.textContaining('未知不代表已配置'), findsWidgets);
    final refresh = tester.widget<TextButton>(
      find.byKey(const Key('world-status-refresh')),
    );
    expect(refresh.onPressed, isNull);
  });

  testWidgets('loader failure becomes unknown without leaking details', (
    tester,
  ) async {
    await _pump(
      tester,
      (_) async => throw const HostRequestException(
        Failure(FailureCode.unavailable, 'transport detail secret-token'),
      ),
    );
    expect(find.byKey(const Key('world-status-unknown')), findsOneWidget);
    expect(find.textContaining('secret-token'), findsNothing);
  });

  testWidgets('passes trimmed space id and shows loading until completion', (
    tester,
  ) async {
    String? seen;
    var calls = 0;
    final completer = Completer<WorldStatusSnapshot>();
    await tester.pumpWidget(
      MaterialApp(
        home: WorldStatusScreen(
          load: (spaceId) {
            seen = spaceId;
            calls++;
            // Let the initial load settle so the refresh button is enabled.
            return calls == 1 ? Future.value(_snapshot()) : completer.future;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(seen, isEmpty);
    await tester.enterText(find.byKey(const Key('world-space-id')), '  home  ');
    await tester.tap(find.byKey(const Key('world-status-refresh')));
    await tester.pump();
    expect(seen, 'home');
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(_snapshot());
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('已读取'), findsOneWidget);
  });

  testWidgets('settings exposes one world status entry and opens the screen', (
    tester,
  ) async {
    final model = TestShellModel()
      ..connectedAccountId = 'owner'
      ..online = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: model,
          builder: (_, _) => Scaffold(
            body: SettingsScreen(model: model, onBack: () {}),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('open-world-status')),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-world-status')));
    await tester.pumpAndSettle();
    expect(find.byType(WorldStatusScreen), findsOneWidget);
    // TestShellModel is not a ClientRuntime, so no connection -> honest unknown.
    expect(find.byKey(const Key('world-status-unknown')), findsOneWidget);
  });
}
