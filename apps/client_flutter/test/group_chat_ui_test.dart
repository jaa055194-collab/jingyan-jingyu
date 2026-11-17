import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class GroupTestModel extends TestShellModel {
  GroupTestModel() {
    connectedAccountId = 'alice';
    online = true;
    conversations = [];
    queuedCount = 0;
  }
  final created = <String>[];
  final added = <String>[];
  bool failCreate = false;
  int refreshes = 0;
  @override
  Future<void> refreshConversations() async {
    refreshes++;
    notifyListeners();
  }

  @override
  bool get canAddMembersToSelectedGroup => selectedConversationId == 'g';
  @override
  Future<void> createGroup(String name) async {
    created.add(name);
    if (failCreate) {
      error = '创建未确认，请刷新会话后重试';
      notifyListeners();
      return;
    }
    conversations = [ShellConversation(id: 'g', title: name)];
    selectedConversationId = 'g';
    notifyListeners();
  }

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    messages = [];
    notifyListeners();
  }

  @override
  Future<void> addGroupMember(String groupId, String accountId) async {
    added.add('$groupId:$accountId');
    notifyListeners();
  }
}

void main() {
  testWidgets('empty list can create a group and mobile opens confirmed chat', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = GroupTestModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.byKey(const Key('create-group')), findsOneWidget);
    await tester.tap(find.byKey(const Key('create-group')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('group-name')), 'Friends');
    await tester.tap(find.byKey(const Key('confirm-create-group')));
    await tester.pumpAndSettle();
    expect(model.created, ['Friends']);
    expect(find.text('还没有消息'), findsOneWidget);
    expect(find.byKey(const Key('add-group-member')), findsOneWidget);
    await tester.tap(find.byKey(const Key('add-group-member')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('member-account-id')), 'bob');
    await tester.tap(find.byKey(const Key('confirm-add-member')));
    await tester.pumpAndSettle();
    expect(model.added, ['g:bob']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('create dialog cancel and invalid name never invoke runtime', (
    tester,
  ) async {
    final model = GroupTestModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.byKey(const Key('create-group')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-create-group')));
    await tester.pumpAndSettle();
    expect(model.created, isEmpty);
    await tester.enterText(find.byKey(const Key('group-name')), 'x' * 101);
    await tester.tap(find.byKey(const Key('confirm-create-group')));
    await tester.pumpAndSettle();
    expect(model.created, isEmpty);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('group-name')), findsNothing);
  });

  for (final member in [false, true]) {
    testWidgets(
      'group dialog shields entered text on lock and authentication loss member=$member',
      (tester) async {
        final model = GroupTestModel();
        if (member) {
          model.conversations = [
            const ShellConversation(id: 'g', title: 'Friends'),
          ];
          model.selectedConversationId = 'g';
        }
        await tester.pumpWidget(WhaleChatApp(model: model));
        await tester.tap(
          find.byKey(Key(member ? 'add-group-member' : 'create-group')),
        );
        await tester.pumpAndSettle();
        final field = Key(member ? 'member-account-id' : 'group-name');
        await tester.enterText(find.byKey(field), 'private-value');
        model.locked = true;
        model.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('private-value'), findsNothing);
        expect(find.byKey(field), findsNothing);
        model.locked = false;
        model.connectedAccountId = null;
        model.onboarded = false;
        model.notifyListeners();
        await tester.pumpAndSettle();
        expect(find.text('private-value'), findsNothing);
        expect(find.byKey(field), findsNothing);
        expect(model.created, isEmpty);
        expect(model.added, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('logout directly shields open group input without a lock first', (
    tester,
  ) async {
    final model = GroupTestModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.byKey(const Key('create-group')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('group-name')),
      'private-logout',
    );
    model.connectedAccountId = null;
    model.onboarded = false;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('private-logout'), findsNothing);
    expect(find.byKey(const Key('group-name')), findsNothing);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(model.created, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wide create failure is shown and explicit refresh never creates',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = GroupTestModel()..failCreate = true;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.byKey(const Key('create-group')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('group-name')), 'x' * 100);
      await tester.tap(find.byKey(const Key('confirm-create-group')));
      await tester.pumpAndSettle();
      expect(model.created.single.length, 100);
      expect(find.textContaining('创建未确认'), findsWidgets);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('refresh-conversations')));
      await tester.pumpAndSettle();
      expect(model.refreshes, 1);
      expect(model.created, hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offline and busy cannot open create dialog', (tester) async {
    final model = GroupTestModel()..online = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    final button = tester.widget<FilledButton>(
      find.byKey(const Key('create-group')),
    );
    expect(button.onPressed, isNull);
    model.online = true;
    model.busy = true;
    model.notifyListeners();
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('create-group')))
          .onPressed,
      isNull,
    );
  });
}
