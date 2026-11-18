import 'dart:async';

import 'package:client_flutter/features/contacts/contacts_screen.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'without a host lookup the contacts surface is an honest empty state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      expect(find.text('当前未连接宿主，无法读取联系人。'), findsOneWidget);
      expect(find.byKey(const Key('contacts-query')), findsNothing);
    },
  );

  testWidgets(
    'injected lookup renders canonical state and hides upstream errors',
    (tester) async {
      var calls = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ContactsScreen(
            lookupState: (id) async {
              calls.add(id);
              if (id == 'boom') throw StateError('private-upstream');
              return FriendState.friends;
            },
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('contacts-account-id')),
        'owner',
      );
      await tester.tap(find.byKey(const Key('contacts-query')));
      await tester.pumpAndSettle();
      expect(calls, ['owner']);
      expect(find.text('关系状态：好友'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('contacts-account-id')),
        'boom',
      );
      await tester.tap(find.byKey(const Key('contacts-query')));
      await tester.pumpAndSettle();
      expect(find.textContaining('查询失败'), findsOneWidget);
      expect(find.textContaining('private-upstream'), findsNothing);
    },
  );

  testWidgets('injected friend loader renders canonical contacts', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsScreen(
          loadFriends: () async => const [
            FriendContact(
              accountId: 'alice',
              displayName: 'Alice',
              state: FriendState.friends,
            ),
            FriendContact(
              accountId: 'bob',
              displayName: 'Bob\n\tLi',
              state: FriendState.incomingPending,
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alice'), findsOneWidget);
    expect(find.textContaining('alice'), findsOneWidget);
    expect(find.text('alice · 好友'), findsOneWidget);
    expect(find.text('Bob  Li'), findsOneWidget);
    expect(find.textContaining('对方请求添加你'), findsOneWidget);
    expect(find.textContaining('无法读取联系人'), findsNothing);
  });

  testWidgets('control-only display name falls back to the account ID', (
    tester,
  ) async {
    final contact = FriendContact.fromJson({
      'accountId': 'fixture-inviter',
      'displayName': '\u0001\u0080',
      'state': 'incomingPending',
    });
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(loadFriends: () async => [contact])),
    );
    await tester.pumpAndSettle();

    final row = tester.widget<ListTile>(
      find.byKey(const Key('contacts-friend-fixture-inviter')),
    );
    expect((row.title! as Text).data, 'fixture-inviter');
  });

  testWidgets('empty list keeps an honest empty state', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(loadFriends: () async => const [])),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂无联系人或待处理的好友邀请。'), findsOneWidget);
  });

  testWidgets('denied list read is reported honestly', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsScreen(
          loadFriends: () async => throw const HostRequestException(
            Failure(FailureCode.unauthenticated, 'upstream-secret'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('未认证或无权限'), findsOneWidget);
    expect(find.textContaining('upstream-secret'), findsNothing);
  });

  testWidgets('unknown list failure hides details and does not retry', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: ContactsScreen(
          loadFriends: () async {
            calls++;
            throw const FormatException('private-upstream-detail');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('读取失败或结果未知'), findsOneWidget);
    expect(find.textContaining('private-upstream-detail'), findsNothing);
    expect(calls, 1); // no automatic retry
  });

  testWidgets('list shows loading until the loader completes', (tester) async {
    final completer = Completer<List<FriendContact>>();
    await tester.pumpWidget(
      MaterialApp(home: ContactsScreen(loadFriends: () => completer.future)),
    );
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    completer.complete(const [
      FriendContact(
        accountId: 'alice',
        displayName: 'Alice',
        state: FriendState.friends,
      ),
    ]);
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Alice'), findsOneWidget);
  });
}
