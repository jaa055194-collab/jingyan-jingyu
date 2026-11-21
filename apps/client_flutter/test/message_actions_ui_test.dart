import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:client_flutter/net/message_operations_api.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _now = DateTime.now();

class _ActionsModel extends ShellViewModel {
  @override
  bool ready = true;
  @override
  bool busy = false;
  @override
  bool onboarded = true;
  @override
  bool chatEntered = true;
  @override
  bool locked = false;
  @override
  bool online = true;
  @override
  String? error;
  @override
  String? connectedAccountId = 'alice';
  @override
  String? selectedConversationId = 'chat';
  @override
  int queuedCount = 0;
  @override
  String get draft => '';
  @override
  bool aiConsentGranted = true;
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
  bool get canAddMembersToSelectedGroup => false;
  @override
  bool get canMentionAi => false;
  @override
  String? get selectedAttachmentName => null;

  final context = Object();
  var available = true;

  @override
  bool get messageOperationsAvailable => available;
  @override
  Object? get messageOperationsContext => available ? context : null;

  @override
  List<ShellConversation> get conversations => const [
    ShellConversation(id: 'chat', title: '周末野餐', kind: 'direct'),
  ];

  List<ShellMessage> rows = [
    ShellMessage(
      id: 'peer',
      text: '周末的野餐改到下午三点。',
      copyText: ' 周末的野餐改到下午三点。\n',
      sentAt: _now,
      operationEligible: true,
    ),
    ShellMessage(
      id: 'mine',
      text: '我会带上折叠椅。',
      copyText: '我会带上折叠椅。',
      outgoing: true,
      sentAt: _now,
      edited: true,
      operationEligible: true,
    ),
    ShellMessage(
      id: 'removable',
      text: '这条我马上撤回。',
      copyText: '这条我马上撤回。',
      outgoing: true,
      sentAt: _now,
      operationEligible: true,
    ),
    ShellMessage(
      id: 'old',
      text: '上周也在公园见面。',
      copyText: '上周也在公园见面。',
      outgoing: true,
      sentAt: _now.subtract(const Duration(hours: 25)),
      operationEligible: true,
    ),
    ShellMessage(
      id: 'removed',
      text: '消息已撤回',
      sentAt: _now,
      recalled: true,
      operationEligible: true,
    ),
    const ShellMessage(
      id: 'pending',
      text: '等待补传',
      outgoing: true,
      status: '等待补传',
    ),
  ];

  @override
  List<ShellMessage> get messages => [...rows];

  final editCalls = <(String, String, String)>[];
  final recallCalls = <String>[];
  MessageWriteOutcome editResult = const MessageWriteAccepted();
  MessageWriteOutcome recallResult = const MessageWriteAccepted();

  void replace(String id, ShellMessage Function(ShellMessage) update) {
    rows = [for (final row in rows) row.id == id ? update(row) : row];
    notifyListeners();
  }

  @override
  Future<MessageWriteOutcome> editMessage({
    required String conversationId,
    required String messageId,
    required String expectedText,
    required String text,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async {
    if (!viewIsCurrent()) return const MessageWriteCancelled();
    editCalls.add((conversationId, expectedText, text));
    if (editResult is MessageWriteAccepted) {
      replace(
        messageId,
        (row) => ShellMessage(
          id: row.id,
          text: text,
          copyText: text,
          outgoing: row.outgoing,
          sentAt: row.sentAt,
          edited: true,
          operationEligible: true,
        ),
      );
    }
    return editResult;
  }

  @override
  Future<MessageWriteOutcome> recallMessage({
    required String conversationId,
    required String messageId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async {
    if (!viewIsCurrent()) return const MessageWriteCancelled();
    recallCalls.add(messageId);
    if (recallResult is MessageWriteAccepted) {
      replace(
        messageId,
        (row) => ShellMessage(
          id: row.id,
          text: '消息已撤回',
          outgoing: row.outgoing,
          sentAt: row.sentAt,
          recalled: true,
          operationEligible: true,
        ),
      );
    }
    return recallResult;
  }

  @override
  Future<void> selectConversation(String id) async {}
  @override
  Future<void> sendMessage() async {}
  @override
  void updateDraft(String value) {}
  @override
  Future<void> attachFile(String kind) async {}
  @override
  Future<void> setAiConsent(bool allowed) async {}
  @override
  Future<void> addGroupMember(String groupId, String accountId) async {}
  @override
  Future<void> createGroup(String name) async {}
  @override
  Future<void> setAppLock(bool enabled, String pin) async {}
  @override
  Future<void> unlock(String pin) async {}
  @override
  Future<void> setHideNotificationBody(bool value) async {}
  @override
  Future<void> setAutoStart(bool value) async {}
  @override
  Future<void> setThemeMode(ThemeMode value) async {}
  @override
  Future<void> setFontScale(double value) async {}
  @override
  void clearError() {}
  @override
  Future<void> refreshConversations() async {}
  @override
  Future<void> enterChat() async {}
  @override
  Future<void> chooseCharacter(String characterId) async {}
  @override
  Future<void> generateRoom(String preset) async {}
  @override
  Future<void> confirmRoom() async {}
  @override
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  }) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, _ActionsModel model) async {
  // A tall viewport keeps every synthetic row built; the production list has
  // no top-anchored scrolling requirement under test here.
  tester.view.physicalSize = const Size(390, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff16776e)),
        useMaterial3: true,
      ),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: model,
          builder: (_, _) => ChatPane(model: model),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _openActions(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('message-actions-$id')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a stale sheet cannot copy the old chat text', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final model = _ActionsModel();
    await _pump(tester, model);
    await _openActions(tester, 'peer');
    model.selectedConversationId = 'elsewhere';
    // No frame has run; an already-built control must still fail closed.
    await tester.tap(find.byKey(const Key('message-action-copy')));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('locking with an edit dialog open hides its plaintext and save', (
    tester,
  ) async {
    final model = _ActionsModel();
    await _pump(tester, model);
    await _openActions(tester, 'removable');
    await tester.tap(find.byKey(const Key('message-action-edit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-message-input')), findsOneWidget);
    model.locked = true;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('edit-message-input')), findsNothing);
    expect(find.byKey(const Key('edit-message-confirm')), findsNothing);
    expect(model.editCalls, isEmpty);
  });

  testWidgets('renders edited, recalled and pending states honestly', (
    tester,
  ) async {
    final model = _ActionsModel();
    await _pump(tester, model);

    expect(find.byKey(const Key('message-edited-mine')), findsOneWidget);
    expect(find.text('已编辑'), findsOneWidget);
    expect(find.byKey(const Key('message-recalled-removed')), findsOneWidget);
    expect(find.text('消息已撤回'), findsOneWidget);
    expect(find.byKey(const Key('message-actions-peer')), findsOneWidget);
    expect(find.byKey(const Key('message-actions-mine')), findsOneWidget);
    expect(find.byKey(const Key('message-actions-removed')), findsNothing);
    expect(find.byKey(const Key('message-actions-pending')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'copy sends the exact canonical text and peer rows offer no write',
    (tester) async {
      final copied = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied.add((call.arguments as Map)['text'] as String);
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final model = _ActionsModel();
      await _pump(tester, model);
      await _openActions(tester, 'peer');
      expect(find.byKey(const Key('message-action-edit')), findsNothing);
      expect(find.byKey(const Key('message-action-recall')), findsNothing);
      await tester.tap(find.byKey(const Key('message-action-copy')));
      await tester.pumpAndSettle();
      expect(copied, [' 周末的野餐改到下午三点。\n']);
      expect(find.text('已复制'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'edit preloads the current text, trims input and shows the marker',
    (tester) async {
      final model = _ActionsModel();
      await _pump(tester, model);
      await _openActions(tester, 'removable');
      await tester.tap(find.byKey(const Key('message-action-edit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('edit-message-dialog')), findsOneWidget);
      final field = tester.widget<TextField>(
        find.byKey(const Key('edit-message-input')),
      );
      expect(field.controller!.text, '这条我马上撤回。');
      await tester.enterText(
        find.byKey(const Key('edit-message-input')),
        '  这条我已经重新编辑。  ',
      );
      await tester.tap(find.byKey(const Key('edit-message-confirm')));
      await tester.pumpAndSettle();
      expect(model.editCalls, [('chat', '这条我马上撤回。', '这条我已经重新编辑。')]);
      expect(find.text('消息已编辑'), findsOneWidget);
      expect(find.byKey(const Key('message-edited-removable')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'recall needs confirmation and is disabled outside the 24h window',
    (tester) async {
      final model = _ActionsModel();
      await _pump(tester, model);
      await _openActions(tester, 'old');
      final recall = find.byKey(const Key('message-action-recall'));
      expect(recall, findsOneWidget);
      expect(tester.widget<ListTile>(recall).enabled, isFalse);
      expect(model.recallCalls, isEmpty);
      await tester.tap(find.byKey(const Key('message-actions-sheet-close')));
      await tester.pumpAndSettle();
      await _openActions(tester, 'removable');
      await tester.tap(find.byKey(const Key('message-action-recall')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('recall-message-dialog')), findsOneWidget);
      expect(model.recallCalls, isEmpty);
      await tester.tap(find.byKey(const Key('recall-message-confirm')));
      await tester.pumpAndSettle();
      expect(model.recallCalls, ['removable']);
      expect(find.text('消息已撤回'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a rejected edit keeps the dialog and explains the failure', (
    tester,
  ) async {
    final model = _ActionsModel()..editResult = const MessageWriteRejected();
    await _pump(tester, model);
    await _openActions(tester, 'removable');
    await tester.tap(find.byKey(const Key('message-action-edit')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('edit-message-input')), '新的正文');
    await tester.tap(find.byKey(const Key('edit-message-confirm')));
    await tester.pumpAndSettle();
    expect(model.editCalls, hasLength(1));
    expect(find.byKey(const Key('edit-message-dialog')), findsOneWidget);
    expect(find.byKey(const Key('edit-message-failure')), findsOneWidget);
    expect(find.byKey(const Key('message-edited-removable')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
