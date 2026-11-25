import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _register = '/api/v1/ai-profiles/register';
const _catalogA = '/api/v1/model-providers/provider-a/models';
const _binding = '/api/v1/ai-profiles/profile-a/bindings/chat';
typedef _Request = (String method, String path, Map<String, Object?>? body);

Map<String, Object?> _models(String id) => {
  'models': [
    {'id': id},
  ],
};

Map<String, Object?> _profile(String account, String profile) => {
  'accountId': account,
  'ownerAccountId': 'owner-fixture',
  'profileId': profile,
};

class _Host extends HostConnection {
  _Host() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final requests = <_Request>[];
  Future<Map<String, Object?>> Function(String)? catalog;
  Future<Map<String, Object?>> Function(String)? resolve;
  Future<void>? saveGate;
  int resolveCalls = 0;
  final bindingAuthReplay = <bool>[];

  List<String> get reads => [
    for (final (method, path, _) in requests)
      if (method == 'GET') path,
  ];
  List<_Request> get writes => [
    for (final request in requests)
      if (request.$1 == 'PUT') request,
  ];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    requests.add((method, path, body));
    expect(query, isNull);
    if (method == 'POST' && path == _register) {
      final ai = body!['accountId']! as String;
      final handler = resolve;
      if (handler != null) {
        resolveCalls++;
        return handler(ai);
      }
      return _profile(ai, ai == 'ai-a' ? 'profile-a' : 'profile-b');
    }
    if (method == 'GET' &&
        path.startsWith('/api/v1/model-providers/') &&
        path.endsWith('/models')) {
      expect(body, isNull);
      final handler = catalog;
      if (handler != null) return handler(path);
      return _models('catalog-model');
    }
    if (method == 'PUT' && path.endsWith('/bindings/chat')) {
      bindingAuthReplay.add(retryAuthentication);
      await saveGate;
      return {
        'owner_id': 'owner-fixture',
        'ai_profile_id': path.split('/')[4],
        'capability': 'chat',
        'provider_id': body!['providerId'],
        'model': body['model'],
      };
    }
    throw StateError('Unexpected fixture request');
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Host host) {
    connection = host;
  }

  String? owner = 'owner-fixture';
  int epoch = 1;
  Object lockEpoch = Object();
  bool isLocked = false;

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  bool get locked => isLocked;
  @override
  String? get connectedAccountId => owner;
  @override
  Object? get ownAiSessionContext => owner == null ? null : epoch;
  @override
  Object? get ownAiDirectContext =>
      isLocked || owner == null ? null : lockEpoch;
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  List<ShellOwnedAi> get ownAiAccounts => const [
    ShellOwnedAi(accountId: 'ai-a', displayName: '鲸 A', disabled: false),
    ShellOwnedAi(accountId: 'ai-b', displayName: '鲸 B', disabled: false),
  ];

  void change(VoidCallback update) {
    update();
    notifyListeners();
  }
}

Finder _key(String value) => find.byKey(Key(value));

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _openSettings(WidgetTester tester, _Runtime runtime) async {
  addTearDown(runtime.dispose);
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, _Runtime runtime) async {
  await _openSettings(tester, runtime);
  await _tap(tester, _key('open-ai-config-write'));
  expect(_key('ai-config-write-select'), findsOneWidget);
}

Future<void> _enter(WidgetTester tester, String key, String value) async {
  await _show(tester, _key(key));
  await tester.enterText(_key(key), value);
  await tester.pumpAndSettle();
}

String _model(WidgetTester tester) =>
    tester.widget<TextField>(_key('binding-model')).controller!.text;

Future<void> _chooseAi(WidgetTester tester, String id) async {
  tester
      .state<ScrollableState>(find.byType(Scrollable).first)
      .position
      .jumpTo(0);
  await tester.pumpAndSettle();
  await tester.tap(_key('ai-config-write-select'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(id).last);
  await tester.pumpAndSettle();
}

void _expectBinding(_Host host, String model) {
  expect(host.writes, hasLength(1));
  final (method, path, body) = host.writes.single;
  expect((method, path), ('PUT', _binding));
  expect(Map<String, Object?>.from(body!), {
    'providerId': 'provider-a',
    'model': model,
  });
}

Future<void> _readCatalog(
  WidgetTester tester, {
  bool waitForCompletion = true,
}) async {
  final read = _key('binding-catalog-read');
  expect(
    read,
    findsOneWidget,
    reason: 'The existing editor exposes a catalog read action',
  );
  await _show(tester, read);
  await tester.tap(read);
  if (waitForCompletion) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

void main() {
  testWidgets(
    'a lock between the Settings tap and editor mount blocks resolution',
    (tester) async {
      final host = _Host();
      final runtime = _Runtime(host);
      await _openSettings(tester, runtime);
      final entry = _key('open-ai-config-write');
      await _show(tester, entry);
      await tester.tap(entry);
      runtime.change(() {
        runtime.isLocked = true;
        runtime.lockEpoch = Object();
      });
      runtime.change(() => runtime.isLocked = false);
      await tester.pumpAndSettle();
      expect(host.requests, isEmpty);
      expect(_key('ai-config-session-invalid'), findsOneWidget);
    },
  );

  testWidgets('Save already sent before lock does not publish a late success', (
    tester,
  ) async {
    final pending = Completer<void>();
    final host = _Host()..saveGate = pending.future;
    final runtime = _Runtime(host);
    await _open(tester, runtime);
    await _enter(tester, 'binding-provider', 'provider-a');
    await _enter(tester, 'binding-model', 'manual-model');
    await _tap(tester, _key('binding-save'));
    _expectBinding(host, 'manual-model');
    runtime.change(() => runtime.isLocked = true);
    runtime.change(() => runtime.isLocked = false);
    pending.complete();
    await tester.pumpAndSettle();
    _expectBinding(host, 'manual-model');
    expect(_key('ai-config-session-invalid'), findsOneWidget);
    expect(find.text('聊天绑定已保存'), findsNothing);
  });

  group('retained callback', () {
    testWidgets('catalog tile cannot fill a model after provider change', (
      tester,
    ) async {
      final host = _Host();
      await _open(tester, _Runtime(host));
      await _enter(tester, 'binding-provider', 'provider-a');
      await _readCatalog(tester);
      final pick = tester
          .widget<ListTile>(_key('binding-catalog-model-catalog-model'))
          .onTap!;
      await _enter(tester, 'binding-provider', 'provider-b');
      pick();
      await tester.pumpAndSettle();
      expect(_model(tester), isEmpty);
      expect(host.reads, [_catalogA]);
      expect(host.writes, isEmpty);
    });

    testWidgets('Save cannot retarget after A to B to A', (tester) async {
      final host = _Host();
      await _open(tester, _Runtime(host));
      await _enter(tester, 'binding-provider', 'provider-a');
      await _enter(tester, 'binding-model', 'manual-model');
      final saveButton = _key('binding-save');
      await _show(tester, saveButton);
      final oldSave = tester.widget<FilledButton>(saveButton).onPressed!;
      await _chooseAi(tester, 'ai-b');
      await _chooseAi(tester, 'ai-a');
      oldSave();
      await tester.pumpAndSettle();
      expect(host.writes, isEmpty);
      await _tap(tester, saveButton);
      _expectBinding(host, 'manual-model');
    });

    testWidgets('Save cannot dispatch twice while its write is pending', (
      tester,
    ) async {
      final pending = Completer<void>();
      final host = _Host()..saveGate = pending.future;
      await _open(tester, _Runtime(host));
      await _enter(tester, 'binding-provider', 'provider-a');
      await _enter(tester, 'binding-model', 'manual-model');
      final saveButton = _key('binding-save');
      await _show(tester, saveButton);
      final save = tester.widget<FilledButton>(saveButton).onPressed!;
      save();
      save();
      pending.complete();
      await tester.pumpAndSettle();
      _expectBinding(host, 'manual-model');
    });
  });

  testWidgets(
    'Settings picker reads explicitly and only Save writes the chat binding',
    (tester) async {
      final host = _Host();
      await _open(tester, _Runtime(host));
      expect(host.requests, hasLength(1));
      final (method, path, body) = host.requests.single;
      expect((method, path), ('POST', _register));
      expect(Map<String, Object?>.from(body!), {'accountId': 'ai-a'});
      await _show(tester, _key('binding-provider'));
      expect(_key('binding-catalog-read'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(_key('binding-catalog-read')).onPressed,
        isNull,
      );

      await _enter(tester, 'binding-provider', ' provider-a ');
      await _enter(tester, 'binding-model', 'manual-model');
      expect(host.reads, isEmpty);
      expect(host.writes, isEmpty);
      await _readCatalog(tester);
      expect(host.reads, [_catalogA]);
      expect(_model(tester), 'manual-model');
      await _tap(tester, find.text('catalog-model'));
      expect(_model(tester), 'catalog-model');
      expect(host.writes, isEmpty);
      expect(host.requests.where((r) => r.$1 == 'POST'), hasLength(1));

      await _tap(tester, _key('binding-save'));
      _expectBinding(host, 'catalog-model');
      expect(host.bindingAuthReplay, [false]);
      expect(host.reads, [_catalogA]);
    },
  );

  for (final result in ['empty', 'unavailable', 'malformed', 'denied']) {
    testWidgets(
      '$result catalog keeps a manual model without retry or binding write',
      (tester) async {
        final host = _Host()
          ..catalog = (_) async => switch (result) {
            'empty' => {'models': <Object?>[]},
            'malformed' => {
              'models': [
                {'id': 42, 'extra': 'not-displayable'},
              ],
            },
            _ => throw HostRequestException(
              Failure(
                result == 'denied'
                    ? FailureCode.forbidden
                    : FailureCode.unavailable,
                'untrusted-detail',
              ),
            ),
          };
        tester.view.physicalSize = const Size(375, 768);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _open(tester, _Runtime(host));
        await _enter(tester, 'binding-provider', 'provider-a');
        await _enter(tester, 'binding-model', 'manual-model');
        await _readCatalog(tester);
        final message = switch (result) {
          'empty' => '目录为空',
          'unavailable' => '暂不可读',
          'malformed' => '无法验证目录',
          _ => '无权限读取目录',
        };
        expect(find.textContaining(message), findsOneWidget);
        expect(_model(tester), 'manual-model');
        expect(find.textContaining('not-displayable'), findsNothing);
        expect(find.textContaining('untrusted-detail'), findsNothing);
        await tester.pump(const Duration(seconds: 30));
        expect(host.reads, [_catalogA]);
        expect(host.writes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('provider A to B to A cannot publish or select an old catalog', (
    tester,
  ) async {
    final old = Completer<Map<String, Object?>>();
    final host = _Host();
    host.catalog = (_) => host.reads.length == 1
        ? old.future
        : Future.value(_models('current-a'));
    await _open(tester, _Runtime(host));
    await _enter(tester, 'binding-provider', 'provider-a');
    await _readCatalog(tester, waitForCompletion: false);
    await _enter(tester, 'binding-provider', 'provider-b');
    await _enter(tester, 'binding-provider', 'provider-a');
    await _readCatalog(tester);
    old.complete(_models('stale-a'));
    await tester.pumpAndSettle();
    expect(find.text('stale-a'), findsNothing);
    await _tap(tester, find.text('current-a'));
    expect(_model(tester), 'current-a');
    await _enter(tester, 'binding-provider', 'provider-b');
    expect(
      _model(tester),
      isEmpty,
      reason: 'the copied model was for provider A',
    );
    expect(host.reads, [_catalogA, _catalogA]);
    expect(host.writes, isEmpty);
  });

  testWidgets('AI A to B to A drops old catalog and old model selection', (
    tester,
  ) async {
    final old = Completer<Map<String, Object?>>();
    final host = _Host();
    host.catalog = (_) => switch (host.reads.length) {
      1 => Future.value(_models('old-choice')),
      2 => old.future,
      _ => Future.value(_models('current-choice')),
    };
    await _open(tester, _Runtime(host));
    await _enter(tester, 'binding-provider', 'provider-a');
    await _readCatalog(tester);
    await _tap(tester, find.text('old-choice'));
    await _readCatalog(tester, waitForCompletion: false);
    await _chooseAi(tester, 'ai-b');
    await _chooseAi(tester, 'ai-a');
    await _show(tester, _key('binding-model'));
    expect(_model(tester), isEmpty);
    old.complete(_models('stale-ai-catalog'));
    await tester.pumpAndSettle();
    expect(find.text('stale-ai-catalog'), findsNothing);
    expect(host.reads, [_catalogA, _catalogA]);
    await _readCatalog(tester);
    expect(find.text('current-choice'), findsOneWidget);
    expect(host.writes, isEmpty);
  });

  testWidgets(
    'late profile resolution from before an AI A to B to A cannot retarget Save',
    (tester) async {
      final old = Completer<Map<String, Object?>>();
      final host = _Host();
      host.resolve = (id) async => host.resolveCalls == 1
          ? old.future
          : _profile(id, id == 'ai-a' ? 'profile-a' : 'profile-b');
      await _open(tester, _Runtime(host));
      await _chooseAi(tester, 'ai-b');
      await _chooseAi(tester, 'ai-a');
      old.complete(_profile('ai-a', 'stale-profile'));
      await tester.pumpAndSettle();
      await _enter(tester, 'binding-provider', 'provider-a');
      await _enter(tester, 'binding-model', 'manual-model');
      await _tap(tester, _key('binding-save'));
      _expectBinding(host, 'manual-model');
      expect(host.reads, isEmpty);
    },
  );

  for (final change in [
    'rapid-lock',
    'logout',
    'account',
    'same-account-epoch',
  ]) {
    testWidgets('$change blocks an already built Save callback', (
      tester,
    ) async {
      final host = _Host();
      final runtime = _Runtime(host);
      await _open(tester, runtime);
      await _enter(tester, 'binding-provider', 'provider-a');
      await _enter(tester, 'binding-model', 'manual-model');
      await _show(tester, _key('binding-save'));
      final save = tester.widget<FilledButton>(_key('binding-save')).onPressed!;
      switch (change) {
        case 'rapid-lock':
          runtime.change(() => runtime.isLocked = true);
          runtime.change(() => runtime.isLocked = false);
        case 'logout':
          runtime.change(() => runtime.owner = null);
        case 'account':
          runtime.change(() => runtime.owner = 'owner-other');
        case 'same-account-epoch':
          runtime.change(() => runtime.epoch++);
      }
      save();
      await tester.pumpAndSettle();
      expect(host.writes, isEmpty);
      expect(_key('binding-model'), findsNothing);
    });
  }

  testWidgets(
    'rapid lock and unlock invalidate an in-flight catalog and its old button',
    (tester) async {
      final pending = Completer<Map<String, Object?>>();
      final host = _Host()..catalog = (_) => pending.future;
      final runtime = _Runtime(host);
      await _open(tester, runtime);
      await _enter(tester, 'binding-provider', 'provider-a');
      final readButton = _key('binding-catalog-read');
      expect(readButton, findsOneWidget);
      final read = tester.widget<OutlinedButton>(readButton).onPressed!;
      await _readCatalog(tester, waitForCompletion: false);
      runtime.change(() => runtime.isLocked = true);
      runtime.change(() => runtime.isLocked = false);
      pending.complete(_models('late-locked-model'));
      read();
      await tester.pumpAndSettle();
      expect(find.text('late-locked-model'), findsNothing);
      expect(_key('binding-catalog-read'), findsNothing);
      expect(host.reads, [_catalogA]);
      expect(host.writes, isEmpty);
    },
  );
}
