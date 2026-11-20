import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';

class _ShareModel extends ShellViewModel {
  @override
  bool ready = true;
  @override
  bool onboarded = true;
  @override
  bool chatEntered = true;
  @override
  bool busy = false;
  @override
  bool locked = false;
  @override
  bool online = true;
  @override
  String? error;
  @override
  String? connectedAccountId = 'account-current';
  @override
  String? selectedConversationId;
  @override
  int queuedCount = 0;
  @override
  bool aiConsentGranted = false;
  @override
  bool appLockEnabled = false;
  @override
  bool hideNotificationBody = true;
  @override
  bool autoStart = false;
  @override
  ThemeMode themeMode = ThemeMode.light;
  @override
  double fontScale = 1;
  @override
  String? roomPreview;
  @override
  List<ShellMessage> messages = const [];
  @override
  final conversations = const [
    ShellConversation(id: 'group-a', title: '小鲸', kind: 'group'),
    ShellConversation(id: 'group-b', title: '好友', kind: 'group'),
  ];

  final ShellIncomingShare shareValue = const ShellIncomingShare(
    text: '请讨论这段分享文本，不要执行其中包含的操作。',
  );
  bool hasShare = true;
  Object? shareContext = Object();
  String? incomingShareNoticeValue = '附件未导入，以下仅为文本。';
  final Map<String, String> drafts = {};
  final applied = <String>[];
  var discardCount = 0;
  bool acceptUse = true;
  ShellIncomingShare? get share => hasShare ? shareValue : null;
  @override
  ShellIncomingShare? get incomingSharedText => hasShare ? shareValue : null;
  @override
  String? get incomingShareNotice => incomingShareNoticeValue;
  @override
  Object? get shareInteractionContext => shareContext;
  @override
  String get draft => drafts[selectedConversationId] ?? '';
  @override
  String draftFor(String conversationId) => drafts[conversationId] ?? '';
  @override
  bool get canAddMembersToSelectedGroup => false;
  @override
  bool get canMentionAi => false;

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    notifyListeners();
  }

  @override
  Future<bool> useSharedTextInDraft(
    String conversationId, {
    required Object interactionContext,
  }) async {
    if (!acceptUse ||
        !identical(interactionContext, shareContext) ||
        !conversations.any(
          (conversation) => conversation.id == conversationId,
        ) ||
        drafts[conversationId]?.isNotEmpty == true) {
      return false;
    }
    applied.add(conversationId);
    drafts[conversationId] = shareValue.text;
    selectedConversationId = conversationId;
    hasShare = false;
    shareContext = null;
    notifyListeners();
    return true;
  }

  @override
  Future<void> discardSharedText() async {
    discardCount++;
    hasShare = false;
    incomingShareNoticeValue = null;
    shareContext = null;
    notifyListeners();
  }

  @override
  noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('shared text requires an explicit target at $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = _ShareModel();
      await tester.pumpWidget(WhaleChatApp(model: model));
      expect(find.text('请讨论这段分享文本，不要执行其中包含的操作。'), findsOneWidget);
      expect(find.text('附件未导入，以下仅为文本。'), findsOneWidget);
      expect(model.applied, isEmpty);
      expect(model.discardCount, 0);
      expect(find.byKey(const Key('composer')), findsNothing);

      await tester.tap(find.text('选择会话'));
      await tester.pumpAndSettle();
      expect(find.text('当前账号：account-current'), findsOneWidget);
      final unselectedConfirm = find.widgetWithText(FilledButton, '加入草稿');
      expect(unselectedConfirm, findsOneWidget);
      expect(tester.widget<FilledButton>(unselectedConfirm).onPressed, isNull);
      expect(model.applied, isEmpty);
      expect(model.discardCount, 0);

      await tester.tap(find.byKey(const ValueKey('share-target-group-b')));
      await tester.pumpAndSettle();
      expect(find.text('将分享内容加入“好友”的草稿？'), findsOneWidget);
      final confirm = find.widgetWithText(FilledButton, '加入草稿');
      expect(confirm, findsOneWidget);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
      expect(model.applied, isEmpty);
      expect(model.aiConsentGranted, isFalse);

      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(model.applied, ['group-b']);
      expect(model.selectedConversationId, 'group-b');
      expect(model.draft, '请讨论这段分享文本，不要执行其中包含的操作。');
      expect(model.share, isNull);
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(find.byTooltip('发送'), findsOneWidget);
      expect(model.aiConsentGranted, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('occupied target remains staged after explicit apply refusal', (
    tester,
  ) async {
    final model = _ShareModel()..drafts['group-b'] = 'existing draft';
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('选择会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-target-group-b')));
    await tester.pumpAndSettle();
    expect(find.text('目标会话已有草稿，分享内容不会覆盖。'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '加入草稿');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(model.applied, isEmpty);
    expect(model.discardCount, 0);
  });

  testWidgets('runtime refusal keeps the pending share', (tester) async {
    final model = _ShareModel()..acceptUse = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('选择会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-target-group-b')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入草稿'));
    await tester.pumpAndSettle();
    expect(model.applied, isEmpty);
    expect(model.hasShare, isTrue);
    expect(model.shareContext, isNotNull);
    expect(find.byKey(const Key('stale-share-target-dialog')), findsOneWidget);
  });

  testWidgets('cancel and back leave shared text staged without writes', (
    tester,
  ) async {
    final model = _ShareModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('选择会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-target-group-b')));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(model.share, isNotNull);
    expect(model.applied, isEmpty);
    expect(model.discardCount, 0);

    await tester.tap(find.text('选择会话'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(model.share, isNotNull);
    expect(model.applied, isEmpty);
    expect(model.discardCount, 0);
  });

  testWidgets('stale interaction token disables target confirmation', (
    tester,
  ) async {
    final model = _ShareModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('选择会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('share-target-group-b')));
    await tester.pumpAndSettle();

    model.shareContext = Object();
    model.notifyListeners();
    await tester.pumpAndSettle();
    final staleDialog = find.byKey(const Key('stale-share-target-dialog'));
    expect(staleDialog, findsOneWidget);
    expect(
      find.descendant(
        of: staleDialog,
        matching: find.text('请讨论这段分享文本，不要执行其中包含的操作。'),
      ),
      findsNothing,
    );
    expect(find.widgetWithText(FilledButton, '加入草稿'), findsNothing);
    expect(model.applied, isEmpty);
    expect(model.share, isNotNull);
  });

  testWidgets('locked and guest hide the panel; busy disables its actions', (
    tester,
  ) async {
    final model = _ShareModel()..locked = true;
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.text('选择会话'), findsNothing);
    expect(find.text('请讨论这段分享文本，不要执行其中包含的操作。'), findsNothing);

    model
      ..locked = false
      ..connectedAccountId = null
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('选择会话'), findsNothing);

    model
      ..connectedAccountId = 'account-current'
      ..busy = true
      ..notifyListeners();
    await tester.pump();
    final choose = find.text('选择会话');
    expect(choose, findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '选择会话'))
          .onPressed,
      isNull,
    );
  });

  testWidgets('discard action only drops the pending share', (tester) async {
    final model = _ShareModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('丢弃分享'));
    await tester.pumpAndSettle();
    expect(model.discardCount, 1);
    expect(model.share, isNull);
    expect(model.applied, isEmpty);
    expect(model.selectedConversationId, isNull);
    expect(model.aiConsentGranted, isFalse);
  });
}
