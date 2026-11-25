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

class _ConfigConnection extends _Connection {
  static const _profile = '/api/v1/ai-profiles/profile-b';
  static const _identity = {
    'profileId': 'profile-b',
    'accountId': 'ai-b',
    'ownerAccountId': 'test-owner',
  };
  final socialWrites = <Map<String, Object?>>[];
  String _level = 'L3';

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
    return switch ((method, path)) {
      ('POST', '/api/v1/ai-profiles/register')
          when body?['accountId'] == 'ai-b' =>
        _identity,
      ('GET', _profile) => _identity,
      ('GET', '$_profile/persona') => const {
        'aiId': 'profile-b',
        'version': 4,
        'locked': false,
        'layers': {
          'p0': {'name': 'Jo'},
          'p1': {'tone': 'Calm'},
          'p2': {'mood': 'Curious'},
        },
      },
      _ => throw StateError('Unexpected $method $path'),
    };
  }

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    requests.add((method, path));
    if (method == 'GET' && path == '$_profile/bindings') return const [];
    throw StateError('Unexpected $method $path');
  }

  @override
  Future<Map<String, Object?>> requestBoundedObject(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    required int maxResponseBytes,
    required int expectedStatus,
    HostReadCancellation? cancellation,
  }) async {
    requests.add((method, path));
    if (path != '$_profile/social-level' ||
        (method != 'GET' && method != 'PUT')) {
      throw StateError('Unexpected $method $path');
    }
    if (method == 'PUT') {
      socialWrites.add(Map.of(body!));
      _level = body['level']! as String;
    }
    return {
      'configurationRequired': false,
      'level': _level,
      'updatedAt': '2026-01-01T00:00:00.000Z',
    };
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection host) {
    connection = host;
  }

  var interaction = Object();

  void tick() => notifyListeners();

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
    ListenableBuilder(
      listenable: runtime,
      // Match the shell's MaterialApp rebuild on runtime notifications.
      builder: (_, _) => MaterialApp(
        home: Scaffold(
          body: SettingsScreen(model: runtime, onBack: () {}),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, String key) async {
  final button = find.byKey(Key(key));
  await tester.ensureVisible(button);
  await tester.tap(button);
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

  testWidgets('Android social level remains editable after a shell rebuild', (
    tester,
  ) async {
    final host = _ConfigConnection();
    final runtime = _Runtime(host);
    await _open(tester, runtime, TargetPlatform.android);
    await _tap(tester, 'open-android-ai-directory');
    await _tap(tester, 'android-ai-open-config-ai-b');
    expect(host.requests, isEmpty);

    await _tap(tester, 'android-ai-config-read');
    expect(find.textContaining('版本 4'), findsOneWidget);
    await _tap(tester, 'owner-social-level-read');
    final l3 = find.byKey(const Key('owner-social-level-L3'));
    expect(tester.widget<ChoiceChip>(l3).selected, isTrue);

    // The same signed-in, unlocked session refreshed on the device. The
    // navigator rebuilds the route's page; the saved L3 must remain visible.
    runtime.tick();
    await tester.pumpAndSettle();
    expect(l3, findsOneWidget);
    expect(tester.widget<ChoiceChip>(l3).selected, isTrue);
    await _tap(tester, 'owner-social-level-L2');
    runtime.tick();
    await tester.pumpAndSettle();
    await _tap(tester, 'owner-social-level-save');

    expect(host.socialWrites, [
      {'level': 'L2'},
    ]);
    expect(find.text('已保存：L2 友好'), findsOneWidget);
    expect(
      host.requests.where((request) => request.$2.endsWith('/social-level')),
      [
        ('GET', '/api/v1/ai-profiles/profile-b/social-level'),
        ('PUT', '/api/v1/ai-profiles/profile-b/social-level'),
      ],
    );
  });

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
