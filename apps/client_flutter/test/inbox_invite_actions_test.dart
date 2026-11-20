import 'dart:async';

import 'package:client_flutter/features/inbox/inbox_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/notification_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

/// Stands in for the runtime-issued session/lock/account epoch.
class _Session extends ChangeNotifier {
  Object? token = Object();

  /// A lock, logout or account change: the epoch is replaced or withdrawn.
  void rotate() {
    token = Object();
    notifyListeners();
  }

  void withdraw() {
    token = null;
    notifyListeners();
  }
}

NotificationItem _request({
  String refId = 'acct-a',
  String status = 'pending',
  String kind = 'friendRequest',
}) => NotificationItem(
  kind: kind,
  title: '好友邀请',
  status: status,
  createdAt: '2026-11-18T00:00:00.000Z',
  refId: refId,
);

Future<void> _pump(
  WidgetTester tester, {
  required List<NotificationItem> items,
  Future<void> Function(String accountId)? accept,
  Future<void> Function(String accountId)? deny,
  _Session? session,
}) async {
  final state = session ?? _Session();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: InboxScreen(
          loadNotifications: () async => items,
          acceptFriend: accept,
          denyFriend: deny,
          actionContext: () => state.token,
          actionChanges: state,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _confirm(WidgetTester tester, Key actionKey) async {
  await tester.tap(find.byKey(actionKey));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('pending friend-request rows offer explicit accept and deny', (
    tester,
  ) async {
    await _pump(
      tester,
      items: [
        _request(refId: 'acct-a'),
        _request(refId: 'acct-b', status: 'denied'),
        _request(refId: 'acct-c', kind: 'systemNotice'),
      ],
      accept: (_) async {},
      deny: (_) async {},
    );

    expect(find.byKey(const Key('inbox-accept-acct-a')), findsOneWidget);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsOneWidget);
    // Only pending friend requests are actionable.
    expect(find.byKey(const Key('inbox-accept-acct-b')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-b')), findsNothing);
    expect(find.byKey(const Key('inbox-accept-acct-c')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-c')), findsNothing);
    // A non-pending row is never presented as accepted.
    expect(find.text('已接受'), findsNothing);
    expect(find.text('已拒绝'), findsNothing);
  });

  testWidgets('accepting needs an explicit confirmation before any host write', (
    tester,
  ) async {
    final calls = <String>[];
    await _pump(
      tester,
      items: [_request()],
      accept: (accountId) async => calls.add(accountId),
      deny: (_) async {},
    );

    await tester.tap(find.byKey(const Key('inbox-accept-acct-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-confirm-dialog')), findsOneWidget);
    expect(find.textContaining('acct-a'), findsWidgets);
    expect(calls, isEmpty, reason: 'opening the dialog must not write');

    await tester.tap(find.byKey(const Key('inbox-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-confirm-dialog')), findsNothing);
    expect(calls, isEmpty, reason: 'a cancelled confirmation must not write');
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsOneWidget);

    await _confirm(tester, const Key('inbox-accept-acct-a'));
    expect(calls, ['acct-a']);
  });

  testWidgets('a confirmed accept updates only that row with the host result', (
    tester,
  ) async {
    final calls = <String>[];
    await _pump(
      tester,
      items: [_request(refId: 'acct-a'), _request(refId: 'acct-b')],
      accept: (accountId) async => calls.add(accountId),
      deny: (_) async {},
    );

    await _confirm(tester, const Key('inbox-accept-acct-a'));

    expect(calls, ['acct-a']);
    expect(find.text('已接受'), findsOneWidget);
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsNothing);
    // The other row is untouched and still actionable.
    expect(find.byKey(const Key('inbox-accept-acct-b')), findsOneWidget);
    expect(find.text('已拒绝'), findsNothing);
  });

  testWidgets('a confirmed deny shows the denied outcome, never accepted', (
    tester,
  ) async {
    final calls = <String>[];
    await _pump(
      tester,
      items: [_request()],
      accept: (_) async {},
      deny: (accountId) async => calls.add(accountId),
    );

    await _confirm(tester, const Key('inbox-deny-acct-a'));

    expect(calls, ['acct-a']);
    expect(find.text('已拒绝'), findsOneWidget);
    expect(find.text('已接受'), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsNothing);
  });

  testWidgets('a refused action is honest, claims nothing and never retries', (
    tester,
  ) async {
    var calls = 0;
    await _pump(
      tester,
      items: [_request()],
      accept: (_) async {
        calls++;
        throw const HostRequestException(
          Failure(FailureCode.forbidden, 'forbidden'),
        );
      },
      deny: (_) async {},
    );

    await _confirm(tester, const Key('inbox-accept-acct-a'));

    expect(calls, 1);
    expect(find.text('未认证或无权限处理邀请；不会自动重试'), findsOneWidget);
    expect(find.text('已接受'), findsNothing);
    // No automatic retry and no silent re-offer of the same action.
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(calls, 1);
  });

  testWidgets('an unknown action failure hides details and does not retry', (
    tester,
  ) async {
    await _pump(
      tester,
      items: [_request()],
      accept: (_) async => throw const FormatException('secret-detail-xyz'),
      deny: (_) async {},
    );

    await _confirm(tester, const Key('inbox-accept-acct-a'));

    expect(find.text('邀请处理响应无效；不会自动重试'), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
    expect(find.text('已接受'), findsNothing);
  });

  testWidgets('a malformed refId row stays read-only', (tester) async {
    await _pump(
      tester,
      items: [_request(refId: 'bad id!')],
      accept: (_) async {},
      deny: (_) async {},
    );

    expect(find.byKey(const Key('notification-bad id!')), findsOneWidget);
    expect(find.byKey(const Key('inbox-accept-bad id!')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-bad id!')), findsNothing);
    expect(find.text('已接受'), findsNothing);
  });

  testWidgets('actions stay hidden until a callback and a session are wired', (
    tester,
  ) async {
    // No callbacks at all.
    await _pump(tester, items: [_request()]);
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsNothing);

    // Only the accept callback is wired.
    await _pump(tester, items: [_request()], accept: (_) async {});
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsOneWidget);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsNothing);

    // No live session context: nothing may be offered.
    final session = _Session()..withdraw();
    await _pump(
      tester,
      items: [_request()],
      accept: (_) async {},
      deny: (_) async {},
      session: session,
    );
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsNothing);
  });

  testWidgets('a session change while confirming clears it and writes nothing', (
    tester,
  ) async {
    final calls = <String>[];
    final session = _Session();
    await _pump(
      tester,
      items: [_request()],
      accept: (accountId) async => calls.add(accountId),
      deny: (_) async {},
      session: session,
    );

    await tester.tap(find.byKey(const Key('inbox-accept-acct-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-confirm-dialog')), findsOneWidget);

    session.rotate();
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox-confirm-dialog')), findsNothing);
    expect(calls, isEmpty);
    expect(find.text('已接受'), findsNothing);
  });

  testWidgets('a session change during the host write discards the result', (
    tester,
  ) async {
    final calls = <String>[];
    final gate = Completer<void>();
    final session = _Session();
    await _pump(
      tester,
      items: [_request()],
      accept: (accountId) {
        calls.add(accountId);
        return gate.future;
      },
      deny: (_) async {},
      session: session,
    );

    await tester.tap(find.byKey(const Key('inbox-accept-acct-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
    await tester.pump();
    expect(calls, ['acct-a']);

    session.rotate();
    await tester.pump();
    gate.complete();
    await tester.pumpAndSettle();

    // No stale success banner and no fabricated failure: the row is back to
    // pending because the client cannot know the host outcome any more.
    expect(find.text('已接受'), findsNothing);
    expect(find.textContaining('不会自动重试'), findsNothing);
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsOneWidget);
  });

  testWidgets('other rows are disabled while an action is in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    await _pump(
      tester,
      items: [_request(refId: 'acct-a'), _request(refId: 'acct-b')],
      accept: (_) => gate.future,
      deny: (_) async {},
    );

    await tester.tap(find.byKey(const Key('inbox-accept-acct-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
    await tester.pump();

    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('inbox-accept-acct-b')))
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('inbox-accept-acct-b')))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('a manual refresh discards an outcome still in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    var reads = 0;
    final session = _Session();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(
            loadNotifications: () async {
              reads++;
              return [_request()];
            },
            acceptFriend: (_) => gate.future,
            denyFriend: (_) async {},
            actionContext: () => session.token,
            actionChanges: session,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(reads, 1);

    await tester.tap(find.byKey(const Key('inbox-accept-acct-a')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('inbox-confirm-ok')));
    await tester.pump();

    await tester.tap(find.byKey(const Key('inbox-refresh')));
    await tester.pumpAndSettle();
    expect(reads, 2);

    gate.complete();
    await tester.pumpAndSettle();

    expect(find.text('已接受'), findsNothing);
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsOneWidget);
  });
}
