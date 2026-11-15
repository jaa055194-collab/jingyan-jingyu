import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class MentionModel extends TestShellModel {
  MentionModel() {
    connectedAccountId = 'alice';
    online = true;
    selectedConversationId = 'g';
    queuedCount = 0;
    conversations = [
      const ShellConversation(id: 'g', title: 'Group', kind: 'group'),
    ];
    drafts['g'] = '你好';
  }
  final targets = <String>[];
  @override
  bool get canMentionAi =>
      authenticated && !locked && !busy && draft.trim().isNotEmpty;
  @override
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  }) async {
    targets.add(aiAccountId);
    drafts[conversationId] = '';
    notifyListeners();
  }
}

void main() {
  testWidgets(
    'mention action confirms one known ID and ordinary composer stays intact on cancel',
    (tester) async {
      final model = MentionModel();
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.byKey(const Key('mention-ai-message')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mention-ai-id')),
        'known-ai',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(model.targets, isEmpty);
      expect(model.draft, '你好');
      await tester.tap(find.byKey(const Key('mention-ai-message')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mention-ai-id')),
        'known-ai',
      );
      await tester.tap(find.byKey(const Key('confirm-mention-message')));
      await tester.pumpAndSettle();
      expect(model.targets, ['known-ai']);
      expect(model.draft, '');
    },
  );
  for (final change in ['logout', 'selection', 'draft']) {
    testWidgets('mention dialog shields private input on $change', (
      tester,
    ) async {
      final model = MentionModel();
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.byKey(const Key('mention-ai-message')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('mention-ai-id')),
        'private-target',
      );
      if (change == 'logout') {
        model.connectedAccountId = null;
        model.onboarded = false;
      }
      if (change == 'selection') model.selectedConversationId = 'other';
      if (change == 'draft') model.drafts['g'] = 'new draft';
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('private-target'), findsNothing);
      expect(find.byKey(const Key('mention-ai-id')), findsNothing);
      expect(model.targets, isEmpty);
    });
  }
  testWidgets(
    'invalid known ID does not send and narrow composer does not overflow',
    (tester) async {
      tester.view.physicalSize = const Size(390, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = MentionModel();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatPane(model: model)),
        ),
      );
      await tester.tap(find.byKey(const Key('mention-ai-message')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('mention-ai-id')), 'bad/id');
      await tester.tap(find.byKey(const Key('confirm-mention-message')));
      await tester.pumpAndSettle();
      expect(model.targets, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('mention dialog hides input on lock and composer drift', (
    tester,
  ) async {
    final model = MentionModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.byKey(const Key('mention-ai-message')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mention-ai-id')),
      'private-target',
    );
    model.locked = true;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('private-target'), findsNothing);
    expect(find.byKey(const Key('mention-ai-id')), findsNothing);
    expect(model.targets, isEmpty);
  });
}
