import 'dart:typed_data';

import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:client_flutter/net/attachment_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _pngBytes = <int>[
  137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, //
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137, //
  0, 0, 0, 10, 73, 68, 65, 84, 120, 156, 99, 0, 1, 0, 0, 5, 0, //
  1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130, //
];

class _ImageModel extends ShellViewModel {
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
  String? connectedAccountId = 'account';
  @override
  String? selectedConversationId = 'group';
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

  MessageImage? result = MessageImage(
    mime: 'image/png',
    bytes: Uint8List.fromList(_pngBytes),
    sha256: 'digest',
  );
  int openCalls = 0;
  final requested = <String>[];

  @override
  List<ShellConversation> conversations = const [
    ShellConversation(id: 'group', title: '小鲸', kind: 'group'),
  ];

  @override
  List<ShellMessage> messages = const [
    ShellMessage(
      id: 'message-image',
      text: 'report.png',
      attachmentId: 'attachment-1',
      attachmentName: 'report.png',
      imageAttachment: true,
    ),
    ShellMessage(
      id: 'message-text',
      text: '普通消息',
      attachmentId: 'attachment-2',
      attachmentName: 'notes.pdf',
    ),
  ];

  @override
  Future<MessageImage?> openImageAttachment(String messageId) async {
    openCalls++;
    requested.add(messageId);
    return result;
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
  Future<void> sendSelectedAttachment() async {}
  @override
  Future<void> discardSelectedAttachment() async {}
  @override
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  }) async {}
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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _pump(WidgetTester tester, ShellViewModel model) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ChatPane(model: model)),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('image messages need an explicit tap before any fetch', (
    tester,
  ) async {
    final model = _ImageModel();
    await _pump(tester, model);

    expect(model.openCalls, 0);
    expect(find.byKey(const Key('open-image-message-image')), findsOneWidget);
    expect(find.byKey(const Key('open-image-message-text')), findsNothing);

    await tester.tap(find.byKey(const Key('open-image-message-image')));
    await tester.pumpAndSettle();

    expect(model.openCalls, 1);
    expect(model.requested, ['message-image']);
    expect(find.byKey(const Key('message-image-dialog')), findsOneWidget);

    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('message-image-dialog')), findsNothing);
  });

  testWidgets('a refused or unavailable image shows no dialog', (tester) async {
    final model = _ImageModel()..result = null;
    await _pump(tester, model);

    await tester.tap(find.byKey(const Key('open-image-message-image')));
    await tester.pumpAndSettle();

    expect(model.openCalls, 1);
    expect(find.byKey(const Key('message-image-dialog')), findsNothing);
    expect(find.textContaining('图片暂不可用'), findsOneWidget);
  });

  testWidgets('locked sessions cannot request an image', (tester) async {
    final model = _ImageModel()..locked = true;
    await _pump(tester, model);

    final button = tester.widget<TextButton>(
      find.byKey(const Key('open-image-message-image')),
    );
    expect(button.onPressed, isNull);
    expect(model.openCalls, 0);
  });
}
