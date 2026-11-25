import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const preferencesProfile = 'profile-a';
const otherPreferencesProfile = 'profile-b';
const preferencesRegister = '/api/v1/ai-profiles/register';
String preferencesPath(String profile) =>
    '/api/v1/ai-profiles/$profile/owner-reply-preferences';

const syntheticTarget = <String, Object?>{
  'providerId': 'fixture-provider',
  'model': 'fixture-chat-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'fixture-target-A',
};

Map<String, Object?> preferenceReply({
  int revision = 0,
  bool enabled = false,
  String? length,
  String? format,
  Map<String, Object?>? target = syntheticTarget,
}) => {
  'revision': revision,
  'enabled': enabled,
  'length': length,
  'format': format,
  'target': target,
};

/// Fixture at the host boundary only: the production Settings/profile resolve,
/// adapter and editor still run. Nothing calls an external provider.
class PreferencesConnection extends HostConnection {
  PreferencesConnection()
    : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final calls = <(String method, String path)>[];
  final writes = <Map<String, Object?>>[];
  final states = <String, Map<String, Object?>>{
    preferencesProfile: preferenceReply(),
    otherPreferencesProfile: preferenceReply(target: null),
  };
  Future<Map<String, Object?>> Function(String profile)? read;
  Future<Map<String, Object?>> Function(String profile, Map<String, Object?>)?
  write;

  String _profile(String path) {
    final profile = path.split('/')[4];
    expect(path, preferencesPath(profile));
    expect(states, contains(profile));
    return profile;
  }

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    calls.add(('GET', path));
    final profile = _profile(path);
    final handler = read;
    return handler == null ? states[profile]! : await handler(profile);
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    calls.add((method, path));
    if (method == 'POST' && path == preferencesRegister) {
      final ai = body!['accountId']! as String;
      expect(ai, anyOf('ai-a', 'ai-b'));
      return {
        'accountId': ai,
        'ownerAccountId': 'fixture-owner',
        'profileId': 'profile-${ai.substring(3)}',
      };
    }
    expect(method, 'PUT');
    expect(retryAuthentication, isFalse);
    expect(body, isNotNull);
    final profile = _profile(path);
    writes.add(Map.unmodifiable(body!));
    final handler = write;
    return handler == null
        ? applyWrite(profile, body)
        : await handler(profile, body);
  }

  Map<String, Object?> applyWrite(String profile, Map<String, Object?> body) {
    expect(
      body.keys,
      unorderedEquals([
        'expectedRevision',
        'enabled',
        'length',
        'format',
        'expectedTargetToken',
      ]),
    );
    final current = states[profile]!;
    expect(body['expectedRevision'], current['revision']);
    final target = current['target'] as Map<String, Object?>?;
    final enabled = body['enabled']! as bool;
    expect(body['expectedTargetToken'], enabled ? target!['token'] : null);
    final result = preferenceReply(
      revision: (current['revision']! as int) + 1,
      enabled: enabled,
      length: body['length'] as String?,
      format: body['format'] as String?,
      target: target,
    );
    states[profile] = result;
    return result;
  }
}

class PreferencesRuntime extends ClientRuntime {
  PreferencesRuntime(PreferencesConnection host) {
    connection = host;
  }

  bool fixtureLocked = false;
  bool fixtureOnline = true;
  String? fixtureOwner = 'fixture-owner';
  Object fixtureLockEpoch = Object();
  int fixtureSessionEpoch = 1;

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => fixtureOnline;
  @override
  bool get locked => fixtureLocked;
  @override
  String? get connectedAccountId => fixtureOwner;
  @override
  Object? get ownAiDirectContext =>
      authenticated && !locked ? fixtureLockEpoch : null;
  @override
  Object? get ownAiSessionContext => authenticated ? fixtureSessionEpoch : null;
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(accountId: 'ai-a', displayName: '示例 A', disabled: false),
    ShellOwnedAi(accountId: 'ai-b', displayName: '示例 B', disabled: false),
  ];

  void changeView({bool? lock, bool? online, bool replaceSession = false}) {
    if (lock != null) {
      fixtureLocked = lock;
      fixtureLockEpoch = Object();
    }
    if (online != null) fixtureOnline = online;
    if (replaceSession) fixtureSessionEpoch++;
    notifyListeners();
  }
}

Finder preferenceKey(String value) => find.byKey(Key(value));

Future<void> tapPreference(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final finder = preferenceKey(key);
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> openPreferencesEditor(
  WidgetTester tester,
  PreferencesRuntime runtime, {
  Key? boundary,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: WhaleChatApp(model: runtime),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  final open = preferenceKey('open-ai-config-write');
  await tester.scrollUntilVisible(
    open,
    280,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.tap(open);
  await tester.pumpAndSettle();
  expect(find.text('档案：profile-a'), findsOneWidget);
}

Future<void> choosePreferencesAi(WidgetTester tester, String ai) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  // Avoid pumpAndSettle while the previous profile has a pending read.
  await tester.pump();
  await tapPreference(tester, 'ai-config-write-select', settle: false);
  await tester.pump(const Duration(milliseconds: 350));
  await tester.tap(find.text(ai).last);
  await tester.pumpAndSettle();
}
