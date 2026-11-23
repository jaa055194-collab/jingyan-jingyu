import 'dart:async';

import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/ai_config/ai_config_editor.dart';
import 'package:client_flutter/net/ai_config_write_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_ai_direct_api.dart';
import 'package:client_flutter/net/owner_ai_readiness_api.dart';
import 'package:client_flutter/net/owner_model_proactive_api.dart';
import 'package:client_flutter/net/owner_reply_preferences_api.dart';
import 'package:client_flutter/net/owner_rule_greeting_api.dart';
import 'package:client_flutter/net/owner_social_level_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

const _profile = '/api/v1/ai-profiles/profile-selected';
const _identity = {
  'profileId': 'profile-selected',
  'accountId': 'ai-selected',
  'ownerAccountId': 'owner',
};
const _original = {
  'aiId': 'profile-selected',
  'version': 7,
  'locked': true,
  'layers': {
    'p0': {'name': '小鲸', 'bio': ' line one\nline=two\t '},
    'p1': {'tone': 'soft\nand calm', 'obsolete': 'will remove'},
    'p2': {'mood': 'quiet'},
  },
};

/// Fixture only at the HTTP boundary; the editor uses real readiness, identity
/// and write adapters (including their guards, parser and payload construction).
class _Host extends HostConnection {
  _Host() : super(Uri.parse('http://localhost'), 'fixture');

  final requests = <(String, String, Map<String, Object?>?, bool)>[];
  final bindingReadStarted = Completer<void>();
  Completer<void>? holdBindings;
  bool providerUnavailable = false;
  bool personaDenied = false;
  bool malformedPatchResponse = false;
  FailureCode? rejectPatch;
  Map<String, Object?>? persona = _original;
  String socialLevel = 'L3';

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
    requests.add((method, path, body, false));
    if (path != '$_profile/social-level') {
      throw StateError('Unexpected bounded fixture request $path');
    }
    if (method == 'PUT') socialLevel = body!['level'] as String;
    return {
      'configurationRequired': false,
      'level': socialLevel,
      'updatedAt': '2026-01-01T00:00:00.000Z',
    };
  }

  Map<String, Object?> _greeting() => {
    'revision': 1,
    'enabled': socialLevel == 'L3',
    'localMinute': 540,
    'offsetMinutes': 480,
    'quietStartMinute': 1380,
    'quietEndMinute': 480,
    'globalBlocked': false,
    'globalRevision': 0,
    'socialLevel': socialLevel,
    'chatRevision': 1,
    'budgetReady': true,
    'lastSentAt': null,
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
    requests.add((method, path, body, retryAuthentication));
    return switch ((method, path)) {
      ('POST', Routes.aiProfileRegister) => _identity,
      ('GET', _profile) => _identity,
      ('GET', '$_profile/persona') =>
        personaDenied
            ? (throw const HostRequestException(
                Failure(FailureCode.forbidden, 'private host detail'),
              ))
            : persona ??
                  (throw const HostRequestException(
                    Failure(FailureCode.notFound, 'absent'),
                  )),
      ('PATCH', '$_profile/persona') => _patch(body!),
      ('GET', '$_profile/owner-rule-greeting') => _greeting(),
      ('GET', '$_profile/owner-model-proactive') => {
        ..._greeting(),
        'intervalMinutes': 1440,
      },
      ('GET', '/api/v1/model-providers/chat-provider') =>
        providerUnavailable
            ? _unavailable()
            : _provider(
                'chat-provider',
                'chat',
                'https://chat.example.test/v1',
              ),
      ('GET', '/api/v1/model-providers/fast-provider') => _provider(
        'fast-provider',
        'chatFast',
        'https://fast.example.test/api',
      ),
      _ => throw StateError('Unexpected fixture request $method $path'),
    };
  }

  Never _unavailable() => throw const HostRequestException(
    Failure(FailureCode.unavailable, 'private host detail'),
  );

  Map<String, Object?> _patch(Map<String, Object?> body) {
    final previous = persona!;
    final version = previous['version'] as int;
    final problem =
        rejectPatch ??
        (body['expectedVersion'] == version ? null : FailureCode.conflict);
    if (problem != null) {
      throw HostRequestException(Failure(problem, 'private host detail'));
    }
    final previousLayers = previous['layers'] as Map;
    final patches = body['diff']! as Map;
    final next = <String, Object?>{
      for (final layer in ['p0', 'p1', 'p2'])
        layer: _patchLayer(previousLayers[layer] as Map, patches[layer] as Map),
    };
    persona = {...previous, 'version': version + 1, 'layers': next};
    return malformedPatchResponse ? {'aiId': 'other-profile'} : persona!;
  }

  Map<Object?, Object?> _patchLayer(Map before, Map patch) =>
      {...before, ...patch}..removeWhere((_, value) => value == null);

  Map<String, Object?> _provider(String id, String cap, String url) => {
    'id': id,
    'name': 'Fixture $id',
    'base_url': url,
    'key_mask': '****z9y8',
    'enabled': true,
    'capabilities': [cap],
  };

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    requests.add((method, path, body, retryAuthentication));
    if (method != 'GET' || path != '$_profile/bindings') {
      throw StateError('Unexpected fixture request $method $path');
    }
    if (!bindingReadStarted.isCompleted) bindingReadStarted.complete();
    await holdBindings?.future;
    return [
      _binding('chat', 'chat-provider', 'reef/chat/model-v3'),
      _binding('chatFast', 'fast-provider', 'reef/fast/model-v1'),
    ];
  }

  Map<String, Object?> _binding(String cap, String provider, String model) => {
    'owner_id': 'owner',
    'ai_profile_id': 'profile-selected',
    'capability': cap,
    'provider_id': provider,
    'model': model,
  };
}

class _Model extends ShellViewModel {
  @override
  String get connectedAccountId => 'owner';
  @override
  bool online = true;
  @override
  bool locked = false;
  int lockEpoch = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);

  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(accountId: 'ai-selected', displayName: '琉璃鲸', disabled: false),
    ShellOwnedAi(accountId: 'ai-other', displayName: '其他 AI', disabled: false),
  ];

  void updateOnline(bool value) {
    online = value;
    notifyListeners();
  }

  void lockAndUnlock() {
    locked = true;
    lockEpoch++;
    notifyListeners();
    locked = false;
    lockEpoch++;
    notifyListeners();
  }
}

Future<_Model> _pump(
  WidgetTester tester,
  _Host host, {
  double width = 375,
  bool withSocialLevel = false,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 700));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(host.close);
  final model = _Model();
  addTearDown(model.dispose);
  final epoch = model.lockEpoch;
  final direct = OwnerAiDirectApi(host);
  Future<OwnedAiProfileIdentity> resolve(String account) =>
      direct.registerOrResolve(
        account,
        expectedOwnerAccountId: 'owner',
        retryAuthentication: false,
      );
  await tester.pumpWidget(
    MaterialApp(
      home: AiConfigEditor(
        session: (
          model: model,
          isCurrent: () => !model.locked && model.lockEpoch == epoch,
        ),
        ownedAiAccountIds: const ['ai-selected'],
        replyPreferences: OwnerReplyPreferencesApi(host),
        ruleGreeting: OwnerRuleGreetingApi(host),
        modelProactive: OwnerModelProactiveApi(host),
        socialLevel: withSocialLevel ? OwnerSocialLevelApi(host) : null,
        writer: AiConfigWriteApi(
          host,
          retryAuthentication: false,
          allowMultilinePersona: true,
        ),
        androidDetails: (
          aiLabel: '琉璃鲸',
          resolveIdentity: resolve,
          readiness: OwnerAiReadinessApi(host),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return model;
}

Finder _key(String key) => find.byKey(Key(key));

Future<void> _tap(WidgetTester tester, String key) async {
  final button = _key(key);
  expect(button, findsOneWidget);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  final field = _key(key);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opening the pinned Android editor does not register or read', (
    tester,
  ) async {
    final host = _Host();
    await _pump(tester, host);
    expect(host.requests, isEmpty);
    expect(_key('android-ai-config-name'), findsOneWidget);
    expect(find.text('琉璃鲸'), findsOneWidget);
    expect(_key('ai-config-write-select'), findsNothing);
    expect(_key('android-ai-config-read').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'explicit read pairs chat and fast models to the saved API addresses',
    (tester) async {
      final host = _Host();
      await _pump(tester, host);
      await _tap(tester, 'android-ai-config-read');
      final models = _key('android-ai-config-models');
      for (final value in [
        'reef/chat/model-v3',
        'https://chat.example.test/v1',
        'reef/fast/model-v1',
        'https://fast.example.test/api',
      ]) {
        expect(
          find.descendant(of: models, matching: find.textContaining(value)),
          findsOneWidget,
        );
      }
      expect(find.textContaining('z9y8'), findsNothing);
      final (method, path, body, retry) = host.requests
          .where((r) => r.$1 != 'GET')
          .single;
      expect((method, path, retry), ('POST', Routes.aiProfileRegister, false));
      expect(body, {'accountId': 'ai-selected'});
      expect(host.requests.every((r) => !r.$4), isTrue);
    },
  );

  testWidgets('persona save sends only exact changes with the read revision', (
    tester,
  ) async {
    final host = _Host();
    await _pump(tester, host);
    await _tap(tester, 'android-ai-config-read');
    expect(find.textContaining('版本 7'), findsOneWidget);
    await _tap(tester, 'android-persona-edit');
    final bio = tester.widget<TextField>(
      find.descendant(
        of: _key('android-persona-value-p0-bio'),
        matching: find.byType(TextField),
      ),
    );
    expect(bio.controller!.text, ' line one\nline=two\t ');
    await _enter(
      tester,
      'android-persona-value-p1-tone',
      '  first\nsecond\tline ',
    );
    await _tap(tester, 'android-persona-remove-p1-obsolete');
    await _enter(tester, 'android-persona-reason', '调整语气');
    await _tap(tester, 'android-persona-save');
    final (method, path, body, retry) = host.requests
        .where((r) => r.$1 == 'PATCH')
        .single;
    expect((method, path, retry), ('PATCH', '$_profile/persona', false));
    expect(body, {
      'expectedVersion': 7,
      'reason': '调整语气',
      'diff': {
        'p0': {},
        'p1': {'tone': '  first\nsecond\tline ', 'obsolete': null},
        'p2': {},
      },
    });
    expect(find.textContaining('版本 8'), findsOneWidget);
    expect(host.requests.where((r) => r.$1 == 'POST'), hasLength(1));
  });

  for (final conflict in [true, false]) {
    testWidgets(
      '${conflict ? 'conflict' : 'unverified success response'} retires the revision without replay',
      (tester) async {
        final host = _Host()
          ..rejectPatch = conflict ? FailureCode.conflict : null
          ..malformedPatchResponse = !conflict;
        await _pump(tester, host);
        await _tap(tester, 'android-ai-config-read');
        await _tap(tester, 'android-persona-edit');
        await _enter(tester, 'android-persona-value-p1-tone', 'new tone');
        await _enter(tester, 'android-persona-reason', '调整语气');
        await _tap(tester, 'android-persona-save');
        expect(
          find.textContaining(conflict ? '版本冲突' : '保存结果未知'),
          findsOneWidget,
        );
        expect(find.textContaining('版本 7'), findsNothing);
        expect(_key('android-persona-save'), findsNothing);
        expect(_key('android-persona-edit'), findsNothing);
        expect(host.requests.where((r) => r.$1 == 'PATCH'), hasLength(1));
        expect(find.textContaining('private host detail'), findsNothing);
      },
    );
  }

  testWidgets(
    'refresh drops the previous address if the provider can no longer be read',
    (tester) async {
      final host = _Host();
      await _pump(tester, host);
      await _tap(tester, 'android-ai-config-read');
      expect(
        find.textContaining('https://chat.example.test/v1'),
        findsOneWidget,
      );
      host.providerUnavailable = true;
      await _tap(tester, 'android-ai-config-read');
      expect(find.textContaining('https://chat.example.test/v1'), findsNothing);
      expect(find.textContaining('reef/chat/model-v3'), findsOneWidget);
      expect(find.textContaining('API 地址暂不可读'), findsOneWidget);
    },
  );

  testWidgets(
    'session online changes immediately enable or disable the read action',
    (tester) async {
      final host = _Host();
      final model = await _pump(tester, host);
      final read = _key('android-ai-config-read');
      expect(tester.widget<FilledButton>(read).onPressed, isNotNull);
      model.updateOnline(false);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(read).onPressed, isNull);
      expect(find.textContaining('宿主未连接'), findsOneWidget);
      model.updateOnline(true);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(read).onPressed, isNotNull);
      expect(host.requests, isEmpty);
    },
  );

  testWidgets('denied readiness does not open the profile or advanced writes', (
    tester,
  ) async {
    final host = _Host()..personaDenied = true;
    await _pump(tester, host);
    await _tap(tester, 'android-ai-config-read');
    expect(find.text('高级配置'), findsNothing);
    expect(_key('android-persona-edit'), findsNothing);
    expect(find.textContaining('无权读取该 AI 的配置'), findsOneWidget);
    expect(find.textContaining('private host detail'), findsNothing);
    expect(
      host.requests.where(
        (r) => r.$2.contains('/bindings') || r.$2.contains('/model-providers/'),
      ),
      isEmpty,
    );
  });

  testWidgets('lock/unlock retires the page and prevents another host step', (
    tester,
  ) async {
    final host = _Host()..holdBindings = Completer<void>();
    final model = await _pump(tester, host);
    final read = _key('android-ai-config-read');
    expect(read.hitTestable(), findsOneWidget);
    await tester.tap(read);
    await tester.pump();
    expect(host.bindingReadStarted.isCompleted, isTrue);
    model.lockAndUnlock();
    host.holdBindings!.complete();
    await tester.pumpAndSettle();
    expect(_key('ai-config-session-invalid'), findsOneWidget);
    expect(find.text('琉璃鲸'), findsNothing);
    expect(find.textContaining('reef/chat/model-v3'), findsNothing);
    expect(
      host.requests.where((r) => r.$2.contains('/model-providers/')),
      isEmpty,
    );
  });

  testWidgets('social level write retires both cached proactive grants', (
    tester,
  ) async {
    final host = _Host();
    await _pump(tester, host, withSocialLevel: true);
    await _tap(tester, 'android-ai-config-read');
    await _tap(tester, 'owner-rule-greeting-read');
    await _tap(tester, 'owner-model-proactive-read');
    expect(find.text('已授权规则问候'), findsOneWidget);
    expect(find.text('已授权模型主动联系'), findsOneWidget);
    await _tap(tester, 'owner-social-level-read');
    await _tap(tester, 'owner-social-level-L0');
    await _tap(tester, 'owner-social-level-save');
    final (method, path, body, retry) = host.requests
        .where((r) => r.$1 == 'PUT')
        .single;
    expect((method, path, retry), ('PUT', '$_profile/social-level', false));
    expect(body, {'level': 'L0'});
    expect(find.text('已授权规则问候'), findsNothing);
    expect(find.text('已授权模型主动联系'), findsNothing);
    expect(_key('owner-rule-greeting-read'), findsOneWidget);
    expect(_key('owner-model-proactive-read'), findsOneWidget);
    expect(
      host.requests.where((r) => r.$2.endsWith('/owner-rule-greeting')),
      hasLength(1),
    );
    expect(
      host.requests.where((r) => r.$2.endsWith('/owner-model-proactive')),
      hasLength(1),
    );
  });

  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets(
      'existing behavior controls are reachable under 活人感 at $width px',
      (tester) async {
        final host = _Host();
        await _pump(tester, host, width: width);
        await _tap(tester, 'android-ai-config-read');
        await _tap(tester, 'android-ai-config-to-aliveness');
        final section = _key('android-ai-config-aliveness');
        expect(find.text('活人感').hitTestable(), findsWidgets);
        for (final key in [
          'owner-reply-preferences-read',
          'owner-rule-greeting-read',
          'owner-model-proactive-read',
        ]) {
          final control = find.descendant(of: section, matching: _key(key));
          await tester.ensureVisible(control);
          expect(control.hitTestable(), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
        // These cards only read or change their own existing host settings after
        // the owner chooses the relevant action; no new request on mount.
        expect(host.requests.where((r) => r.$1 != 'GET'), hasLength(1));
        expect(
          host.requests.where(
            (r) =>
                r.$2.contains('proactive') ||
                r.$2.contains('greeting') ||
                r.$2.contains('preferences'),
          ),
          isEmpty,
        );
      },
    );
  }
}
