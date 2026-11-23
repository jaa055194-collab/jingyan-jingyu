import 'dart:async';

import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/settings/android_ai_directory_screen.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

const _failure = '我的AI列表读取失败，请重试刷新';
const _chatAvailable = '直连模型服务；设置好后，宿主离线也能用';
const _chat = 'android-ai-open-chat-ai-a';
const _config = 'android-ai-open-config-ai-a';

class _DirectoryModel extends TestShellModel {
  _DirectoryModel() {
    connectedAccountId = 'owner-a';
    online = true;
    queuedCount = 0;
  }

  Object? interaction = Object();
  List<ShellOwnedAi> accounts = const [
    ShellOwnedAi(accountId: 'ai-a', displayName: '潮汐', disabled: false),
  ];
  bool loaded = true;
  Completer<void>? hold;
  String? failWith;
  int loads = 0;

  @override
  Object? get ownAiDirectContext => interaction;
  @override
  bool get ownAiLoaded => loaded;
  @override
  List<ShellOwnedAi> get ownAiAccounts => accounts;

  // Like the runtime, a read clears the previous error and reports its own.
  @override
  Future<void> loadOwnAi() async {
    loads++;
    error = null;
    notifyListeners();
    await hold?.future;
    if (failWith case final message?) {
      error = message;
    } else {
      loaded = true;
    }
    notifyListeners();
  }
}

Finder _key(String name) => find.byKey(Key(name));

Future<List<String>> _open(WidgetTester tester, _DirectoryModel model) async {
  final opened = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: AndroidAiDirectoryScreen(
        model: model,
        onOpenAi: (ai, _) => opened.add('config:${ai.accountId}'),
        onOpenPrivateChat: (ai, _) => opened.add('chat:${ai.accountId}'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

String? _subtitle(WidgetTester tester, String key) =>
    (tester.widget<ListTile>(_key(key)).subtitle as Text?)?.data;

bool _enabled(WidgetTester tester, String key) =>
    tester.widget<ListTile>(_key(key)).enabled;

void main() {
  testWidgets('refresh shows progress on its own button until the read ends', (
    tester,
  ) async {
    final model = _DirectoryModel()..hold = Completer<void>();
    await _open(tester, model);
    final refresh = _key('android-ai-directory-refresh');
    await tester.tap(refresh);
    await tester.pump();
    expect(model.loads, 1);
    expect(
      find.descendant(of: refresh, matching: find.text('正在刷新…')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: refresh,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    expect(tester.widget<TextButton>(refresh).onPressed, isNull);
    await tester.tap(refresh, warnIfMissed: false);
    expect(model.loads, 1, reason: 'a running refresh is not repeated');
    model.hold!.complete();
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: refresh, matching: find.text('刷新我的 AI')),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);
    expect(_key('android-ai-directory-error'), findsNothing);
  });

  testWidgets('a failed refresh stays on the page with retry and dismiss', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final model = _DirectoryModel()..failWith = _failure;
    await _open(tester, model);
    await tester.tap(_key('android-ai-directory-refresh'));
    await tester.pumpAndSettle();
    final card = _key('android-ai-directory-error');
    expect(card, findsOneWidget);
    expect(
      find.descendant(of: card, matching: find.text('没能刷新我的 AI')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text(_failure)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: card, matching: find.text('关闭')),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.text('没能刷新我的 AI')),
      isSemantics(isLiveRegion: true),
    );

    await tester.tap(_key('android-ai-directory-retry'));
    await tester.pumpAndSettle();
    expect(model.loads, 2);
    expect(card, findsOneWidget, reason: 'a second failure stays visible');

    await tester.tap(_key('android-ai-directory-error-dismiss'));
    await tester.pumpAndSettle();
    expect(card, findsNothing);
    expect(model.loads, 2, reason: 'dismissing does not read again');
    expect(model.error, isNull, reason: 'the same text is not left behind');
    final refresh = _key('android-ai-directory-refresh');
    expect(tester.widget<TextButton>(refresh).onPressed, isNotNull);

    await tester.tap(refresh);
    await tester.pumpAndSettle();
    expect(model.loads, 3);
    expect(card, findsOneWidget, reason: 'a later failure shows again');

    model.failWith = null;
    await tester.tap(_key('android-ai-directory-retry'));
    await tester.pumpAndSettle();
    expect(model.loads, 4);
    expect(card, findsNothing);
    semantics.dispose();
  });

  testWidgets(
    'offline, the page says what still works and what needs the host',
    (tester) async {
      final model = _DirectoryModel()..online = false;
      await _open(tester, model);
      final note = _key('android-ai-directory-offline');
      expect(note, findsOneWidget);
      expect(
        find.descendant(of: note, matching: find.textContaining('宿主未连接')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<TextButton>(_key('android-ai-directory-refresh'))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<FilledButton>(_key('android-ai-directory-create'))
            .onPressed,
        isNull,
      );
      model
        ..online = true
        ..notifyListeners();
      await tester.pumpAndSettle();
      expect(note, findsNothing);
    },
  );

  testWidgets('entry subtitles say why an entry cannot be used', (
    tester,
  ) async {
    final model = _DirectoryModel();
    await _open(tester, model);
    expect(find.text('在本机与它对话；宿主离线时也能用'), findsNothing);
    expect(_subtitle(tester, _chat), _chatAvailable);
    expect(_subtitle(tester, _config), '读取和修改宿主上保存的配置');
    expect(_enabled(tester, _chat), isTrue);
    expect(_enabled(tester, _config), isTrue);

    model
      ..online = false
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(_subtitle(tester, _config), '需要连接宿主');
    expect(_enabled(tester, _config), isFalse);
    expect(_subtitle(tester, _chat), _chatAvailable);
    expect(_enabled(tester, _chat), isTrue);

    model
      ..online = true
      ..busy = true
      ..notifyListeners();
    await tester.pumpAndSettle();
    for (final key in [_chat, _config]) {
      expect(_subtitle(tester, key), '请等当前操作完成');
      expect(_enabled(tester, key), isFalse);
    }

    model
      ..busy = false
      ..interaction = null
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(_subtitle(tester, _chat), '暂时无法打开');
    expect(_subtitle(tester, _config), '暂时无法使用');
    expect(_enabled(tester, _chat), isFalse);
    expect(_enabled(tester, _config), isFalse);
  });

  testWidgets('an unread or empty list explains itself', (tester) async {
    final model = _DirectoryModel()
      ..accounts = const []
      ..loaded = false;
    await _open(tester, model);
    expect(_key('android-ai-directory-unloaded'), findsOneWidget);
    expect(find.text('点“刷新我的 AI”，从宿主读取。'), findsOneWidget);
    model
      ..online = false
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('连接宿主后，点“刷新我的 AI”读取。'), findsOneWidget);
    model
      ..online = true
      ..notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(_key('android-ai-directory-refresh'));
    await tester.pumpAndSettle();
    expect(_key('android-ai-directory-unloaded'), findsNothing);
    expect(_key('android-ai-directory-empty'), findsOneWidget);
    expect(find.text('你还没有 AI 账户'), findsOneWidget);
  });

  testWidgets('a lock replaces the page with a quiet notice', (tester) async {
    final model = _DirectoryModel();
    await _open(tester, model);
    model
      ..locked = true
      ..notifyListeners();
    await tester.pumpAndSettle();
    expect(find.text('账号或解锁状态已变更，请返回后重新打开。'), findsOneWidget);
    expect(_key(_chat), findsNothing);
    expect(_key(_config), findsNothing);
  });
}
