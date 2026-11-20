import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

/// A view-model double that exposes the same `unread` projection the runtime
/// publishes: opening a conversation clears only that conversation's count.
class _UnreadModel extends TestShellModel {
  _UnreadModel() {
    connectedAccountId = 'alice';
    online = true;
    queuedCount = 0;
    conversations = [
      const ShellConversation(id: 'busy', title: '忙碌会话', unread: 3),
      const ShellConversation(id: 'quiet', title: '安静会话'),
    ];
  }

  final opened = <String>[];

  @override
  Future<void> selectConversation(String id) async {
    opened.add(id);
    selectedConversationId = id;
    messages = const [];
    conversations = [
      for (final conversation in conversations)
        conversation.id == id
            ? ShellConversation(
                id: conversation.id,
                title: conversation.title,
                preview: conversation.preview,
                kind: conversation.kind,
                ownerAccountId: conversation.ownerAccountId,
              )
            : conversation,
    ];
    notifyListeners();
  }
}

void main() {
  testWidgets('the list shows the unread count and clears it after opening', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _UnreadModel();
    await tester.pumpWidget(WhaleChatApp(model: model));

    final badge = find.descendant(
      of: find.byKey(const ValueKey('busy')),
      matching: find.byType(Badge),
    );
    expect(badge, findsOneWidget);
    expect(
      find.descendant(of: badge, matching: find.text('3')),
      findsOneWidget,
    );
    // A conversation with no cached messages never shows a badge.
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quiet')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );

    await tester.tap(find.byKey(const ValueKey('busy')));
    await tester.pumpAndSettle();
    expect(model.opened, ['busy']);
    expect(model.selectedConversationId, 'busy');
    expect(badge, findsNothing, reason: 'opening clears the badge');
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('quiet')),
        matching: find.byType(Badge),
      ),
      findsNothing,
    );
  });

  testWidgets('an unread count renders as a real badge in the list row', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = _UnreadModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.pumpAndSettle();
    expect(find.text('忙碌会话'), findsOneWidget);
    expect(find.byType(Badge), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
  });
}
