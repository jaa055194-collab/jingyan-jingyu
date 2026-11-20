import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// In-memory HostConnection double: real request plumbing, canned responses.
/// Widget tests run under fake async, so a loopback socket cannot be used.
class _CannedConnection extends HostConnection {
  _CannedConnection({this.waitForReports})
    : super(Uri.parse('http://canned.invalid'), 'fixture');

  final Future<void>? waitForReports;
  final paths = <String>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    expect(method, 'GET');
    expect(body, isNull);
    expect(path, anyOf('/api/v1/creative/reports', '/api/v1/creative/radio'));
    paths.add(path);
    if (path == '/api/v1/creative/reports') await waitForReports;
    return path == '/api/v1/creative/reports'
        ? {
            'reports': [
              {
                'aiId': 'ai-profile',
                'kind': 'weekly',
                'periodKey': '2026-11-15',
                'status': 'generated',
                'report': _report(),
              },
            ],
          }
        : {
            'episodes': [_episode()],
          };
  }
}

/// Minimal runtime double that only supplies what the shell needs and an
/// explicit live connection, so the 动态 wiring path runs for real.
class _ConnectedShell extends ClientRuntime {
  _ConnectedShell(HostConnection live) {
    connection = live;
  }

  @override
  bool get ready => true;
  @override
  bool get busy => false;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool locked = false;
  @override
  bool get online => true;
  @override
  String? get error => null;
  @override
  String? connectedAccountId = 'owner';
  @override
  Object? ownAiSessionContext = Object();

  void interrupt(String interruption) {
    switch (interruption) {
      case 'lock':
        locked = true;
      case 'logout':
        connectedAccountId = null;
      case 'account':
        connectedAccountId = 'replacement-owner';
      case 'session':
        ownAiSessionContext = Object();
    }
    notifyListeners();
  }

  @override
  String? get selectedConversationId => null;
  @override
  List<ShellConversation> get conversations => const [];
  @override
  List<ShellMessage> get messages => const [];
  @override
  int get queuedCount => 0;
  @override
  String get draft => '';
  @override
  bool get aiConsentGranted => false;
  @override
  bool get appLockEnabled => false;
  @override
  bool get hideNotificationBody => false;
  @override
  bool get autoStart => false;
  @override
  ThemeMode get themeMode => ThemeMode.system;
  @override
  double get fontScale => 1;
  @override
  String? get roomPreview => null;
  @override
  bool get canAddMembersToSelectedGroup => false;
  @override
  bool get canMentionAi => false;
}

Map<String, Object?> _report() => {
  'kind': 'weekly',
  'periodKey': '2026-11-15',
  'windowStartDay': '2026-11-09',
  'windowEndDay': '2026-11-15',
  'generatedAt': '2026-11-15T13:31:00.000Z',
  'commonTopics': [
    {'label': '旅行', 'count': 3},
  ],
  'completedAgreements': 1,
  'checkinDays': 2,
  'moodCurve': {'2026-11-11': 4.0},
  'letter': '这一周我们聊了很多。',
  'keywords': <Object?>[],
  'milestones': <Object?>[],
  'busiestDay': null,
  'sourceScopes': ['privateChat'],
};

Map<String, Object?> _episode() => {
  'aiId': 'ai-profile',
  'dateKey': '2026-11-16',
  'scheduledFor': '2026-11-16T15:00:00.000Z',
  'generatedAt': '2026-11-16T14:50:00.000Z',
  'voiceId': 'voice-1',
  'offlineCacheKey': 'cache/2026-11-16',
  'playableOffline': true,
  'script': {
    'text': '晚安。',
    'segments': [
      {'kind': 'comfort', 'text': '晚安。'},
    ],
  },
};

void main() {
  testWidgets('without a runtime connection the 动态 tab stays honest unknown', (
    tester,
  ) async {
    await tester.pumpWidget(WhaleChatApp(model: TestShellModel()));
    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();
    expect(find.textContaining('创作内容需要接入宿主连接后显示'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('with a runtime connection the 动态 tab loads reports and radio', (
    tester,
  ) async {
    final connection = _CannedConnection();
    addTearDown(connection.close);
    final model = _ConnectedShell(connection);
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('动态'));
    await tester.pumpAndSettle();
    expect(find.text('周报 · 2026-11-15'), findsOneWidget);
    expect(find.text('2026-11-16'), findsOneWidget);
    expect(find.textContaining('可离线播放'), findsOneWidget);
    expect(find.textContaining('创作内容需要接入宿主连接后显示'), findsNothing);
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('production 动态 opens the stored report at $width px', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 960));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final connection = _CannedConnection();
      addTearDown(connection.close);
      final model = _ConnectedShell(connection);
      await tester.pumpWidget(WhaleChatApp(model: model));
      expect(connection.paths, isEmpty, reason: 'no blind load from chat');
      await tester.tap(find.text('动态'));
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsNothing);
      await tester.tap(find.text('周报 · 2026-11-15'));
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsOneWidget);
      expect(connection.paths, [
        '/api/v1/creative/reports',
        '/api/v1/creative/radio',
      ]);
      expect(tester.takeException(), isNull);
    });
  }

  for (final interruption in ['lock', 'logout', 'account', 'session']) {
    testWidgets('production shell clears open report on $interruption', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(1280, 960));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final connection = _CannedConnection();
      addTearDown(connection.close);
      final model = _ConnectedShell(connection);
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.text('动态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('周报 · 2026-11-15'));
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsOneWidget);

      // Notify before the next frame, then restore the original context. The
      // interruption still invalidated the old disclosure and its fetched data.
      final account = model.connectedAccountId;
      final epoch = model.ownAiSessionContext;
      model.interrupt(interruption);
      model
        ..connectedAccountId = account
        ..ownAiSessionContext = epoch
        ..locked = false
        ..notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('这一周我们聊了很多。'), findsNothing);
      expect(find.text('周报 · 2026-11-15'), findsNothing);
      expect(connection.paths, hasLength(2), reason: 'no implicit reload');
    });

    testWidgets(
      'production shell ignores a late list response on $interruption',
      (tester) async {
        final gate = Completer<void>();
        final connection = _CannedConnection(waitForReports: gate.future);
        addTearDown(connection.close);
        final model = _ConnectedShell(connection);
        await tester.pumpWidget(WhaleChatApp(model: model));
        await tester.tap(find.text('动态'));
        await tester.pump();
        expect(connection.paths, ['/api/v1/creative/reports']);
        model.interrupt(interruption);
        await tester.pump();
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('周报 · 2026-11-15'), findsNothing);
        expect(connection.paths, ['/api/v1/creative/reports']);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
