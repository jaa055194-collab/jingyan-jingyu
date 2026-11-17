import 'dart:async';

import 'package:client_flutter/features/contacts/contacts_screen.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

FriendContact _bob(FriendState state) =>
    FriendContact(accountId: 'acct-b', displayName: 'Bob', state: state);

FriendContact _alice() => const FriendContact(
  accountId: 'acct-a',
  displayName: 'Alice',
  state: FriendState.friends,
);

void main() {
  testWidgets(
    'incoming pending invitations expose explicit accept/deny buttons',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContactsScreen(
              loadFriends: () async => [
                _alice(),
                _bob(FriendState.incomingPending),
              ],
              acceptFriend: (_) async {},
              denyFriend: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('friend-accept-acct-b')), findsOneWidget);
      expect(find.byKey(const Key('friend-deny-acct-b')), findsOneWidget);
      // Non-pending rows never expose actions.
      expect(find.byKey(const Key('friend-accept-acct-a')), findsNothing);
      expect(find.byKey(const Key('friend-deny-acct-a')), findsNothing);
      expect(find.text('接受'), findsOneWidget);
      expect(find.text('拒绝'), findsOneWidget);
    },
  );

  testWidgets('actions are disabled until callbacks are wired', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async => [_bob(FriendState.incomingPending)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('friend-accept-acct-b')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('friend-deny-acct-b')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('accept calls the callback with the account id and refreshes', (
    tester,
  ) async {
    var loaderCalls = 0;
    final accepted = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async {
              loaderCalls++;
              return [
                _alice(),
                _bob(
                  loaderCalls > 1
                      ? FriendState.friends
                      : FriendState.incomingPending,
                ),
              ];
            },
            acceptFriend: (accountId) async => accepted.add(accountId),
            denyFriend: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loaderCalls, 1);

    await tester.tap(find.byKey(const Key('friend-accept-acct-b')));
    await tester.pumpAndSettle();
    expect(accepted, ['acct-b']);
    expect(loaderCalls, 2, reason: 'the list is refreshed after success');
    expect(find.text('acct-a · 好友'), findsOneWidget);
    expect(find.byKey(const Key('friend-accept-acct-b')), findsNothing);
  });

  testWidgets('deny calls the callback with the account id and refreshes', (
    tester,
  ) async {
    var loaderCalls = 0;
    final denied = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async {
              loaderCalls++;
              return [
                _alice(),
                _bob(
                  loaderCalls > 1
                      ? FriendState.none
                      : FriendState.incomingPending,
                ),
              ];
            },
            acceptFriend: (_) async {},
            denyFriend: (accountId) async => denied.add(accountId),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('friend-deny-acct-b')));
    await tester.pumpAndSettle();
    expect(denied, ['acct-b']);
    expect(loaderCalls, 2);
    expect(find.byKey(const Key('friend-deny-acct-b')), findsNothing);
    expect(find.textContaining('未添加'), findsOneWidget);
  });

  testWidgets('denied action failure is reported honestly without refresh', (
    tester,
  ) async {
    var loaderCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async {
              loaderCalls++;
              return [_bob(FriendState.incomingPending)];
            },
            acceptFriend: (_) async => throw const HostRequestException(
              Failure(FailureCode.forbidden, 'forbidden'),
            ),
            denyFriend: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loaderCalls, 1);

    await tester.tap(find.byKey(const Key('friend-accept-acct-b')));
    await tester.pumpAndSettle();
    expect(find.text('未认证或无权限处理邀请；不会自动重试'), findsOneWidget);
    expect(loaderCalls, 1, reason: 'failed actions do not refresh');
    // The honest failure message replaces the list view until a reload.
    expect(find.byKey(const Key('friend-accept-acct-b')), findsNothing);
  });

  testWidgets('unknown action failure hides details and does not retry', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async => [_bob(FriendState.incomingPending)],
            denyFriend: (_) async =>
                throw const FormatException('secret-detail-xyz'),
            acceptFriend: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('friend-deny-acct-b')));
    await tester.pumpAndSettle();
    expect(find.text('好友操作响应无效；不会自动重试'), findsOneWidget);
    expect(find.textContaining('secret-detail-xyz'), findsNothing);
  });

  testWidgets('buttons are disabled while an action is in flight', (
    tester,
  ) async {
    final gate = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContactsScreen(
            loadFriends: () async => [_bob(FriendState.incomingPending)],
            acceptFriend: (_) => gate.future,
            denyFriend: (_) async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('friend-accept-acct-b')));
    await tester.pump();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('friend-accept-acct-b')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('friend-deny-acct-b')))
          .onPressed,
      isNull,
    );

    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('friend-accept-acct-b')))
          .onPressed,
      isNotNull,
    );
  });
}
