import 'dart:async';

import 'package:client_flutter/features/inbox/inbox_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/notification_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

NotificationItem _item() => const NotificationItem(
  kind: 'friendRequest',
  title: '好友邀请',
  status: 'pending',
  createdAt: '2026-11-18T00:00:00.000Z',
  refId: 'acct-a',
);

void main() {
  testWidgets('unbound inbox keeps the honest gap copy', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: InboxScreen())),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox-gap')), findsOneWidget);
    expect(find.text('当前未连接宿主，无法读取收件箱。'), findsOneWidget);
    expect(find.text('连接后可查看待处理的好友邀请。'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byKey(const Key('inbox-refresh')), findsNothing);
  });

  testWidgets('renders friend-request invitations as metadata only', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(loadNotifications: () async => [_item()]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('notification-acct-a')), findsOneWidget);
    expect(find.text('好友邀请'), findsOneWidget);
    expect(find.textContaining('来自 acct-a'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    expect(find.text('本页只读，不修改好友关系。'), findsNothing);
    // Without an injected accept/deny callback and a live session epoch the
    // row stays read-only: nothing is offered and nothing is claimed.
    expect(find.byKey(const Key('inbox-accept-acct-a')), findsNothing);
    expect(find.byKey(const Key('inbox-deny-acct-a')), findsNothing);
    expect(find.text('已接受'), findsNothing);
    expect(find.textContaining('请在“联系人”页处理'), findsNothing);
  });

  testWidgets('the footer honestly describes the narrowed write scope', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(loadNotifications: () async => [_item()]),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('inbox-footer')), findsOneWidget);
    expect(find.textContaining('接受/拒绝需要再次确认'), findsOneWidget);
    expect(find.textContaining('结果以宿主返回为准'), findsOneWidget);
    expect(find.textContaining('其他通知只读'), findsOneWidget);
  });

  testWidgets('empty list is an honest empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(loadNotifications: () async => const []),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-empty')), findsOneWidget);
    expect(find.text('暂无新通知。'), findsOneWidget);
  });

  testWidgets(
    'manual refresh rereads once and disables the action until complete',
    (tester) async {
      final refresh = find.byKey(const Key('inbox-refresh'));
      final pending = Completer<List<NotificationItem>>();
      var reads = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InboxScreen(
              loadNotifications: () async =>
                  ++reads == 1 ? [_item()] : pending.future,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.byKey(const Key('notification-acct-a')), findsOneWidget);
      await tester.tap(refresh);
      await tester.pump();
      expect(reads, 2);
      expect(tester.widget<TextButton>(refresh).onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(const Key('inbox-empty')), findsNothing);
      await tester.pump(const Duration(minutes: 2));
      expect(reads, 2);
      pending.complete([]);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-acct-a')), findsNothing);
      expect(find.byKey(const Key('inbox-empty')), findsOneWidget);
      expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    },
  );

  testWidgets('temporary failure can be retried explicitly without polling', (
    tester,
  ) async {
    var reads = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(
            loadNotifications: () async {
              if (++reads == 1) throw StateError('opaque-failure');
              return [_item()];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-message')), findsOneWidget);
    expect(find.textContaining('opaque-failure'), findsNothing);
    expect(find.byKey(const Key('inbox-empty')), findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(reads, 1);
    await tester.tap(find.byKey(const Key('inbox-refresh')));
    await tester.pumpAndSettle();
    expect(reads, 2);
    expect(find.byKey(const Key('notification-acct-a')), findsOneWidget);
    expect(find.byKey(const Key('inbox-message')), findsNothing);
    await tester.pump(const Duration(minutes: 2));
    expect(reads, 2);
  });

  testWidgets('denied read is reported honestly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(
            loadNotifications: () async => throw const HostRequestException(
              Failure(FailureCode.forbidden, 'forbidden'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('未认证或无权限读取通知；不会自动重试'), findsOneWidget);
  });

  testWidgets('unknown failure hides details and does not retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(
            loadNotifications: () async =>
                throw const FormatException('secret-detail-xyz'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-message')), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
    expect(find.text('通知读取失败或结果未知；不会自动重试'), findsOneWidget);
  });

  testWidgets('loading state shows a progress indicator before data', (
    tester,
  ) async {
    final completer = Completer<List<NotificationItem>>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: InboxScreen(loadNotifications: () => completer.future),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete([_item()]);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('notification-acct-a')), findsOneWidget);
  });
}
