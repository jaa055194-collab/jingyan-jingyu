import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';

class TestShellModel extends ShellViewModel {
  @override
  bool ready = true;
  @override
  bool busy = false;
  @override
  bool onboarded = true;
  @override
  bool locked = false;
  @override
  bool online = false;
  @override
  String? error;
  @override
  String? selectedConversationId;
  @override
  List<ShellConversation> conversations = const [
    ShellConversation(id: 'a', title: '小鲸'),
    ShellConversation(id: 'b', title: '好友'),
  ];
  @override
  List<ShellMessage> messages = const [];
  @override
  int queuedCount = 2;
  final Map<String, String> drafts = {};
  @override
  String get draft => drafts[selectedConversationId] ?? '';
  @override
  bool aiConsentGranted = false;
  @override
  bool appLockEnabled = false;
  @override
  bool hideNotificationBody = true;
  @override
  bool autoStart = false;
  @override
  ThemeMode themeMode = ThemeMode.system;
  @override
  double fontScale = 1;
  @override
  String? roomPreview;
  bool failConnect = false;
  @override
  Future<void> connectHost(String address, String invite) async {
    error = failConnect ? '宿主尚未开放账户接入' : null;
    notifyListeners();
  }

  @override
  Future<void> chooseCharacter(String characterId) async {}
  @override
  Future<void> generateRoom(String preset) async {
    roomPreview = '安静的房间，可确认后进入';
    notifyListeners();
  }

  @override
  Future<void> confirmRoom() async {
    onboarded = true;
    notifyListeners();
  }

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    messages = [ShellMessage(id: 'm-$id', text: '会话 $id')];
    notifyListeners();
  }

  @override
  void updateDraft(String value) {
    drafts[selectedConversationId!] = value;
    notifyListeners();
  }

  @override
  Future<void> sendMessage() async {
    messages = [
      ...messages,
      ShellMessage(id: 'new', text: draft, outgoing: true, status: '等待联网'),
    ];
    updateDraft('');
  }

  @override
  Future<void> setAiConsent(bool allowed) async {
    aiConsentGranted = allowed;
    notifyListeners();
  }

  @override
  Future<void> attachFile(String kind) async {
    error = '$kind 文件选择不可用';
    notifyListeners();
  }

  @override
  Future<void> setAppLock(bool enabled, String pin) async {
    appLockEnabled = enabled;
    notifyListeners();
  }

  @override
  Future<void> unlock(String pin) async {
    if (pin == '1234') {
      locked = false;
      error = null;
    } else {
      error = 'PIN 不正确';
    }
    notifyListeners();
  }

  @override
  Future<void> setHideNotificationBody(bool value) async {
    hideNotificationBody = value;
    notifyListeners();
  }

  @override
  Future<void> setAutoStart(bool value) async {
    autoStart = value;
    notifyListeners();
  }

  @override
  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    notifyListeners();
  }

  @override
  Future<void> setFontScale(double value) async {
    fontScale = value;
    notifyListeners();
  }

  @override
  void clearError() {
    error = null;
    notifyListeners();
  }
}

void main() {
  test('settings persistence failure is exposed through model error', () async {
    final runtime = ClientRuntime();
    addTearDown(runtime.dispose);
    await expectLater(runtime.setThemeMode(ThemeMode.dark), completes);
    expect(runtime.error, isNotNull);
    expect(runtime.busy, isFalse);
    await expectLater(runtime.setFontScale(1.2), completes);
    expect(runtime.error, isNotNull);
    await expectLater(runtime.setHideNotificationBody(false), completes);
    expect(runtime.error, isNotNull);
  });
  testWidgets('host failure remains on connection step with actionable error', (
    tester,
  ) async {
    final model = TestShellModel()
      ..onboarded = false
      ..failConnect = true;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.enterText(
      find.byKey(const Key('host-address')),
      'http://localhost:8080',
    );
    await tester.enterText(find.byKey(const Key('host-invite')), 'invite');
    await tester.tap(find.text('连接宿主'));
    await tester.pumpAndSettle();
    expect(find.text('宿主尚未开放账户接入'), findsOneWidget);
    expect(find.text('连接宿主'), findsOneWidget);
    expect(find.text('选择你的形象'), findsNothing);
  });

  testWidgets('onboarding requires room preview before confirmation', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.enterText(
      find.byKey(const Key('host-address')),
      'http://localhost:8080',
    );
    await tester.enterText(find.byKey(const Key('host-invite')), 'invite');
    await tester.tap(find.text('连接宿主'));
    await tester.pumpAndSettle();
    expect(find.text('选择你的形象'), findsOneWidget);
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并进入'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('生成预览'));
    await tester.pumpAndSettle();
    expect(find.text('安静的房间，可确认后进入'), findsOneWidget);
    await tester.tap(find.text('花园小屋'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认并进入'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('生成预览'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并进入'));
    await tester.pumpAndSettle();
    expect(find.text('小鲸'), findsOneWidget);
  });

  testWidgets(
    'selecting conversations displays matching messages and restores drafts',
    (tester) async {
      final model = TestShellModel();
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.text('小鲸'));
      await tester.pumpAndSettle();
      expect(find.text('会话 a'), findsOneWidget);
      expect(find.textContaining('2 条待发送'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('composer')), '未完成的草稿');
      await tester.tap(find.text('好友'));
      await tester.pumpAndSettle();
      expect(find.text('会话 b'), findsOneWidget);
      await tester.tap(find.text('小鲸').first);
      await tester.pumpAndSettle();
      expect(find.text('未完成的草稿'), findsOneWidget);
      await tester.tap(find.byTooltip('发送'));
      await tester.pumpAndSettle();
      expect(find.text('等待联网'), findsOneWidget);
      expect(find.text('未完成的草稿'), findsOneWidget);
    },
  );

  testWidgets('attachment consent cancel never opens file action', (
    tester,
  ) async {
    final model = TestShellModel()..selectedConversationId = 'a';
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.byTooltip('添加图片'));
    await tester.pumpAndSettle();
    expect(find.text('允许 AI 读取附件？'), findsOneWidget);
    await tester.tap(find.text('暂不允许'));
    await tester.pumpAndSettle();
    expect(model.aiConsentGranted, isFalse);
    expect(model.error, isNull);
    await tester.tap(find.byTooltip('添加文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许并继续'));
    await tester.pumpAndSettle();
    expect(find.text('file 文件选择不可用'), findsOneWidget);
  });

  testWidgets('settings changes bind preferences and lock requires valid PIN', (
    tester,
  ) async {
    final model = TestShellModel();
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('应用锁'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('new-pin')), '12');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 4–12 位数字 PIN'), findsOneWidget);
    expect(model.appLockEnabled, isFalse);
    await tester.enterText(find.byKey(const Key('new-pin')), '1234');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(model.appLockEnabled, isTrue);
    await tester.tap(find.text('隐藏通知正文'));
    await tester.pumpAndSettle();
    expect(model.hideNotificationBody, isFalse);
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(model.themeMode, ThemeMode.dark);
  });

  testWidgets('locked shell hides messages and allows PIN retry', (
    tester,
  ) async {
    final model = TestShellModel()..locked = true;
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.text('小鲸'), findsNothing);
    await tester.enterText(find.byKey(const Key('unlock-pin')), '0000');
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.text('PIN 不正确'), findsOneWidget);
    await tester.enterText(find.byKey(const Key('unlock-pin')), '1234');
    await tester.tap(find.text('解锁'));
    await tester.pumpAndSettle();
    expect(find.text('小鲸'), findsOneWidget);
  });

  testWidgets(
    'mobile conversation route provides back navigation and honest empty tabs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = TestShellModel();
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.text('小鲸'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer')), findsOneWidget);
      await tester.tap(find.byTooltip('返回会话列表'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('联系人'));
      await tester.pumpAndSettle();
      expect(find.text('暂无联系人'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('chat fits viewport $width at enlarged font', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = TestShellModel()..fontScale = 1.5;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.text('小鲸'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('composer')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
