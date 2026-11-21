import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/chat_reactions_fixture.dart';

Finder _key(String value) => find.byKey(Key(value));

Future<void> _tapAndRead(WidgetTester tester, String from, String until) async {
  expect(_key(from).hitTestable(), findsOneWidget);
  await tester.runAsync(() async {
    await tester.tap(_key(from));
    await tester.pump();
    final clock = Stopwatch()..start();
    final result = _key(until);
    while (result.evaluate().isEmpty &&
        clock.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    expect(result, findsOneWidget);
  });
  await tester.pumpAndSettle();
}

/// Drives the same synthetic current-chat row in the real app on both trees.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture matched message actions and checked reaction readback', (
    t,
  ) async {
    const before = bool.fromEnvironment('CAPTURE_BEFORE');
    const menuOutput = String.fromEnvironment('CAPTURE_PATH');
    const pickerOutput = String.fromEnvironment('CAPTURE_PICKER');
    const confirmedOutput = String.fromEnvironment('CAPTURE_CONFIRMED');
    const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    const emoji = String.fromEnvironment('CAPTURE_EMOJI_FONT');
    expect(menuOutput, isNotEmpty);
    if (!before) {
      expect(pickerOutput, isNotEmpty);
      expect(confirmedOutput, isNotEmpty);
    }
    for (final (family, path) in [
      ('Roboto', cjk),
      ('Ahem', cjk),
      ('MaterialIcons', icons),
      ('Segoe UI Emoji', emoji),
    ]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    t.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    final (fixture, runtime) = (await t.runAsync(() async {
      final fixture = await ChatReactionsFixture.create();
      return (fixture, await fixture.open());
    }))!;
    final boundary = GlobalKey();

    Future<void> capture(String output) async {
      expect(t.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = (await t.runAsync(() async {
        final image = await render.toImage();
        try {
          expect((image.width, image.height), (390, 844));
          return await image.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          image.dispose();
        }
      }))!;
      File(output).writeAsBytesSync(
        png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    try {
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WhaleChatApp(model: runtime),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(_key(pinsChat));
      await t.pumpAndSettle();
      expect(find.text(peerText), findsOneWidget);
      await t.tap(_key('message-actions-$peerMessage'));
      await t.pumpAndSettle();
      expect(_key('message-action-copy').hitTestable(), findsOneWidget);
      expect(_key('message-action-pin').hitTestable(), findsOneWidget);
      expect(
        _key('message-action-reactions').hitTestable(),
        before ? findsNothing : findsOneWidget,
      );
      expect(fixture.requests, isEmpty);
      await capture(menuOutput);
      if (before) return;

      await _tapAndRead(
        t,
        'message-action-reactions',
        'message-reaction-thumbsUp',
      );
      expect(
        t.widget<FilterChip>(_key('message-reaction-heart')).selected,
        isTrue,
      );
      expect(
        t.widget<FilterChip>(_key('message-reaction-thumbsUp')).selected,
        isFalse,
      );
      expect(find.text(reactionActor), findsNothing);
      expect(find.text(legacyReaction), findsNothing);
      expect(fixture.requests, [('GET', peerReactionPath, '')]);
      await capture(pickerOutput);

      await _tapAndRead(
        t,
        'message-reaction-thumbsUp',
        'message-reactions-confirmed',
      );
      expect(
        t.widget<FilterChip>(_key('message-reaction-thumbsUp')).selected,
        isTrue,
      );
      expect(fixture.requests, [
        ('GET', peerReactionPath, ''),
        ('POST', peerReactionPath, '{"emoji":"👍"}'),
        ('GET', peerReactionPath, ''),
      ]);
      await capture(confirmedOutput);
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await t.runAsync(fixture.cleanup);
    }
  });
}
