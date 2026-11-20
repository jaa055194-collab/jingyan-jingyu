import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

const _entry = Key('open-favorites');
const _load = Key('load-favorites');
const _invalid = Key('favorites-invalidated');
const _preview = 'Visible source excerpt';
const _privateText = 'Never rendered fixture secret';

const _fixture = <String, Object?>{
  'favorites': [
    {
      'id': 'fav-message',
      'kind': 'message',
      'messageId': 'msg-1',
      'conversationId': 'conv-1',
      'title': 'Editorial notes',
      'content':
          '{"text":"Visible source excerpt",'
          '"storagePath":"/home/fixture/private",'
          '"api_key":"Never rendered fixture secret"}',
      'tags': ['hidden fixture tag'],
      'note': 'hidden fixture note',
      'createdAt': '2026-11-20T10:11:12.000Z',
    },
    {
      'id': 'fav-link',
      'kind': 'link',
      'messageId': null,
      'conversationId': null,
      'title': 'https://fixture.invalid/hidden-title',
      'content': 'https://fixture.invalid/hidden-url',
      'tags': null,
      'note': null,
      'createdAt': '2026-11-20T10:11:12.000Z',
    },
  ],
};

class _Connection extends HostConnection {
  _Connection(this.reply)
    : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final FutureOr<Map<String, Object?>> Function() reply;
  final reads = <String>[];
  HostReadCancellation? readCancellation;

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    reads.add(path);
    readCancellation = cancellation;
    return reply();
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(HostConnection fixture) {
    connection = fixture;
  }

  bool isLocked = false;
  String? account = 'fixture-owner';
  int session = 1;

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  String? get connectedAccountId => account;
  @override
  int? get ownAiSessionContext => authenticated ? session : null;
  @override
  bool get locked => isLocked;

  void lock(bool value) {
    isLocked = value;
    notifyListeners();
  }
}

Future<_Runtime> _pump(WidgetTester tester, _Connection connection) async {
  final runtime = _Runtime(connection);
  addTearDown(runtime.dispose);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.pumpAndSettle();
  return runtime;
}

Future<void> _open(WidgetTester tester) async {
  final entry = find.byKey(_entry);
  expect(entry, findsOneWidget);
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('conversation list opens favorites without reading until load', (
    tester,
  ) async {
    final connection = _Connection(() => _fixture);
    final runtime = await _pump(tester, connection);
    expect(connection.reads, isEmpty);
    await _open(tester);
    expect(connection.reads, isEmpty);
    expect(find.text(_preview), findsNothing);
    final submit = tester.widget<FilledButton>(find.byKey(_load)).onPressed!;
    submit();
    submit();
    await tester.pumpAndSettle();
    expect(connection.reads, [Routes.favorites]);
    expect(connection.readCancellation, isNotNull);
    expect(find.text('Editorial notes'), findsOneWidget);
    expect(find.text(_preview), findsOneWidget);
    expect(find.text('链接收藏'), findsOneWidget);
    for (final hidden in [
      _privateText,
      '/home/fixture/private',
      'fixture.invalid',
      'hidden fixture',
      'conv-1',
    ]) {
      expect(find.textContaining(hidden), findsNothing);
    }
    await tester.tap(find.text('链接收藏'));
    await tester.pumpAndSettle();
    expect(connection.reads, [Routes.favorites]);
    expect(runtime.selectedConversationId, isNull);
    expect(find.text(_preview), findsOneWidget);
  });

  testWidgets('a lock and unlock in the same frame clear loaded favorites', (
    tester,
  ) async {
    final connection = _Connection(() => _fixture);
    final runtime = await _pump(tester, connection);
    await _open(tester);
    final submit = tester.widget<FilledButton>(find.byKey(_load)).onPressed!;
    submit();
    await tester.pumpAndSettle();
    expect(find.text(_preview), findsOneWidget);

    runtime.lock(true);
    runtime.lock(false);
    submit();
    await tester.pumpAndSettle();
    expect(find.text(_preview), findsNothing);
    expect(find.byKey(_invalid), findsOneWidget);
    expect(find.byKey(_load), findsNothing);
    expect(connection.reads, [Routes.favorites]);

    await tester.pageBack();
    await tester.pumpAndSettle();
    await _open(tester);
    expect(find.byKey(_load), findsOneWidget);
    expect(connection.reads, [Routes.favorites]);
  });

  for (final (label, invalidate) in <(String, void Function(_Runtime))>[
    ('logout', (model) => model.account = null),
    ('account switch', (model) => model.account = 'other-fixture-account'),
    ('same-account session replacement', (model) => model.session++),
  ]) {
    testWidgets('late favorites are discarded after $label', (tester) async {
      final response = Completer<Map<String, Object?>>();
      final connection = _Connection(() => response.future);
      final runtime = await _pump(tester, connection);
      await _open(tester);
      await tester.tap(find.byKey(_load));
      await tester.pump();
      expect(connection.reads, [Routes.favorites]);
      invalidate(runtime);
      runtime.notifyListeners();
      response.complete(_fixture);
      await tester.pumpAndSettle();
      expect(find.text(_preview), findsNothing);
      expect(find.byKey(_invalid), findsOneWidget);
      expect(find.byKey(_load), findsNothing);
    });
  }

  testWidgets(
    'covering and uncovering the route cannot publish a late result',
    (tester) async {
      final response = Completer<Map<String, Object?>>();
      final connection = _Connection(() => response.future);
      await _pump(tester, connection);
      await _open(tester);
      await tester.tap(find.byKey(_load));
      await tester.pump();
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(
            builder: (_) => const Scaffold(body: Text('Other route')),
          ),
        ),
      );
      await tester.pump();
      response.complete(_fixture);
      await tester.pumpAndSettle();
      expect(find.text(_preview, skipOffstage: false), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_invalid), findsOneWidget);
      expect(find.text(_preview), findsNothing);
      expect(connection.reads, [Routes.favorites]);
    },
  );

  for (final (key, reply) in <(String, Map<String, Object?> Function())>[
    ('favorites-empty', () => {'favorites': <Object?>[]}),
    (
      'favorites-malformed',
      () => {
        'favorites': [null],
      },
    ),
    (
      'favorites-denied',
      () => throw const HostRequestException(
        Failure(FailureCode.forbidden, _privateText),
      ),
    ),
    (
      'favorites-unavailable',
      () => throw const HostRequestException(
        Failure(FailureCode.unavailable, _privateText),
      ),
    ),
  ]) {
    testWidgets('$key is distinct and carries no private error detail', (
      tester,
    ) async {
      final connection = _Connection(reply);
      await _pump(tester, connection);
      await _open(tester);
      await tester.tap(find.byKey(_load));
      await tester.pumpAndSettle();
      expect(find.byKey(Key(key)), findsOneWidget);
      expect(find.text(_privateText), findsNothing);
      expect(connection.reads, [Routes.favorites]);
    });
  }
}
