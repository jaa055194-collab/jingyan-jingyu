import 'dart:async';

import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/favorites_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

const _key = Key('save-favorite-msg');
const _fixtureRows = [
  ShellMessage(id: 'msg', text: 'A canonical fixture', favoriteEligible: true),
  ShellMessage(id: 'pending', text: 'A queued fixture', status: '等待补传'),
  ShellMessage(id: 'recalled', text: 'A recalled fixture'),
];

class _Model extends TestShellModel {
  _Model() {
    connectedAccountId = 'fixture-owner';
    selectedConversationId = 'a';
    online = true;
    messages = _fixtureRows;
  }

  Object epoch = Object();
  final writes = <(String, String)>[];
  final reply = Completer<FavoriteSaveOutcome>();
  bool spent = false;

  @override
  Object? get messageFavoriteContext => authenticated && !locked ? epoch : null;

  @override
  bool hasSubmittedMessageFavorite(String messageId) =>
      messageId == 'msg' && spent;

  @override
  Future<FavoriteSaveOutcome> saveMessageFavorite({
    required String conversationId,
    required String messageId,
    required Object expectedContext,
    required bool Function() viewIsCurrent,
  }) async {
    if (!viewIsCurrent() || expectedContext != messageFavoriteContext) {
      return FavoriteSaveOutcome.cancelled;
    }
    writes.add((conversationId, messageId));
    spent = true;
    return await reply.future;
  }

  void lockThenUnlock() {
    epoch = Object();
    locked = true;
    notifyListeners();
    locked = false;
    notifyListeners();
  }
}

Future<void> _pump(
  WidgetTester tester,
  _Model model, {
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(WhaleChatApp(model: model));
  await tester.pumpAndSettle();
  if (width < 720) {
    await tester.tap(find.byKey(const ValueKey('a')));
    await tester.pumpAndSettle();
    model.messages = _fixtureRows;
    model.notifyListeners();
    await tester.pumpAndSettle();
  }
}

void main() {
  for (final width in [390.0, 768.0, 1280.0]) {
    testWidgets('only a canonical row offers explicit save at $width', (
      tester,
    ) async {
      final model = _Model();
      await _pump(tester, model, width: width);
      expect(find.byKey(_key).hitTestable(), findsOneWidget);
      expect(find.byKey(const Key('save-favorite-pending')), findsNothing);
      expect(find.byKey(const Key('save-favorite-recalled')), findsNothing);
      expect(model.writes, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('one tap sequence writes once and only a receipt shows success', (
    tester,
  ) async {
    final model = _Model();
    await _pump(tester, model);
    final save = find.byKey(_key);
    final press = tester.widget<TextButton>(save).onPressed!;
    press();
    press();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(model.writes, [('a', 'msg')]);
    expect(find.text('已收藏'), findsNothing);
    expect(tester.widget<TextButton>(save).onPressed, isNull);
    model.reply.complete(FavoriteSaveOutcome.saved);
    await tester.pumpAndSettle();
    expect(find.text('已收藏'), findsOneWidget);
    press();
    await tester.pumpAndSettle();
    expect(model.writes, [('a', 'msg')]);
  });

  for (final (outcome, text) in [
    (FavoriteSaveOutcome.rejected, '宿主拒绝收藏。'),
    (FavoriteSaveOutcome.unknown, '收藏结果未确认，请到「我的收藏」核对。'),
  ]) {
    testWidgets('$outcome is not shown as a successful save', (tester) async {
      final model = _Model()..reply.complete(outcome);
      await _pump(tester, model);
      await tester.tap(find.byKey(_key));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
      expect(find.text('已收藏'), findsNothing);
      expect(tester.widget<TextButton>(find.byKey(_key)).onPressed, isNull);
      expect(model.writes, [('a', 'msg')]);
    });
  }

  testWidgets('same-frame departure to Settings prevents a stale write', (
    tester,
  ) async {
    final model = _Model();
    await _pump(tester, model);
    final press = tester.widget<TextButton>(find.byKey(_key)).onPressed!;
    await tester.tap(find.byTooltip('设置'));
    press();
    await tester.pumpAndSettle();
    expect(find.byKey(_key), findsNothing);
    expect(model.writes, isEmpty);
  });

  testWidgets('lock/unlock clears the old action and late status', (
    tester,
  ) async {
    final model = _Model();
    await _pump(tester, model);
    final press = tester.widget<TextButton>(find.byKey(_key)).onPressed!;
    press();
    await tester.pump();
    await tester.pump();
    expect(model.writes, [('a', 'msg')]);
    model.lockThenUnlock();
    model.reply.complete(FavoriteSaveOutcome.saved);
    await tester.pumpAndSettle();
    expect(find.text('已收藏'), findsNothing);
    expect(tester.widget<TextButton>(find.byKey(_key)).onPressed, isNull);
    press();
    await tester.pumpAndSettle();
    expect(model.writes, [('a', 'msg')]);
  });

  testWidgets(
    'a route covered and uncovered before the next frame retires the old callback',
    (tester) async {
      final model = _Model();
      await _pump(tester, model);
      final press = tester.widget<TextButton>(find.byKey(_key)).onPressed!;
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Cover')),
          ),
        ),
      );
      navigator.pop();
      press();
      await tester.pumpAndSettle();
      expect(model.writes, isEmpty);
      expect(find.byKey(_key).hitTestable(), findsOneWidget);
    },
  );
}
