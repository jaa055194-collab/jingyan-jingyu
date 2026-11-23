import 'dart:async';

import 'package:client_flutter/app/android_private_ai_chat_port.dart';
import 'package:client_flutter/features/chat/android_private_ai_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

const _endpoint = 'https://model.example.test/v1/chat/completions';
const _otherEndpoint = 'https://other.example.test/api/chat/completions';
const _keyDraft = 'sk-test-phone-only-123';

// The widget is real; the route port stands in for the host, vault and provider.
class _Chat extends AndroidPrivateAiChatPort {
  _Chat({bool configured = true}) {
    if (configured) {
      model = 'reef/chat-v3';
      endpoint = _endpoint;
      keyConfigured = true;
      personaName = '潮汐';
      personaText = '温和地倾听，回答保持简短。';
      personaVersion = 7;
    }
  }

  @override
  String get aiName => '琉璃鲸';
  @override
  bool isCurrent = true;
  @override
  bool busy = false;
  @override
  bool online = true;
  @override
  bool initialized = true;
  @override
  String? model;
  @override
  String? endpoint;
  @override
  String? personaName;
  @override
  String? personaText;
  @override
  int? personaVersion;
  @override
  String? behaviorSnapshot;
  @override
  String? notice;
  @override
  bool keyConfigured = false;
  @override
  bool syncEnabled = false;
  @override
  List<PrivateAiExchange> exchanges = [];

  int profileReads = 0;
  final settings = <({String endpoint, String model, String? apiKey})>[];
  final sends = <String>[];
  final syncChoices = <bool>[];
  int syncCalls = 0;
  bool rejectSave = false;
  Completer<bool>? sendResult;

  void changed() => notifyListeners();

  @override
  Future<bool> loadHostProfile() async {
    ++profileReads;
    personaName = '从宿主读取的人格';
    personaText = '倾听。';
    personaVersion = 8;
    changed();
    return true;
  }

  @override
  Future<bool> configure({
    required String endpoint,
    required String model,
    String? apiKey,
  }) async {
    settings.add((endpoint: endpoint, model: model, apiKey: apiKey));
    if (rejectSave ||
        (apiKey == null && (!keyConfigured || endpoint != this.endpoint))) {
      notice = '请检查地址并为此地址输入密钥。';
      changed();
      return false;
    }
    this.model = model;
    this.endpoint = endpoint;
    keyConfigured = true;
    notice = null;
    changed();
    return true;
  }

  @override
  Future<bool> send(String text) async {
    sends.add(text);
    final sent = await (sendResult?.future ?? Future.value(true));
    if (!sent) notice = '待同步记录已满，请先同步。';
    changed();
    return sent;
  }

  @override
  Future<void> setSyncEnabled(bool enabled) async {
    syncChoices.add(enabled);
    syncEnabled = enabled;
    changed();
  }

  @override
  Future<void> sync() async => ++syncCalls;
}

Finder _key(String name) => find.byKey(ValueKey('private-ai-$name'));

Future<void> _open(
  WidgetTester tester,
  _Chat chat, {
  Size size = const Size(375, 812),
  double textScale = 1,
}) async {
  addTearDown(chat.dispose);
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff16776e)),
      ),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: AndroidPrivateAiScreen(chat: chat),
    ),
  );
  await tester.pump();
}

Future<void> _tap(WidgetTester tester, String name) async {
  await tester.ensureVisible(_key(name));
  await tester.tap(_key(name));
  await tester.pumpAndSettle();
}

Future<void> _menu(WidgetTester tester, String item) async {
  await _tap(tester, 'menu');
  await _tap(tester, item);
}

Future<void> _enter(WidgetTester tester, String name, String text) async {
  await tester.ensureVisible(_key(name));
  await tester.enterText(_key(name), text);
  await tester.pumpAndSettle();
}

TextField _field(WidgetTester tester, String name) =>
    tester.widget<TextField>(_key(name));

void main() {
  testWidgets('the chat names the current model and persona before any reply', (
    tester,
  ) async {
    final chat = _Chat();
    await _open(tester, chat);
    expect(find.text('私聊我的 AI'), findsOneWidget);
    expect(find.textContaining('琉璃鲸').hitTestable(), findsWidgets);
    expect(find.text('模型：reef/chat-v3').hitTestable(), findsOneWidget);
    expect(find.textContaining('人格：潮汐').hitTestable(), findsOneWidget);
    expect(find.textContaining('本机不运行大模型'), findsWidgets);
    expect(chat.profileReads, 0);
    await _menu(tester, 'persona');
    expect(find.textContaining('版本 7').hitTestable(), findsWidgets);
    expect(find.text('温和地倾听，回答保持简短。'), findsOneWidget);
  });

  testWidgets(
    'cached host behavior is visible offline without implying local execution',
    (tester) async {
      final chat = _Chat()
        ..online = false
        ..behaviorSnapshot = '社交等级：L3\n规则问候：关闭';
      await _open(tester, chat);
      await _menu(tester, 'persona');
      expect(find.text('宿主活人感设置 · 上次读取'), findsOneWidget);
      expect(find.textContaining('社交等级：L3'), findsOneWidget);
      expect(find.text('本机直连不运行宿主的问候或主动联系。'), findsOneWidget);
      expect(chat.profileReads, 0);
    },
  );

  testWidgets(
    'missing configuration disables send and profile lookup requires a disclosed action',
    (tester) async {
      final chat = _Chat(configured: false);
      await _open(tester, chat);
      expect(chat.profileReads, 0);
      expect(find.text('模型：未配置'), findsOneWidget);
      expect(find.text('人格：未加载'), findsOneWidget);
      expect(find.textContaining('已就绪'), findsNothing);
      expect(tester.widget<IconButton>(_key('send')).onPressed, isNull);
      expect(find.textContaining('未登记时会建立档案'), findsWidgets);
      expect(find.textContaining('不会开启宿主私聊授权'), findsWidgets);
      await _tap(tester, 'load-profile');
      expect(chat.profileReads, 1);
      expect(find.textContaining('人格：从宿主读取的人格'), findsOneWidget);
      expect(tester.widget<IconButton>(_key('send')).onPressed, isNull);
    },
  );

  testWidgets(
    'the secondary menu welcome explains private scope and key handling',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat);
      await _tap(tester, 'menu');
      for (final item in ['欢迎与说明', '模型设置', '查看人格', '会话同步']) {
        expect(find.text(item), findsOneWidget);
      }
      await _tap(tester, 'welcome');
      final dialog = find.byType(AlertDialog);
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('只与你自己已登记的 AI 对话'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('密钥只在本机加密保存'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('不会开启宿主私聊授权'),
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'models disclose provider egress and use a masked credential field',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final chat = _Chat(configured: false);
      await _open(tester, chat);
      await _menu(tester, 'model-settings');
      final dialog = find.byType(AlertDialog);
      for (final disclosure in ['最近最多 5 轮', '不含群聊或与他人的消息', '宿主离线', '仍需网络']) {
        expect(
          find.descendant(
            of: dialog,
            matching: find.textContaining(disclosure),
          ),
          findsWidgets,
        );
      }
      await _enter(tester, 'endpoint', _endpoint);
      await _enter(tester, 'model', '实际模型');
      await _enter(tester, 'api-key', _keyDraft);
      expect(_field(tester, 'api-key').obscureText, isTrue);
      final editable = find.descendant(
        of: _key('api-key'),
        matching: find.byType(EditableText),
      );
      final node = tester.semantics.find(editable);
      expect(node.flagsCollection.isObscured, isTrue);
      expect(node.value, isNot(contains(_keyDraft)));
      expect(node.label, isNot(contains(_keyDraft)));
      semantics.dispose();
      expect(chat.settings, isEmpty);
      await _tap(tester, 'configure');
      expect(chat.settings, [
        (endpoint: _endpoint, model: '实际模型', apiKey: _keyDraft),
      ]);
      expect(_key('api-key'), findsNothing);
      expect(find.text('模型：实际模型'), findsOneWidget);
    },
  );

  testWidgets(
    'insecure, incomplete or credential-bearing addresses are not submitted',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat);
      await _menu(tester, 'model-settings');
      await _enter(tester, 'api-key', _keyDraft);
      for (final invalid in [
        'http://model.example.test/v1/chat/completions',
        'https://model.example.test/v1',
        'https://model.example.test/v1/chat/completions?debug=1',
        'https://model.example.test/v1/chat/completions#fragment',
        'https://login@model.example.test/v1/chat/completions',
      ]) {
        await _enter(tester, 'endpoint', invalid);
        await _tap(tester, 'configure');
        expect(_field(tester, 'endpoint').decoration!.errorText, isNotEmpty);
        expect(chat.settings, isEmpty);
      }
    },
  );

  testWidgets(
    'only the controller can reuse the saved key, and rejected changes retain the draft',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat);
      await _menu(tester, 'model-settings');
      expect(_field(tester, 'endpoint').controller!.text, _endpoint);
      expect(_field(tester, 'model').controller!.text, 'reef/chat-v3');
      expect(_field(tester, 'api-key').controller!.text, isEmpty);
      await _enter(tester, 'model', '模型改名');
      await _tap(tester, 'configure');
      expect(chat.settings.single, (
        endpoint: _endpoint,
        model: '模型改名',
        apiKey: null,
      ));
      expect(_key('api-key'), findsNothing);

      await _menu(tester, 'model-settings');
      await _enter(tester, 'endpoint', _otherEndpoint);
      await _enter(tester, 'model', '另一模型');
      await _tap(tester, 'configure');
      expect(chat.settings.last, (
        endpoint: _otherEndpoint,
        model: '另一模型',
        apiKey: null,
      ));
      expect(_field(tester, 'endpoint').controller!.text, _otherEndpoint);
      expect(_field(tester, 'model').controller!.text, '另一模型');
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('请检查地址并为此地址输入密钥。'),
        ),
        findsOneWidget,
      );

      await _enter(tester, 'api-key', _keyDraft);
      chat.rejectSave = true;
      await _tap(tester, 'configure');
      expect(_field(tester, 'api-key').controller!.text, _keyDraft);
      chat.rejectSave = false;
      await _tap(tester, 'configure');
      expect(chat.settings.last, (
        endpoint: _otherEndpoint,
        model: '另一模型',
        apiKey: _keyDraft,
      ));
      expect(_key('api-key'), findsNothing);
    },
  );

  testWidgets(
    'host offline sends directly, one at a time, and only success clears the draft',
    (tester) async {
      final chat = _Chat()..online = false;
      await _open(tester, chat);
      expect(find.textContaining('宿主离线'), findsWidgets);
      await _enter(tester, 'draft', '  可以听到吗？  ');
      final result = chat.sendResult = Completer<bool>();
      await tester.tap(_key('send'));
      await tester.pump();
      expect(tester.widget<IconButton>(_key('send')).onPressed, isNull);
      await tester.tap(_key('send'));
      expect(chat.sends, ['可以听到吗？']);
      result.complete(false);
      await tester.pumpAndSettle();
      expect(_field(tester, 'draft').controller!.text, '  可以听到吗？  ');
      expect(find.text('待同步记录已满，请先同步。'), findsOneWidget);
      chat.sendResult = null;
      await _tap(tester, 'send');
      expect(chat.sends, ['可以听到吗？', '可以听到吗？']);
      expect(_field(tester, 'draft').controller!.text, isEmpty);
    },
  );

  testWidgets(
    'pending local and server-confirmed exchanges have distinct status',
    (tester) async {
      final chat = _Chat()
        ..exchanges = [
          (user: '服务器已收录', assistant: '第一条回复', seq: 7),
          (user: '仍在本机', assistant: '第二条回复', seq: null),
        ];
      await _open(tester, chat);
      expect(find.text('第一条回复'), findsOneWidget);
      expect(find.text('第二条回复'), findsOneWidget);
      expect(find.text('已同步 #7'), findsOneWidget);
      expect(find.text('待同步（仅本机）'), findsOneWidget);
    },
  );

  testWidgets(
    'sync is opt-in and manual upload requires both consent and an online host',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat);
      await _menu(tester, 'sync-settings');
      expect(tester.widget<SwitchListTile>(_key('sync-switch')).value, isFalse);
      expect(tester.widget<FilledButton>(_key('sync-now')).onPressed, isNull);
      expect(find.textContaining('不上传 API 密钥'), findsWidgets);
      expect(find.textContaining('约 48 轮'), findsWidgets);
      await _tap(tester, 'sync-switch');
      expect(chat.syncChoices, [true]);
      expect(chat.syncCalls, 0);
      chat.online = false;
      chat.changed();
      await tester.pump();
      expect(tester.widget<FilledButton>(_key('sync-now')).onPressed, isNull);
      chat.online = true;
      chat.busy = true;
      chat.changed();
      await tester.pump();
      expect(
        tester.widget<SwitchListTile>(_key('sync-switch')).onChanged,
        isNull,
      );
      expect(tester.widget<FilledButton>(_key('sync-now')).onPressed, isNull);
      chat.busy = false;
      chat.changed();
      await tester.pump();
      await _tap(tester, 'sync-now');
      expect(chat.syncCalls, 1);
    },
  );

  testWidgets(
    'invalidating the session retires an already open credential dialog',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat);
      await _menu(tester, 'model-settings');
      await _enter(tester, 'api-key', _keyDraft);
      chat.isCurrent = false;
      chat.changed();
      await tester.pumpAndSettle();
      expect(_key('api-key'), findsNothing);
      expect(_key('configure'), findsNothing);
      expect(find.textContaining('会话已失效'), findsWidgets);
      expect(chat.settings, isEmpty);
      // A transiently restored guard cannot resurrect sensitive drafts.
      chat.isCurrent = true;
      chat.changed();
      await tester.pumpAndSettle();
      expect(_key('api-key'), findsNothing);
      expect(_key('draft'), findsNothing);
    },
  );

  testWidgets(
    'the chat and setup actions fit a narrow viewport above the keyboard',
    (tester) async {
      final chat = _Chat();
      await _open(tester, chat, size: const Size(320, 568), textScale: 1.2);
      await _enter(tester, 'draft', '你好');
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();
      expect(_key('send').hitTestable(), findsOneWidget);
      expect(tester.getBottomLeft(_key('send')).dy, lessThanOrEqualTo(268));
      expect(tester.takeException(), isNull);
      await _menu(tester, 'model-settings');
      expect(_key('configure').hitTestable(), findsOneWidget);
      await _enter(tester, 'api-key', _keyDraft);
      await _tap(tester, 'configure');
      expect(chat.settings.single.apiKey, _keyDraft);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'the local pending cap blocks new sends and keeps every pending turn',
    (tester) async {
      final chat = _Chat()
        ..exchanges = [
          for (var index = 0; index < 48; index++)
            (user: '待同步问题$index', assistant: '待同步回复$index', seq: null),
        ];
      await _open(tester, chat);
      expect(find.textContaining('本机待同步 48 轮（上限约 48）'), findsOneWidget);
      expect(find.textContaining('本机待同步记录已满'), findsWidgets);
      await _enter(tester, 'draft', '不应发出');
      expect(tester.widget<IconButton>(_key('send')).onPressed, isNull);
      expect(chat.sends, isEmpty);
      expect(chat.exchanges, hasLength(48));
    },
  );

  testWidgets('the route-owned port is not disposed with the screen', (
    tester,
  ) async {
    final chat = _Chat();
    await _open(tester, chat);
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('其他页面'))),
    );
    await tester.pump();
    expect(() => chat.changed(), returnsNormally);
  });
}
