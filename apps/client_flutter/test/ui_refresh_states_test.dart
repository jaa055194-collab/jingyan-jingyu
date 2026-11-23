import 'package:client_flutter/app/app_theme.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/app/status_panel.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

const _offlineEmptyDetail = '离线时发出的文字消息会先排队，联网后会自动尝试发送。';
const _offlineEmptyBefore = '离线时发出的消息会先排队，联网后自动发送。';

/// A signed-in, online account whose conversations open with no messages.
class _StatesModel extends TestShellModel {
  _StatesModel() {
    connectedAccountId = 'account-a';
    online = true;
    queuedCount = 0;
  }

  int refreshes = 0;

  @override
  Future<void> refreshConversations() async => refreshes++;

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    messages = const [];
    notifyListeners();
  }
}

Future<void> _pump(
  WidgetTester tester,
  Widget Function() body, {
  required ShellViewModel model,
  double textScale = 1,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: buildAppTheme(Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: Scaffold(
        body: ListenableBuilder(listenable: model, builder: (_, _) => body()),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pumpList(
  WidgetTester tester,
  ShellViewModel model, {
  double textScale = 1,
}) => _pump(
  tester,
  () => ConversationList(model: model, onSelected: (_) {}),
  model: model,
  textScale: textScale,
);

Future<void> _pumpChat(WidgetTester tester, ShellViewModel model) =>
    _pump(tester, () => ChatPane(model: model), model: model);

void _narrow(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 640);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

OutlinedButton _retry(WidgetTester tester) =>
    tester.widget<OutlinedButton>(find.byKey(const Key('conversations-retry')));

void main() {
  group('conversation list', () {
    testWidgets('signed out, it says the host is not connected yet', (
      tester,
    ) async {
      final model = _StatesModel()
        ..connectedAccountId = null
        ..conversations = const [];
      await _pumpList(tester, model);
      expect(
        find.byKey(const ValueKey('conversations-signed-out')),
        findsOneWidget,
      );
      expect(find.text('尚未连接宿主'), findsOneWidget);
      expect(find.text('登录宿主后，这里会显示你的聊天。'), findsOneWidget);
      expect(find.byKey(const Key('conversations-retry')), findsNothing);
    });

    testWidgets(
      'offline, it waits for the connection instead of claiming none',
      (tester) async {
        final model = _StatesModel()
          ..online = false
          ..conversations = const [];
        await _pumpList(tester, model);
        expect(
          find.byKey(const ValueKey('conversations-offline')),
          findsOneWidget,
        );
        expect(find.text('暂时离线'), findsOneWidget);
        expect(find.text('恢复连接后，会显示你的聊天。'), findsOneWidget);
        expect(find.text('暂无会话'), findsNothing);
      },
    );

    testWidgets(
      'a failed read is announced and its retry waits while locked or busy',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final model = _StatesModel()
          ..conversations = const []
          ..error = '会话读取失败';
        await _pumpList(tester, model);
        expect(
          find.byKey(const ValueKey('conversations-error')),
          findsOneWidget,
        );
        expect(find.text('没有可显示的会话'), findsOneWidget);
        expect(
          tester.getSemantics(find.text('没有可显示的会话')),
          isSemantics(isLiveRegion: true),
        );
        expect(_retry(tester).onPressed, isNotNull);
        await tester.tap(find.byKey(const Key('conversations-retry')));
        await tester.pump();
        expect(model.refreshes, 1);
        for (final (locked, busy) in [(true, false), (false, true)]) {
          model
            ..locked = locked
            ..busy = busy
            ..notifyListeners();
          await tester.pump();
          expect(
            _retry(tester).onPressed,
            isNull,
            reason: 'locked=$locked busy=$busy',
          );
        }
        semantics.dispose();
      },
    );

    testWidgets('an account with no chats says so and suggests a next step', (
      tester,
    ) async {
      final model = _StatesModel()..conversations = const [];
      await _pumpList(tester, model);
      expect(find.byKey(const ValueKey('conversations-empty')), findsOneWidget);
      expect(find.text('暂无会话'), findsOneWidget);
      expect(find.text('可以创建群聊，或等好友发来消息。'), findsOneWidget);
    });
  });

  testWidgets('the chat pane asks for a conversation until one is chosen', (
    tester,
  ) async {
    final model = _StatesModel();
    await _pumpChat(tester, model);
    expect(find.text('选择一个会话，开始聊天'), findsOneWidget);
    expect(find.byKey(const Key('composer')), findsNothing);
  });

  testWidgets(
    'an empty conversation says how sending works online and offline',
    (tester) async {
      final model = _StatesModel()..selectedConversationId = 'a';
      await _pumpChat(tester, model);
      expect(find.text('还没有消息'), findsOneWidget);
      expect(find.text('发一条消息，开始这段对话。'), findsOneWidget);
      model
        ..online = false
        ..notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('还没有消息'), findsOneWidget);
      expect(find.text(_offlineEmptyDetail), findsOneWidget);
      // Queued text can still be refused or wait for sign-in: never promise it.
      expect(find.text(_offlineEmptyBefore), findsNothing);
      expect(find.textContaining('自动发送'), findsNothing);
    },
  );

  group('status panel', () {
    Future<void> pumpPanel(WidgetTester tester, {required bool reduceMotion}) =>
        tester.pumpWidget(
          MaterialApp(
            theme: buildAppTheme(Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reduceMotion),
              child: child!,
            ),
            home: const Scaffold(
              body: StatusPanel(
                tone: StatusTone.error,
                icon: Icons.error_outline,
                title: '没能读取',
              ),
            ),
          ),
        );

    Finder fadeIn() => find.descendant(
      of: find.byType(StatusPanel),
      matching: find.byType(TweenAnimationBuilder<double>),
    );

    testWidgets('appears at once when animations are disabled', (tester) async {
      await pumpPanel(tester, reduceMotion: true);
      expect(fadeIn(), findsNothing);
      expect(find.text('没能读取'), findsOneWidget);
    });

    testWidgets('otherwise fades in and is announced from the first frame', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpPanel(tester, reduceMotion: false);
      final fade = find.descendant(
        of: fadeIn(),
        matching: find.byType(Opacity),
      );
      expect(tester.widget<Opacity>(fade.first).opacity, 0);
      expect(find.bySemanticsLabel('没能读取'), findsOneWidget);
      await tester.pump(StatusPanel.fadeDuration);
      expect(tester.widget<Opacity>(fade.first).opacity, 1);
      semantics.dispose();
    });
  });

  testWidgets('light and dark themes build from the single accent seed', (
    tester,
  ) async {
    expect(appAccentSeed, const Color(0xff16776e));
    for (final brightness in Brightness.values) {
      final theme = buildAppTheme(brightness);
      final seeded = ColorScheme.fromSeed(
        seedColor: const Color(0xff16776e),
        brightness: brightness,
      );
      expect(theme.useMaterial3, isTrue);
      expect(theme.colorScheme.brightness, brightness);
      expect(theme.colorScheme.primary, seeded.primary);
      expect(theme.colorScheme.onPrimary, seeded.onPrimary);
      expect(theme.colorScheme.secondary, seeded.secondary);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            appBar: AppBar(title: const Text('标题')),
            body: const StatusPanel(icon: Icons.inbox_outlined, title: '暂无内容'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }
    await tester.pumpWidget(WhaleChatApp(model: _StatesModel()));
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(
      app.theme!.colorScheme.primary,
      buildAppTheme(Brightness.light).colorScheme.primary,
    );
    expect(app.darkTheme!.colorScheme.brightness, Brightness.dark);
    expect(
      app.darkTheme!.colorScheme.primary,
      buildAppTheme(Brightness.dark).colorScheme.primary,
    );
  });

  group('360x640 at 1.5x text', () {
    testWidgets('every conversation list state fits', (tester) async {
      _narrow(tester);
      final model = _StatesModel()..conversations = const [];
      for (final (key, apply) in <(String, void Function())>[
        ('conversations-empty', () {}),
        ('conversations-error', () => model.error = '会话读取失败，请稍后重试'),
        ('conversations-offline', () => model.online = false),
        ('conversations-signed-out', () => model.connectedAccountId = null),
      ]) {
        apply();
        await _pumpList(tester, model, textScale: 1.5);
        expect(find.byKey(ValueKey(key)), findsOneWidget);
        expect(tester.takeException(), isNull, reason: key);
      }
    });

    testWidgets('the empty chat fits online and offline inside the shell', (
      tester,
    ) async {
      _narrow(tester);
      final model = _StatesModel()..fontScale = 1.5;
      await tester.pumpWidget(WhaleChatApp(model: model));
      await tester.pumpAndSettle();
      await tester.tap(find.text('小鲸'));
      await tester.pumpAndSettle();
      expect(find.text('还没有消息'), findsOneWidget);
      expect(tester.takeException(), isNull);
      model
        ..online = false
        ..notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text(_offlineEmptyDetail), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
