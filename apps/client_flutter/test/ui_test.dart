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
  bool chatEntered = false;
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
  @override
  String? connectedAccountId;
  bool failConnect = false;
  int connectCalls = 0;
  Map<String, String>? suppliedCredentials;
  @override
  Future<void> connectHost(
    String address,
    String invite, {
    String displayName = '',
    String password = '',
    String deviceName = '',
    String accountId = '',
  }) async {
    connectCalls++;
    suppliedCredentials = {
      'address': address,
      'invite': invite,
      'displayName': displayName,
      'password': password,
      'deviceName': deviceName,
      'accountId': accountId,
    };
    error = failConnect ? '宿主尚未开放账户接入' : null;
    if (!failConnect) {
      connectedAccountId = accountId.isEmpty ? 'created-account-42' : accountId;
    }
    notifyListeners();
  }

  @override
  Future<void> enterChat() async {
    chatEntered = true;
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
  List<ShellOwnedAi> get ownAiAccounts => const [];
  @override
  String? get ownAiNotice => null;
  @override
  Object? get ownAiSessionContext => connectedAccountId;
  @override
  bool get ownAiLoaded => false;
  @override
  Future<void> loadOwnAi() async {}
  @override
  Future<void> createOwnAi(String displayName) async {}

  @override
  bool get canAddMembersToSelectedGroup => false;
  @override
  Future<void> createGroup(String name) async {}
  @override
  Future<void> refreshConversations() async {}
  @override
  Future<void> addGroupMember(String groupId, String accountId) async {}

  @override
  bool get canMentionAi => false;
  @override
  Future<void> sendMentionedMessage({
    required String conversationId,
    required String expectedDraft,
    required String aiAccountId,
  }) async {}

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

Future<void> enterOnboardingField(
  WidgetTester tester,
  String key,
  String value,
) async {
  final field = find.byKey(Key(key));
  expect(field, findsOneWidget);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
  await tester.pumpAndSettle();
}

Future<void> fillNewAccountCredentials(WidgetTester tester) async {
  await enterOnboardingField(tester, 'host-display-name', '小鲸用户');
  await enterOnboardingField(tester, 'host-device-name', '我的电脑');
  await enterOnboardingField(tester, 'host-password', ' secret password ');
}

Future<void> submitHostConnection(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.text('连接宿主'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('连接宿主'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('连接宿主'));
  await tester.pumpAndSettle();
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
  testWidgets(
    'onboarding rejects host and invite without required credentials',
    (tester) async {
      final model = TestShellModel()..onboarded = false;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.enterText(
        find.byKey(const Key('host-address')),
        'http://localhost:8080',
      );
      await tester.enterText(find.byKey(const Key('host-invite')), 'invite');
      await submitHostConnection(tester);
      expect(model.connectCalls, 0);
      expect(find.text('选择你的形象'), findsNothing);
    },
  );

  testWidgets('new account credentials are obscured and forwarded on success', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await enterOnboardingField(
      tester,
      'host-address',
      ' https://host.example ',
    );
    await enterOnboardingField(tester, 'host-invite', ' invite-code ');
    await fillNewAccountCredentials(tester);
    final password = tester.widget<TextField>(
      find.byKey(const Key('host-password')),
    );
    final passwordController = password.controller!;
    expect(password.obscureText, isTrue);
    expect(password.enableSuggestions, isFalse);
    expect(password.autocorrect, isFalse);
    await submitHostConnection(tester);
    expect(model.suppliedCredentials, {
      'address': 'https://host.example',
      'invite': 'invite-code',
      'displayName': '小鲸用户',
      'password': ' secret password ',
      'deviceName': '我的电脑',
      'accountId': '',
    });
    expect(find.text('选择你的形象'), findsOneWidget);
    expect(passwordController.text, isEmpty);
  });

  testWidgets('existing account signs in without invite or display name', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await enterOnboardingField(tester, 'host-address', 'https://host.example');
    await tester.ensureVisible(find.text('已有账户'));
    await tester.tap(find.text('已有账户'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-invite')), findsNothing);
    expect(find.byKey(const Key('host-display-name')), findsNothing);
    await enterOnboardingField(tester, 'host-account-id', ' account-7 ');
    await enterOnboardingField(tester, 'host-device-name', ' 手机 ');
    await enterOnboardingField(tester, 'host-password', 'existing-secret');
    await submitHostConnection(tester);
    expect(model.suppliedCredentials, {
      'address': 'https://host.example',
      'invite': '',
      'displayName': '',
      'password': 'existing-secret',
      'deviceName': '手机',
      'accountId': 'account-7',
    });
    expect(find.text('选择你的形象'), findsOneWidget);
  });

  for (final existing in [false, true]) {
    testWidgets(
      'connected account ID is selectable on character and room steps existing=$existing',
      (tester) async {
        final model = TestShellModel()..onboarded = false;
        await tester.pumpWidget(WhaleChatApp(model: model));
        await enterOnboardingField(
          tester,
          'host-address',
          'https://host.example',
        );
        if (existing) {
          await tester.ensureVisible(find.text('已有账户'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('已有账户'));
          await tester.pumpAndSettle();
          await enterOnboardingField(
            tester,
            'host-account-id',
            'existing-account-7',
          );
          await enterOnboardingField(tester, 'host-device-name', '手机');
          await enterOnboardingField(tester, 'host-password', 'short');
        } else {
          await enterOnboardingField(tester, 'host-invite', 'invite');
          await fillNewAccountCredentials(tester);
        }
        expect(find.textContaining('账号 ID：'), findsNothing);
        await submitHostConnection(tester);
        final expectedId = existing
            ? 'existing-account-7'
            : 'created-account-42';
        final selectableId = find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText && widget.data == '账号 ID：$expectedId',
        );
        expect(selectableId, findsOneWidget);
        expect(
          tester
              .widget<SelectableText>(selectableId)
              .enableInteractiveSelection,
          isTrue,
        );
        expect(find.text('保存账号ID可用于已有账号登录'), findsOneWidget);
        await tester.ensureVisible(find.text('下一步'));
        await tester.tap(find.text('下一步'));
        await tester.pumpAndSettle();
        expect(selectableId, findsOneWidget);
        expect(find.text('保存账号ID可用于已有账号登录'), findsOneWidget);
      },
    );
  }

  for (final missing in [
    'host-address',
    'host-invite',
    'host-display-name',
    'host-device-name',
    'host-password',
  ]) {
    testWidgets('new account never connects with missing $missing', (
      tester,
    ) async {
      final model = TestShellModel()..onboarded = false;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await enterOnboardingField(
        tester,
        'host-address',
        'https://host.example',
      );
      await enterOnboardingField(tester, 'host-invite', 'invite');
      await fillNewAccountCredentials(tester);
      await enterOnboardingField(
        tester,
        missing,
        missing == 'host-password' ? '' : '   ',
      );
      await submitHostConnection(tester);
      expect(model.connectCalls, 0);
      expect(find.text('选择你的形象'), findsNothing);
    });
  }

  for (final invalid in [
    ('host-password', 'p' * 11),
    ('host-password', 'p' * 1025),
    ('host-display-name', 'n' * 101),
    ('host-device-name', 'd' * 101),
  ]) {
    testWidgets(
      'new account rejects host limit ${invalid.$1} ${invalid.$2.length}',
      (tester) async {
        final model = TestShellModel()..onboarded = false;
        await tester.pumpWidget(WhaleChatApp(model: model));
        await enterOnboardingField(
          tester,
          'host-address',
          'https://host.example',
        );
        await enterOnboardingField(tester, 'host-invite', 'invite');
        await fillNewAccountCredentials(tester);
        await enterOnboardingField(tester, invalid.$1, invalid.$2);
        await submitHostConnection(tester);
        expect(model.connectCalls, 0);
        expect(find.text('选择你的形象'), findsNothing);
      },
    );
  }

  for (final length in [12, 1024]) {
    testWidgets(
      'new account accepts host boundary password $length and names100',
      (tester) async {
        final model = TestShellModel()..onboarded = false;
        await tester.pumpWidget(WhaleChatApp(model: model));
        await enterOnboardingField(
          tester,
          'host-address',
          'https://host.example',
        );
        await enterOnboardingField(tester, 'host-invite', 'invite');
        await enterOnboardingField(tester, 'host-display-name', 'n' * 100);
        await enterOnboardingField(tester, 'host-device-name', 'd' * 100);
        await enterOnboardingField(tester, 'host-password', 'p' * length);
        await submitHostConnection(tester);
        expect(model.connectCalls, 1);
        expect(model.suppliedCredentials!['password'], 'p' * length);
      },
    );
  }

  testWidgets(
    'existing password allows short value but rejects above host maximum',
    (tester) async {
      final model = TestShellModel()..onboarded = false;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await enterOnboardingField(
        tester,
        'host-address',
        'https://host.example',
      );
      await tester.ensureVisible(find.text('已有账户'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('已有账户'));
      await tester.pumpAndSettle();
      await enterOnboardingField(tester, 'host-account-id', 'account-7');
      await enterOnboardingField(tester, 'host-device-name', '手机');
      await enterOnboardingField(tester, 'host-password', 'p' * 1025);
      await submitHostConnection(tester);
      expect(model.connectCalls, 0);
      await enterOnboardingField(tester, 'host-password', 'short');
      await submitHostConnection(tester);
      expect(model.connectCalls, 1);
      expect(model.suppliedCredentials!['password'], 'short');
    },
  );

  testWidgets('invalid host and blank existing account never connect', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await enterOnboardingField(tester, 'host-address', 'https:///missing-host');
    await enterOnboardingField(tester, 'host-invite', 'invite');
    await fillNewAccountCredentials(tester);
    await submitHostConnection(tester);
    expect(model.connectCalls, 0);
    await enterOnboardingField(tester, 'host-address', 'https://host.example');
    await tester.ensureVisible(find.text('已有账户'));
    await tester.tap(find.text('已有账户'));
    await tester.pumpAndSettle();
    await enterOnboardingField(tester, 'host-account-id', '   ');
    await submitHostConnection(tester);
    expect(model.connectCalls, 0);
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
    await fillNewAccountCredentials(tester);
    final passwordController = tester
        .widget<TextField>(find.byKey(const Key('host-password')))
        .controller!;
    await submitHostConnection(tester);
    expect(find.text('宿主尚未开放账户接入'), findsOneWidget);
    expect(find.text('连接宿主'), findsOneWidget);
    expect(find.text('选择你的形象'), findsNothing);
    expect(passwordController.text, ' secret password ');
    model.failConnect = false;
    await submitHostConnection(tester);
    expect(model.connectCalls, 2);
    expect(model.error, isNull);
    expect(find.text('选择你的形象'), findsOneWidget);
    expect(passwordController.text, isEmpty);
  });

  testWidgets(
    'authenticated user can defer world setup and reach the chat shell',
    (tester) async {
      final model = TestShellModel()..onboarded = false;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await enterOnboardingField(
        tester,
        'host-address',
        'https://host.example',
      );
      await enterOnboardingField(tester, 'host-invite', 'invite');
      await fillNewAccountCredentials(tester);
      await submitHostConnection(tester);
      expect(find.text('选择你的形象'), findsOneWidget);
      expect(find.byKey(const Key('defer-world-setup')), findsOneWidget);
      await tester.tap(find.byKey(const Key('defer-world-setup')));
      await tester.pumpAndSettle();
      expect(model.chatEntered, isTrue);
      expect(model.onboarded, isFalse);
      expect(find.text('小鲸'), findsOneWidget);
      expect(find.text('选择你的形象'), findsNothing);
    },
  );

  testWidgets('world setup remains explicitly optional from the world tab', (
    tester,
  ) async {
    final model = TestShellModel()
      ..onboarded = false
      ..chatEntered = true
      ..connectedAccountId = 'account-9';
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('世界'));
    await tester.pumpAndSettle();
    expect(find.text('世界与形象'), findsOneWidget);
    expect(find.text('设置形象与房间（可选）'), findsOneWidget);
    await tester.tap(find.text('设置形象与房间（可选）'));
    await tester.pumpAndSettle();
    expect(find.text('选择你的形象'), findsOneWidget);
    expect(find.byKey(const Key('defer-world-setup')), findsOneWidget);
  });

  for (final event in ['lock', 'logout']) {
    testWidgets('optional world route shields account setup after $event', (
      tester,
    ) async {
      final model = TestShellModel()
        ..onboarded = false
        ..chatEntered = true
        ..connectedAccountId = 'account-9';
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.tap(find.text('世界'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置形象与房间（可选）'));
      await tester.pumpAndSettle();
      expect(find.text('账号 ID：account-9'), findsOneWidget);
      if (event == 'lock') {
        model.locked = true;
      } else {
        model.connectedAccountId = null;
        model.chatEntered = false;
      }
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('账号 ID：account-9'), findsNothing);
      expect(find.text('选择你的形象'), findsNothing);
      expect(find.byKey(const Key('defer-world-setup')), findsNothing);
      expect(
        event == 'lock'
            ? find.byKey(const Key('unlock-pin'))
            : find.byKey(const Key('host-address')),
        findsOneWidget,
      );
      model.locked = false;
      model.connectedAccountId = event == 'lock' ? 'account-9' : 'account-10';
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('选择你的形象'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('optional world action fits a short mobile viewport', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 350);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final model = TestShellModel()
      ..onboarded = false
      ..chatEntered = true
      ..connectedAccountId = 'account-9'
      ..fontScale = 1.5;
    await tester.pumpWidget(WhaleChatApp(model: model));
    await tester.tap(find.text('世界'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('设置形象与房间（可选）'));
    expect(find.text('设置形象与房间（可选）'), findsOneWidget);
  });

  testWidgets('restored pending setup returns to credentials after logout', (
    tester,
  ) async {
    final model = TestShellModel()
      ..onboarded = false
      ..connectedAccountId = 'account-9';
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.text('选择你的形象'), findsOneWidget);
    model.connectedAccountId = null;
    model.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('host-address')), findsOneWidget);
    expect(find.text('选择你的形象'), findsNothing);
  });

  testWidgets('deferred flag alone never opens unauthenticated chat', (
    tester,
  ) async {
    final model = TestShellModel()
      ..onboarded = false
      ..chatEntered = true;
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.text('连接你的宿主'), findsOneWidget);
    expect(find.text('好友'), findsNothing);
  });

  testWidgets('deferring world setup is unavailable before authentication', (
    tester,
  ) async {
    final model = TestShellModel()..onboarded = false;
    await tester.pumpWidget(WhaleChatApp(model: model));
    expect(find.text('连接你的宿主'), findsOneWidget);
    expect(find.byKey(const Key('defer-world-setup')), findsNothing);
    expect(model.chatEntered, isFalse);
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
    await fillNewAccountCredentials(tester);
    await submitHostConnection(tester);
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
    'mobile conversation route provides back navigation and honest module tabs',
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

      // Contacts is now a real module surface with an honest empty state: the
      // host exposes no friend-list route yet, so no contacts are fabricated.
      await tester.tap(find.text('联系人'));
      await tester.pumpAndSettle();
      expect(find.text('宿主未提供好友列表路由；接入好友列表后可在此显示。'), findsOneWidget);

      // Inbox is likewise a real module surface with an honest unavailable state
      // (post PR#101 copy): it lists the current gap and what appears once wired.
      await tester.tap(find.text('收件箱'));
      await tester.pumpAndSettle();
      expect(find.text('当前缺口：宿主未提供收件箱/通知路由。'), findsOneWidget);
      expect(find.text('接入后此处将显示邀请与通知；数据来自宿主实时读取。'), findsOneWidget);

      // 动态 is now the CreativeScreen module surface; with no host connection
      // wired it reports an honest unbound state instead of inventing content.
      await tester.tap(find.text('动态'));
      await tester.pumpAndSettle();
      expect(find.text('创作内容需要接入宿主连接后显示；宿主读取接口已就绪。'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [375.0, 768.0, 1280.0]) {
    testWidgets('onboarding credentials fit viewport $width at enlarged font', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final model = TestShellModel()
        ..onboarded = false
        ..fontScale = 1.5;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await enterOnboardingField(
        tester,
        'host-address',
        'https://host.example',
      );
      await enterOnboardingField(tester, 'host-invite', 'invite');
      await fillNewAccountCredentials(tester);
      await submitHostConnection(tester);
      expect(model.connectCalls, 1);
      expect(find.text('选择你的形象'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

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
