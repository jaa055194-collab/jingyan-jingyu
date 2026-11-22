import 'package:client_flutter/features/ai_config/owner_model_proactive_card.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_model_proactive_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _ai = 'profile-a';
const _settingsPath = '/api/v1/ai-profiles/profile-a/owner-model-proactive';
const _globalPath = '/api/v1/accounts/me/owner-model-proactive';

Map<String, Object?> settingsJson({
  int revision = 0,
  bool enabled = false,
  int localMinute = 540,
  int? offsetMinutes,
  int quietStartMinute = 1380,
  int quietEndMinute = 480,
  int intervalMinutes = 1440,
  bool globalBlocked = false,
  int globalRevision = 0,
  String? socialLevel = 'L3',
  int? chatRevision = 1,
  bool budgetReady = true,
  String? lastSentAt,
}) => {
  'revision': revision,
  'enabled': enabled,
  'localMinute': localMinute,
  'offsetMinutes': offsetMinutes,
  'quietStartMinute': quietStartMinute,
  'quietEndMinute': quietEndMinute,
  'intervalMinutes': intervalMinutes,
  'globalBlocked': globalBlocked,
  'globalRevision': globalRevision,
  'socialLevel': socialLevel,
  'chatRevision': chatRevision,
  'budgetReady': budgetReady,
  'lastSentAt': lastSentAt,
};

class _ProactiveConnection extends HostConnection {
  _ProactiveConnection()
    : super(Uri.parse('http://proactive.invalid'), 'synthetic');

  final calls = <(String method, String path)>[];
  final writes = <(String path, Map<String, Object?> body)>[];
  Map<String, Object?> settings = settingsJson();
  Map<String, Object?> global = {'revision': 0, 'blocked': false};

  static const conflict = HostRequestException(
    Failure(FailureCode.conflict, 'synthetic private detail'),
  );

  Map<String, Object?> _snapshot() => {
    ...settings,
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
    expect(retryAuthentication, isFalse);
    if (path == _globalPath) {
      if (method == 'GET') return global;
      expect(method, 'PUT');
      writes.add((path, Map.unmodifiable(body!)));
      if (body['expectedRevision'] != global['revision']) throw conflict;
      global = {
        'revision': (global['revision']! as int) + 1,
        'blocked': body['blocked'],
      };
      if (global['blocked'] == true && settings['enabled'] == true) {
        settings['enabled'] = false;
        settings['revision'] = (settings['revision']! as int) + 1;
      }
      return global;
    }
    expect(path, _settingsPath);
    if (method == 'GET') return _snapshot();
    expect(method, 'PUT');
    writes.add((path, Map.unmodifiable(body!)));
    final enabled = body['enabled']! as bool;
    if (body['expectedRevision'] != settings['revision'] ||
        (enabled &&
            (global['blocked'] == true ||
                settings['budgetReady'] != true ||
                !const {'L3', 'L4'}.contains(settings['socialLevel']) ||
                settings['chatRevision'] == null ||
                body['expectedChatRevision'] != settings['chatRevision'] ||
                body['expectedGlobalRevision'] != global['revision']))) {
      throw conflict;
    }
    for (final key in [
      'enabled',
      'localMinute',
      'offsetMinutes',
      'quietStartMinute',
      'quietEndMinute',
      'intervalMinutes',
    ]) {
      settings[key] = body[key];
    }
    settings['revision'] = (settings['revision']! as int) + 1;
    return _snapshot();
  }
}

Finder _key(String id) => find.byKey(Key(id));

Future<void> _tap(WidgetTester t, String id) async {
  final finder = _key(id);
  await t.ensureVisible(finder);
  await t.pump();
  await t.tap(finder);
  await t.pumpAndSettle();
}

Future<void> _enter(WidgetTester t, String id, String text) async {
  final finder = _key(id);
  await t.ensureVisible(finder);
  await t.enterText(finder, text);
  await t.pump();
}

Future<void> _pump(WidgetTester t, _ProactiveConnection host) async {
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: OwnerModelProactiveCard(
            api: OwnerModelProactiveApi(host),
            profileId: _ai,
            aiLabel: '主动示例 A',
            isCurrent: () => true,
            canContactHost: () => true,
          ),
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  late _ProactiveConnection host;
  setUp(() {
    host = _ProactiveConnection();
  });
  tearDown(() async {
    await host.close();
  });

  testWidgets(
    'per-AI opt-in requires review and explicit confirmation of the schedule',
    (t) async {
      await _pump(t, host);
      await _tap(t, 'owner-model-proactive-read');
      expect(find.text('未授权模型主动联系'), findsOneWidget);
      await _enter(t, 'owner-model-proactive-local', '01:30');
      await _enter(t, 'owner-model-proactive-offset', '+08:00');
      await _enter(t, 'owner-model-proactive-interval', '2880');
      await _tap(t, 'owner-model-proactive-review');
      expect(find.textContaining('主动示例 A'), findsWidgets);
      expect(find.textContaining('UTC+08:00'), findsOneWidget);
      expect(find.textContaining('2880'), findsWidgets);
      expect(host.writes, isEmpty);
      await _tap(t, 'owner-model-proactive-cancel');
      expect(host.writes, isEmpty);
      await _tap(t, 'owner-model-proactive-review');
      await _tap(t, 'owner-model-proactive-confirm');
      expect(host.writes.single.$1, _settingsPath);
      expect(host.writes.single.$2, {
        'expectedRevision': 0,
        'enabled': true,
        'localMinute': 90,
        'offsetMinutes': 480,
        'quietStartMinute': 1380,
        'quietEndMinute': 480,
        'intervalMinutes': 2880,
        'expectedChatRevision': 1,
        'expectedGlobalRevision': 0,
      });
      expect(find.text('已授权模型主动联系'), findsOneWidget);
    },
  );

  testWidgets(
    'revocation ignores unsaved form and budget outage and retains settings',
    (t) async {
      host.settings = settingsJson(
        revision: 3,
        enabled: true,
        localMinute: 615,
        offsetMinutes: -330,
        quietStartMinute: 1350,
        quietEndMinute: 420,
        intervalMinutes: 720,
        budgetReady: false,
      );
      await _pump(t, host);
      await _tap(t, 'owner-model-proactive-read');
      expect(find.text('已授权模型主动联系'), findsOneWidget);
      await _enter(t, 'owner-model-proactive-interval', '1440');
      await _tap(t, 'owner-model-proactive-disable');
      expect(host.writes.single.$2, {
        'expectedRevision': 3,
        'enabled': false,
        'localMinute': 615,
        'offsetMinutes': -330,
        'quietStartMinute': 1350,
        'quietEndMinute': 420,
        'intervalMinutes': 720,
        'expectedChatRevision': null,
        'expectedGlobalRevision': null,
      });
      expect(find.text('未授权模型主动联系'), findsOneWidget);
      expect(
        t
            .widget<TextField>(_key('owner-model-proactive-interval'))
            .controller!
            .text,
        '720',
      );
    },
  );

  testWidgets('invalid offset and interval cannot open review', (t) async {
    await _pump(t, host);
    await _tap(t, 'owner-model-proactive-read');
    await _enter(t, 'owner-model-proactive-offset', '+14:01');
    expect(
      t.widget<FilledButton>(_key('owner-model-proactive-review')).onPressed,
      isNull,
    );
    await _enter(t, 'owner-model-proactive-offset', '+00:00');
    await _enter(t, 'owner-model-proactive-interval', '59');
    expect(
      t.widget<FilledButton>(_key('owner-model-proactive-review')).onPressed,
      isNull,
    );
    expect(_key('owner-model-proactive-confirm'), findsNothing);
    expect(host.writes, isEmpty);
  });

  for (final (name, settings, blocked) in [
    ('global stop', settingsJson(offsetMinutes: 0), true),
    ('missing pair', settingsJson(offsetMinutes: 0, chatRevision: null), false),
    ('L2', settingsJson(offsetMinutes: 0, socialLevel: 'L2'), false),
    ('budget', settingsJson(offsetMinutes: 0, budgetReady: false), false),
  ]) {
    testWidgets('$name withholds enable review', (t) async {
      host.settings = settings;
      host.global = {'revision': 2, 'blocked': blocked};
      await _pump(t, host);
      await _tap(t, 'owner-model-proactive-read');
      expect(
        t.widget<FilledButton>(_key('owner-model-proactive-review')).onPressed,
        isNull,
      );
      expect(_key('owner-model-proactive-confirm'), findsNothing);
      expect(host.writes, isEmpty);
    });
  }

  testWidgets(
    'account stop toggle confirms then writes the global stop route',
    (t) async {
      await _pump(t, host);
      await _tap(t, 'owner-model-proactive-read');
      expect(
        t
            .widget<SwitchListTile>(_key('owner-model-proactive-global-stop'))
            .value,
        isFalse,
      );
      await _tap(t, 'owner-model-proactive-global-stop');
      expect(find.text('停止全部模型主动联系？'), findsOneWidget);
      await _tap(t, 'owner-model-proactive-global-confirm');
      expect(host.writes.single.$1, _globalPath);
      expect(host.writes.single.$2, {'expectedRevision': 0, 'blocked': true});
    },
  );
}
