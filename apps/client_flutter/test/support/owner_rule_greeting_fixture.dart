import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const greetingAiA = 'ai-a';
const greetingAiB = 'ai-b';
const greetingProfileA = 'profile-a';
const greetingProfileB = 'profile-b';
const greetingRegister = '/api/v1/ai-profiles/register';
const greetingGlobalPath = '/api/v1/accounts/me/owner-rule-greetings';
String greetingPath(String profile) =>
    '/api/v1/ai-profiles/$profile/owner-rule-greeting';

Map<String, Object?> greetingJson({
  int revision = 0,
  bool enabled = false,
  int localMinute = 540,
  int? offsetMinutes,
  int quietStartMinute = 1380,
  int quietEndMinute = 480,
  String? socialLevel = 'L3',
  int? chatRevision = 1,
  bool budgetReady = true,
}) => {
  'revision': revision,
  'enabled': enabled,
  'localMinute': localMinute,
  'offsetMinutes': offsetMinutes,
  'quietStartMinute': quietStartMinute,
  'quietEndMinute': quietEndMinute,
  'globalBlocked': false,
  'globalRevision': 0,
  'socialLevel': socialLevel,
  'chatRevision': chatRevision,
  'budgetReady': budgetReady,
  'lastSentAt': null,
};

/// Only the host boundary is synthetic; production routes/profile resolution,
/// receipt validation, session retirement and UI callbacks are exercised.
class GreetingConnection extends HostConnection {
  GreetingConnection()
    : super(Uri.parse('http://greeting.invalid'), 'synthetic');
  final calls = <(String method, String path)>[];
  final writes = <(String path, Map<String, Object?> body)>[];
  final settings = <String, Map<String, Object?>>{
    greetingProfileA: greetingJson(),
    greetingProfileB: greetingJson(
      socialLevel: 'L0',
      chatRevision: null,
      budgetReady: false,
    ),
  };
  Map<String, Object?> global = {'revision': 0, 'blocked': false};
  Future<Map<String, Object?>> Function(String profile)? beforeSettingsRead;
  Future<Map<String, Object?>> Function()? beforeGlobalRead;
  Future<Map<String, Object?>> Function(Map<String, Object?> body)?
  beforeGlobalWrite;
  Future<Map<String, Object?>> Function(
    String profile,
    Map<String, Object?> body,
  )?
  beforeSettingsWrite;

  static const conflict = HostRequestException(
    Failure(FailureCode.conflict, 'synthetic private detail'),
  );

  Map<String, Object?> _snapshot(String profile) => {
    ...settings[profile]!,
    'globalBlocked': global['blocked'],
    'globalRevision': global['revision'],
  };

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
    if (method == 'POST' && path == greetingRegister) {
      final account = body!['accountId'];
      expect(account, anyOf(greetingAiA, greetingAiB));
      return {
        'accountId': account,
        'ownerAccountId': 'greeting-owner',
        'profileId': account == greetingAiA
            ? greetingProfileA
            : greetingProfileB,
      };
    }
    expect(retryAuthentication, isFalse);
    if (method == 'PUT') writes.add((path, Map.unmodifiable(body!)));
    if (path == greetingGlobalPath) {
      if (method == 'GET') return beforeGlobalRead?.call() ?? global;
      expect(method, 'PUT');
      final handler = beforeGlobalWrite;
      if (handler != null) return handler(body!);
      if (body!['expectedRevision'] != global['revision']) throw conflict;
      global = {
        'revision': (global['revision']! as int) + 1,
        'blocked': body['blocked'],
      };
      if (global['blocked'] == true) {
        for (final state in settings.values.where(
          (row) => row['enabled'] == true,
        )) {
          state['enabled'] = false;
          state['revision'] = (state['revision']! as int) + 1;
        }
      }
      return global;
    }
    final profile = path.split('/')[4];
    expect(settings, contains(profile));
    expect(path, greetingPath(profile));
    if (method == 'GET') {
      return beforeSettingsRead?.call(profile) ?? _snapshot(profile);
    }
    expect(method, 'PUT');
    final handler = beforeSettingsWrite;
    if (handler != null) return handler(profile, body!);
    final current = settings[profile]!;
    final enabled = body!['enabled']! as bool;
    if (body['expectedRevision'] != current['revision'] ||
        (enabled &&
            (global['blocked'] == true ||
                current['budgetReady'] != true ||
                !const {'L3', 'L4'}.contains(current['socialLevel']) ||
                current['chatRevision'] == null ||
                body['expectedChatRevision'] != current['chatRevision'] ||
                body['expectedGlobalRevision'] != global['revision']))) {
      throw conflict;
    }
    for (final key in [
      'enabled',
      'localMinute',
      'offsetMinutes',
      'quietStartMinute',
      'quietEndMinute',
    ]) {
      current[key] = body[key];
    }
    current['revision'] = (current['revision']! as int) + 1;
    return _snapshot(profile);
  }
}

class GreetingRuntime extends ClientRuntime {
  GreetingRuntime(GreetingConnection host) {
    connection = host;
  }
  final ais = <ShellOwnedAi>[
    const ShellOwnedAi(
      accountId: greetingAiA,
      displayName: '问候示例 A',
      disabled: false,
    ),
    const ShellOwnedAi(
      accountId: greetingAiB,
      displayName: '问候示例 B',
      disabled: false,
    ),
  ];
  bool fixtureLocked = false;
  bool fixtureOnline = true;
  int fixtureEpoch = 1;
  Object fixtureLockEpoch = Object();

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
  String? get connectedAccountId => 'greeting-owner';
  @override
  Object? get ownAiDirectContext =>
      authenticated && !locked ? fixtureLockEpoch : null;
  @override
  Object? get ownAiSessionContext => authenticated ? fixtureEpoch : null;
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
  @override
  List<ShellOwnedAi> get ownAiAccounts => ais;

  void changeSession({bool? lock, bool? online, bool replaceSession = false}) {
    if (lock != null) {
      fixtureLocked = lock;
      fixtureLockEpoch = Object();
    }
    if (online != null) fixtureOnline = online;
    if (replaceSession) fixtureEpoch++;
    notifyListeners();
  }
}

Finder greetingKey(String id) => find.byKey(Key(id));

Future<void> tapGreeting(
  WidgetTester t,
  String id, {
  bool settle = true,
}) async {
  final finder = greetingKey(id);
  expect(finder, findsOneWidget);
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  if (settle) {
    await t.pumpAndSettle();
  } else {
    await t.pump();
  }
}

Future<void> openGreetingSettings(
  WidgetTester t,
  GreetingRuntime runtime, {
  Key? boundary,
}) async {
  await t.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: WhaleChatApp(model: runtime),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(find.byTooltip('设置'));
  await t.pumpAndSettle();
}

Future<void> openGreetingEditor(WidgetTester t) async {
  await t.scrollUntilVisible(
    greetingKey('open-ai-config-write'),
    280,
    scrollable: find.byType(Scrollable).first,
  );
  await tapGreeting(t, 'open-ai-config-write');
  expect(find.text('档案：profile-a'), findsOneWidget);
}

Future<void> openGreetingGlobal(WidgetTester t) async {
  await t.scrollUntilVisible(
    greetingKey('open-owner-rule-greeting-global'),
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tapGreeting(t, 'open-owner-rule-greeting-global');
}

Future<void> revealGreetingCard(WidgetTester t) async {
  await t.scrollUntilVisible(
    greetingKey('owner-rule-greeting-read'),
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await t.pumpAndSettle();
}

Future<void> enterGreeting(WidgetTester t, String key, String text) async {
  final field = greetingKey(key);
  await t.ensureVisible(field);
  await t.enterText(field, text);
  await t.pump();
}
