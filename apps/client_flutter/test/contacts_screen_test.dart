import 'package:client_flutter/features/contacts/contacts_screen.dart';
import 'package:client_flutter/net/friends_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'without a host lookup the contacts surface is an honest empty state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: ContactsScreen()));
      expect(find.text('宿主未提供好友列表路由；接入好友列表后可在此显示。'), findsOneWidget);
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
}
