import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _register = '/api/v1/ai-profiles/register';
String _history(String member) =>
    '/api/v1/ai-profiles/profile-$member/persona/history';

Map<String, Object?> _change(int version, [String kind = 'edit']) {
  final layers = {
    'p0': {'synthetic-field-opaque': 'synthetic-value-opaque'},
    'p1': {'style': 'synthetic-style-opaque'},
    'p2': {'mood': 'synthetic-mood-opaque'},
  };
  return {
    'id': 'synthetic-history-id',
    'version': version,
    'kind': kind,
    'actorAccountId': 'fixture-owner',
    'before': kind == 'initialize' ? null : layers,
    'after': layers,
    'diff': kind == 'initialize'
        ? layers
        : {
            'p0': <String, String?>{},
            'p1': {'synthetic-field-opaque': null},
            'p2': <String, String?>{},
          },
    'reason': 'synthetic-reason-opaque',
    'evidenceIds': ['synthetic-evidence-opaque'],
    'at': '2026-02-05T10:30:00.000Z',
    'lockedBefore': kind == 'initialize' ? null : false,
    'lockedAfter': false,
    'revertsChangeId': null,
  };
}

Map<String, Object?> _page(int from, int through, {int? next}) => {
  'changes': [
    for (var i = from; i <= through; i++)
      _change(i, i == 1 ? 'initialize' : 'edit'),
  ],
  'nextAfterVersion': next,
};

class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final calls = <(String, String)>[];
  final cursors = <int>[];
  Future<Map<String, Object?>>? resolving;
  Future<Map<String, Object?>> Function(int after)? reply;

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
    if (method == 'POST' && path == _register) {
      final ai = body!['accountId']! as String;
      final future = resolving;
      if (future != null) return future;
      return {
        'accountId': ai,
        'ownerAccountId': 'fixture-owner',
        'profileId': 'profile-${ai.substring(3)}',
      };
    }
    throw StateError('Unexpected history fixture method');
  }

  // This also compiles on the original production tree for the route RED.
  // ignore: annotate_overrides
  Future<Map<String, Object?>> getBoundedJsonWithQuery(
    String path, {
    required Map<String, String> query,
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    calls.add(('GET', path));
    expect(path, anyOf(_history('a'), _history('b')));
    expect(query.keys, unorderedEquals(['limit', 'afterVersion']));
    expect(query['limit'], '20');
    expect(maxResponseBytes, 2 * 1024 * 1024);
    expect(cancellation, isNotNull);
    final after = int.parse(query['afterVersion']!);
    cursors.add(after);
    final handler = reply;
    if (handler != null) return handler(after);
    return _page(1, 1);
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection host) {
    connection = host;
  }
  String? owner = 'fixture-owner';
  bool isLocked = false;
  Object lockEpoch = Object();
  int epoch = 0;
  List<ShellOwnedAi> owned = const [
    ShellOwnedAi(accountId: 'ai-a', displayName: '示例 A', disabled: false),
    ShellOwnedAi(accountId: 'ai-b', displayName: '示例 B', disabled: false),
  ];

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
  Object? get ownAiSessionContext => authenticated ? epoch : null;
  @override
  Object? get ownAiDirectContext => authenticated && !locked ? lockEpoch : null;
  @override
  List<ShellOwnedAi> get ownAiAccounts => owned;
}

Finder _key(String value) => find.byKey(Key(value));
final _read = _key('persona-history-read');
final _next = _key('persona-history-next');
final _first = _key('persona-history-version-1');

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    225,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, _Runtime runtime) async {
  addTearDown(runtime.dispose);
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  await _tap(tester, _key('open-ai-config-write'));
  await _show(tester, _key('help-persona'));
  expect(
    _read,
    findsOneWidget,
    reason: 'history belongs to the existing persona card',
  );
  await _show(tester, _read);
}

Future<void> _choose(WidgetTester tester, String id) async {
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

void main() {
  testWidgets(
    'production Settings history reads explicitly and pages on the resolved profile only',
    (tester) async {
      final host = _Connection()
        ..reply = (after) async =>
            after == 0 ? _page(1, 20, next: 20) : _page(21, 21);
      await _open(tester, _Runtime(host));
      expect(host.calls, [('POST', _register)]);
      await _tap(tester, _read);
      expect(host.calls, [('POST', _register), ('GET', _history('a'))]);
      expect(host.cursors, [0]);
      expect(_first, findsOneWidget);
      expect(find.textContaining('初始化'), findsWidgets);
      expect(find.textContaining('2026-02-05'), findsWidgets);
      for (final opaque in [
        'synthetic-field-opaque',
        'synthetic-value-opaque',
        'synthetic-style-opaque',
        'synthetic-reason-opaque',
        'synthetic-evidence-opaque',
        'synthetic-history-id',
        'fixture-owner',
      ]) {
        expect(find.textContaining(opaque), findsNothing);
      }
      await tester.pump(const Duration(seconds: 30));
      expect(host.cursors, [0], reason: 'no polling or auto-next');
      await _tap(tester, _next);
      expect(host.cursors, [0, 20]);
      expect(host.calls, [
        ('POST', _register),
        ('GET', _history('a')),
        ('GET', _history('a')),
      ]);
      expect(_first, findsNothing);
      expect(_key('persona-history-version-21'), findsOneWidget);
      expect(_next, findsNothing);
    },
  );

  testWidgets(
    'unresolved owner profile never enables history or resolves again',
    (tester) async {
      final resolved = Completer<Map<String, Object?>>();
      final host = _Connection()..resolving = resolved.future;
      await _open(tester, _Runtime(host));
      expect(tester.widget<OutlinedButton>(_read).onPressed, isNull);
      expect(host.calls, [('POST', _register)]);
      resolved.complete({
        'accountId': 'ai-a',
        'ownerAccountId': 'fixture-owner',
        'profileId': 'profile-a',
      });
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(_read).onPressed, isNotNull);
      expect(host.calls, [('POST', _register)]);
    },
  );

  for (final (failure, label) in [
    (FailureCode.notFound, '未初始化或不可见'),
    (FailureCode.forbidden, '无权读取'),
    (FailureCode.unavailable, '暂不可读'),
    (null, '没有历史记录'),
  ]) {
    testWidgets(
      'history status $failure is honest without raw details or retry',
      (tester) async {
        final host = _Connection()
          ..reply = (_) async {
            if (failure != null) {
              throw HostRequestException(
                Failure(failure, 'synthetic-error-opaque'),
              );
            }
            return _page(1, 0);
          };
        await _open(tester, _Runtime(host));
        await _tap(tester, _read);
        expect(find.textContaining(label), findsOneWidget);
        expect(find.textContaining('synthetic-error-opaque'), findsNothing);
        await tester.pump(const Duration(seconds: 30));
        expect(host.cursors, [0]);
        expect(_first, findsNothing);
      },
    );
  }

  testWidgets('profile switch clears the old page and reads only B', (
    tester,
  ) async {
    final host = _Connection()..reply = (_) async => _page(1, 1);
    await _open(tester, _Runtime(host));
    await _tap(tester, _read);
    expect(_first, findsOneWidget);
    expect(host.calls, [('POST', _register), ('GET', _history('a'))]);
    await _choose(tester, 'ai-b');
    expect(
      _first,
      findsNothing,
      reason: 'the old profile page is not carried into B',
    );
    await _tap(tester, _read);
    expect(host.calls, [
      ('POST', _register),
      ('GET', _history('a')),
      ('POST', _register),
      ('GET', _history('b')),
    ]);
    expect(_first, findsOneWidget);
    expect(_key('persona-history-version-2'), findsNothing);
  });

  testWidgets('A to B to A discards the old page and saved read callback', (
    tester,
  ) async {
    final pending = Completer<Map<String, Object?>>();
    final host = _Connection()..reply = (_) => pending.future;
    await _open(tester, _Runtime(host));
    final oldRead = tester.widget<OutlinedButton>(_read).onPressed!;
    await _tap(tester, _read);
    expect(host.cursors, [0]);
    await _choose(tester, 'ai-b');
    await _choose(tester, 'ai-a');
    await _show(tester, _read);
    pending.complete(_page(1, 1));
    oldRead();
    await tester.pumpAndSettle();
    expect(host.cursors, [0]);
    expect(_first, findsNothing);
    expect(host.calls, [
      ('POST', _register),
      ('GET', _history('a')),
      ('POST', _register),
      ('POST', _register),
    ]);
    host.reply = (_) async => _page(2, 2);
    await _tap(tester, _read);
    expect(_key('persona-history-version-2'), findsOneWidget);
  });

  for (final transition in [
    'lock',
    'account',
    'session',
    'connection',
    'ownership',
    'pop',
  ]) {
    testWidgets('late history is discarded after $transition', (tester) async {
      final pending = Completer<Map<String, Object?>>();
      final host = _Connection()..reply = (_) => pending.future;
      final runtime = _Runtime(host);
      await _open(tester, runtime);
      final oldRead = tester.widget<OutlinedButton>(_read).onPressed!;
      await _tap(tester, _read);
      switch (transition) {
        case 'lock':
          runtime.isLocked = true;
          runtime.lockEpoch = Object();
          runtime.notifyListeners();
          runtime.isLocked = false;
        case 'account':
          runtime.owner = 'replacement-owner';
        case 'session':
          runtime.epoch++;
        case 'connection':
          final replacement = _Connection();
          addTearDown(host.close);
          runtime.connection = replacement;
        case 'ownership':
          runtime.owned = const [];
        case 'pop':
          Navigator.of(tester.element(_read)).pop();
      }
      runtime.notifyListeners();
      pending.complete(_page(1, 1));
      oldRead();
      await tester.pumpAndSettle();
      expect(_first, findsNothing);
      expect(_read, findsNothing);
      expect(host.calls, [('POST', _register), ('GET', _history('a'))]);
    });
  }
}
