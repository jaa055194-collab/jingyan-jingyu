import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _target = 'Exact_ID-02';
const _path = '/api/v1/friends/Exact_ID-02/requests';
final _field = find.byKey(const Key('contacts-request-account'));
final _review = find.byKey(const Key('contacts-request-review'));
final _dialog = find.byKey(const Key('contacts-request-confirmation'));
final _send = find.byKey(const Key('contacts-request-send'));
final _result = find.byKey(const Key('contacts-request-result'));

class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final writes = <String>[];
  final response = Completer<Map<String, Object?>>();
  var reads = 0;

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    expect((method, path, body, query), ('GET', '/api/v1/friends', null, null));
    reads++;
    return const [
      {
        'accountId': 'fixture-peer',
        'displayName': 'Fixture Peer',
        'state': 'friends',
      },
    ];
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) {
    expect(method, 'POST', reason: 'no lookup or preflight');
    expect(
      (body, query, retryAuthentication, allowEmptySuccess),
      (null, null, false, true),
    );
    writes.add(path);
    return response.future;
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection live) {
    connection = live;
  }

  String? account = 'fixture-sender';
  bool isLocked = false;
  int session = 0;
  Object lockEpoch = Object();

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
  String? get connectedAccountId => account;
  @override
  Object? get ownAiSessionContext => account == null ? null : session;
  @override
  Object? get ownAiDirectContext =>
      account == null || locked ? null : lockEpoch;

  void lockAndUnlock() {
    lockEpoch = Object();
    isLocked = true;
    notifyListeners();
    isLocked = false;
    notifyListeners();
  }

  void changeIdentity(String change, _Connection next) {
    switch (change) {
      case 'lock/unlock':
        lockAndUnlock();
        return;
      case 'logout':
        account = null;
      case 'account':
        account = 'fixture-next';
      case 'connection':
        connection = next;
      case 'session':
        session++;
    }
    notifyListeners();
  }
}

Future<_Runtime> _openContacts(WidgetTester tester, _Connection conn) async {
  final runtime = _Runtime(conn);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
    await conn.close();
  });
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.tap(find.text('联系人'));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('contacts-friend-fixture-peer')), findsOneWidget);
  return runtime;
}

Future<void> _openConfirmation(WidgetTester tester) async {
  expect(_field, findsOneWidget);
  await tester.enterText(_field, _target);
  await tester.tap(_review);
  await tester.pumpAndSettle();
  expect(_dialog, findsOneWidget);
  expect(
    find.descendant(of: _dialog, matching: find.textContaining(_target)),
    findsOneWidget,
  );
}

void main() {
  testWidgets('opening Contacts, typing, and cancelling never writes', (
    tester,
  ) async {
    final conn = _Connection();
    await _openContacts(tester, conn);
    expect(conn.writes, isEmpty);
    await _openConfirmation(tester);
    expect(conn.writes, isEmpty);
    await tester.tap(find.byKey(const Key('contacts-request-cancel')));
    await tester.pumpAndSettle();
    expect(_dialog, findsNothing);
    expect(conn.writes, isEmpty);
    expect(conn.reads, 1);
  });

  testWidgets('invalid and own account IDs never open confirmation', (
    tester,
  ) async {
    final conn = _Connection();
    await _openContacts(tester, conn);
    expect(_field, findsOneWidget);
    for (final id in [
      '',
      'bad/id',
      ' $_target ',
      'fixture-sender',
      List.filled(65, 'a').join(),
    ]) {
      await tester.enterText(_field, id);
      await tester.tap(_review);
      await tester.pumpAndSettle();
      expect(_dialog, findsNothing, reason: 'invalid target $id');
      expect(conn.writes, isEmpty);
    }
  });

  testWidgets(
    'confirm sends the exact reviewed ID once and waits for host acknowledgement',
    (tester) async {
      final conn = _Connection();
      await _openContacts(tester, conn);
      await _openConfirmation(tester);
      expect(conn.writes, isEmpty);
      await tester.tap(_send);
      await tester.tap(_send, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(conn.writes, [_path]);
      expect(_result, findsNothing);
      expect(tester.widget<FilledButton>(_review).onPressed, isNull);

      conn.response.complete({});
      await tester.pumpAndSettle();
      expect(_result, findsOneWidget);
      expect(find.textContaining('宿主已确认'), findsOneWidget);
      expect(find.textContaining('不代表'), findsOneWidget);
      expect(
        find.byKey(const Key('contacts-friend-fixture-peer')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('contacts-friend-$_target')), findsNothing);
      expect(conn.reads, 1);
      expect(conn.writes, [_path]);
    },
  );

  testWidgets('403 shows an honest action error and never retries', (
    tester,
  ) async {
    final conn = _Connection();
    await _openContacts(tester, conn);
    await _openConfirmation(tester);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    conn.response.completeError(
      const HostRequestException(
        Failure(FailureCode.forbidden, 'opaque upstream'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('不会自动重试'), findsOneWidget);
    expect(find.textContaining('宿主已确认'), findsNothing);
    expect(find.textContaining('opaque upstream'), findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(conn.writes, [_path]);
    expect(conn.reads, 1);
  });

  for (final change in [
    'lock/unlock',
    'logout',
    'account',
    'connection',
    'session',
  ]) {
    testWidgets(
      '$change invalidates a pending confirmation without submitting',
      (tester) async {
        final conn = _Connection();
        final next = _Connection();
        addTearDown(next.close);
        final runtime = await _openContacts(tester, conn);
        await _openConfirmation(tester);
        runtime.changeIdentity(change, next);
        // Attempt to confirm before the first repaint, as well as verify closure after it.
        await tester.tap(_send, warnIfMissed: false);
        await tester.pumpAndSettle();
        expect(_dialog, findsNothing);
        expect(conn.writes, isEmpty);
        expect(next.writes, isEmpty);
      },
    );
  }

  testWidgets('a covering route clears only the request confirmation', (
    tester,
  ) async {
    final conn = _Connection();
    await _openContacts(tester, conn);
    final navigator = Navigator.of(tester.element(_field), rootNavigator: true);
    await _openConfirmation(tester);
    unawaited(
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Unrelated test page')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Unrelated test page'), findsOneWidget);
    expect(
      find.byKey(
        const Key('contacts-request-confirmation'),
        skipOffstage: false,
      ),
      findsNothing,
    );
    navigator.pop();
    await tester.pumpAndSettle();
    expect(_field, findsOneWidget);
    expect(conn.writes, isEmpty);
  });

  testWidgets('a late acknowledgement after lock/unlock is not displayed', (
    tester,
  ) async {
    final conn = _Connection();
    final runtime = await _openContacts(tester, conn);
    await _openConfirmation(tester);
    await tester.tap(_send);
    await tester.pumpAndSettle();
    expect(conn.writes, [_path]);

    runtime.lockAndUnlock();
    conn.response.complete({});
    await tester.pumpAndSettle();
    expect(_result, findsNothing);
    expect(tester.widget<FilledButton>(_review).onPressed, isNotNull);
    expect(conn.writes, [_path]);
  });

  testWidgets(
    'leaving action scope and returning cannot publish the late result',
    (tester) async {
      final conn = _Connection();
      await _openContacts(tester, conn);
      await _openConfirmation(tester);
      await tester.tap(_send);
      await tester.pumpAndSettle();
      expect(conn.writes, [_path]);

      await tester.tap(find.text('聊天'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('联系人'));
      await tester.pumpAndSettle();
      conn.response.complete({});
      await tester.pumpAndSettle();
      expect(_result, findsNothing);
      expect(conn.writes, [_path]);
    },
  );
}
