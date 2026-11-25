import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/features/chat/chat_pane.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

class _LongHistoryModel extends TestShellModel {
  _LongHistoryModel({this.deferHistory = false}) {
    connectedAccountId = 'synthetic-owner';
    online = true;
    queuedCount = 0;
    themeMode = ThemeMode.light;
    conversations = const [
      ShellConversation(id: 'ai', title: '示例 AI', kind: 'direct'),
      ShellConversation(id: 'friend', title: '示例好友', kind: 'direct'),
      ShellConversation(id: 'group', title: '示例群聊', kind: 'group'),
    ];
  }

  final bool deferHistory;

  @override
  Future<void> selectConversation(String id) async {
    selectedConversationId = id;
    if (deferHistory) {
      messages = [];
      notifyListeners();
    } else {
      receiveHistory();
    }
  }

  void receiveHistory() {
    final id = selectedConversationId!;
    messages = [
      for (var number = 1; number <= 501; number++)
        ShellMessage(
          id: '$id-$number',
          text: '示例 $id 第 $number 条',
          outgoing: number.isEven,
        ),
    ];
    notifyListeners();
  }
}

Future<void> _open(WidgetTester tester, String conversation) async {
  await tester.tap(find.byKey(ValueKey(conversation)));
  await tester.pumpAndSettle();
}

Finder _visible(String id, int number) =>
    find.text('示例 $id 第 $number 条').hitTestable();

Finder get _history =>
    find.descendant(of: find.byType(ChatPane), matching: find.byType(ListView));

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  for (final id in ['ai', 'friend', 'group']) {
    testWidgets('opening $id shows newest in chronological order', (
      tester,
    ) async {
      _setViewport(tester, const Size(390, 844));
      await tester.pumpWidget(WhaleChatApp(model: _LongHistoryModel()));
      await _open(tester, id);

      final latest = _visible(id, 501);
      expect(latest, findsOneWidget);
      expect(_visible(id, 1), findsNothing);
      expect(
        tester.getCenter(_visible(id, 500)).dy,
        lessThan(tester.getCenter(latest).dy),
      );
    });
  }

  testWidgets('opening a mobile chat again resets a scrolled history', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    await tester.pumpWidget(WhaleChatApp(model: _LongHistoryModel()));
    await _open(tester, 'ai');
    await tester.drag(_history, const Offset(0, 470));
    await tester.pumpAndSettle();
    expect(_visible('ai', 501), findsNothing);
    expect(_visible('ai', 490), findsOneWidget);
    await tester.tap(find.byTooltip('返回会话列表'));
    await tester.pumpAndSettle();
    await _open(tester, 'ai');
    expect(_visible('ai', 501), findsOneWidget);
  });

  testWidgets('wide chat resets when switching or reselecting a row', (
    tester,
  ) async {
    _setViewport(tester, const Size(1280, 820));
    await tester.pumpWidget(WhaleChatApp(model: _LongHistoryModel()));
    await _open(tester, 'ai');
    await tester.drag(_history, const Offset(0, 430));
    await tester.pumpAndSettle();
    expect(_visible('ai', 501), findsNothing);
    await _open(tester, 'ai');
    expect(_visible('ai', 501), findsOneWidget);
    await tester.drag(_history, const Offset(0, 430));
    await tester.pumpAndSettle();
    await _open(tester, 'friend');
    expect(_visible('friend', 501), findsOneWidget);
  });

  testWidgets('history received after opening starts at newest', (
    tester,
  ) async {
    _setViewport(tester, const Size(390, 844));
    final model = _LongHistoryModel(deferHistory: true);
    await tester.pumpWidget(WhaleChatApp(model: model));
    await _open(tester, 'ai');
    expect(find.text('还没有消息'), findsOneWidget);
    model.receiveHistory();
    await tester.pumpAndSettle();
    expect(_visible('ai', 501), findsOneWidget);
  });
}
