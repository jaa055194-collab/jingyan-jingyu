import 'dart:async';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _Connection extends HostConnection {
  _Connection({this.writeGate})
    : super(Uri.parse('http://fixture.invalid'), 'fixture-token');

  final Completer<void>? writeGate;
  final writes = <String>[];
  int reads = 0;

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/notifications');
    expect(query, {'limit': '50'});
    reads++;
    return const [
      {
        'kind': 'friendRequest',
        'title': '好友邀请',
        'status': 'pending',
        'createdAt': '2026-11-18T00:00:00.000Z',
        'refId': 'fixture-alice',
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
  }) async {
    expect(method, 'POST');
    expect(body, isNull);
    expect(allowEmptySuccess, isTrue);
    writes.add(path);
    await writeGate?.future;
    return {};
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(HostConnection live) {
    connection = live;
  }
  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  String? get connectedAccountId => 'fixture-recipient';
}

class _LockableRuntime extends _Runtime {
  _LockableRuntime(super.live);
  bool isLocked = false;
  @override
  bool get locked => isLocked;
  @override
  bool get authenticated => connectedAccountId != null;
  void setLocked(bool value) {
    isLocked = value;
    notifyListeners();
  }
}

Future<void> _openInbox(WidgetTester tester, ClientRuntime runtime) async {
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.tap(find.text('收件箱'));
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, Key actionKey) async {
  await tester.tap(find.byKey(actionKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the production inbox tab writes only after explicit confirm', (
    tester,
  ) async {
    final connection = _Connection();
    addTearDown(connection.close);
    await _openInbox(tester, _Runtime(connection));

    expect(connection.reads, 1);
    expect(connection.writes, isEmpty, reason: 'reading must never write');

    await tester.tap(find.byKey(const Key('inbox-accept-fixture-alice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-confirm-dialog')), findsOneWidget);
    expect(connection.writes, isEmpty);

    await tester.tap(find.byKey(const Key('inbox-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(connection.writes, isEmpty);
    expect(find.byKey(const Key('inbox-accept-fixture-alice')), findsOneWidget);

    await _confirm(tester, const Key('inbox-accept-fixture-alice'));
    expect(connection.writes, ['/api/v1/friends/fixture-alice/accept']);
    expect(find.text('已接受'), findsOneWidget);
    expect(find.byKey(const Key('inbox-accept-fixture-alice')), findsNothing);
  });

  testWidgets('deny uses the existing deny route from the inbox row', (
    tester,
  ) async {
    final connection = _Connection();
    addTearDown(connection.close);
    await _openInbox(tester, _Runtime(connection));

    await _confirm(tester, const Key('inbox-deny-fixture-alice'));
    expect(connection.writes, ['/api/v1/friends/fixture-alice/deny']);
    expect(find.text('已拒绝'), findsOneWidget);
  });

  testWidgets('locking closes a pending confirmation without writing', (
    tester,
  ) async {
    final connection = _Connection();
    addTearDown(connection.close);
    final runtime = _LockableRuntime(connection);
    await _openInbox(tester, runtime);

    await tester.tap(find.byKey(const Key('inbox-accept-fixture-alice')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-confirm-dialog')), findsOneWidget);

    runtime.setLocked(true);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox-confirm-dialog')), findsNothing);
    expect(connection.writes, isEmpty);
    expect(find.text('已接受'), findsNothing);
  });

  testWidgets('logging out during the write discards the result', (
    tester,
  ) async {
    final gate = Completer<void>();
    final connection = _Connection(writeGate: gate);
    addTearDown(connection.close);
    final runtime = _LogoutRuntime(connection);
    await _openInbox(tester, runtime);

    await tester.tap(find.byKey(const Key('inbox-accept-fixture-alice')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
    await tester.pump();
    expect(connection.writes, ['/api/v1/friends/fixture-alice/accept']);

    runtime.signedOut = true;
    runtime.notifyListeners();
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('已接受'), findsNothing);
    expect(find.textContaining('不会自动重试'), findsNothing);
  });
}

class _LogoutRuntime extends _Runtime {
  _LogoutRuntime(super.live);
  bool signedOut = false;
  @override
  String? get connectedAccountId =>
      signedOut ? null : super.connectedAccountId;
  @override
  bool get authenticated => connectedAccountId != null;
}
