import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../test/support/chat_pins_fixture.dart';

const _list = Key('open-chat-pins');
const _close = Key('close-chat-pins');
const _peer = Key('chat-pinned-message-$peerMessage');
const _own = Key('chat-pinned-message-$ownMessage');
const _confirm = Key('chat-pin-confirm');

Future<void> _tapAndRead(WidgetTester tester, Key tap, Key result) async {
  await tester.runAsync(() async {
    await tester.tap(find.byKey(tap));
    final clock = Stopwatch()..start();
    final arrived = find.byKey(result);
    while (arrived.evaluate().isEmpty &&
        clock.elapsed < const Duration(seconds: 10)) {
      await tester.pump(const Duration(milliseconds: 16));
      await Future<void>.delayed(const Duration(milliseconds: 12));
    }
    expect(arrived, findsOneWidget);
  });
  await tester.pumpAndSettle();
}

/// Same test clock, UI configuration and live loopback fixture on both revisions.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture the same eligible chat and confirmed pin flow', (
    tester,
  ) async {
    const before = bool.fromEnvironment('CAPTURE_BEFORE');
    const path = String.fromEnvironment('CAPTURE_PATH');
    const listPath = String.fromEnvironment('CAPTURE_LIST');
    const confirmPath = String.fromEnvironment('CAPTURE_CONFIRM');
    const resultPath = String.fromEnvironment('CAPTURE_RESULT');
    const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(path, isNotEmpty);
    if (!before) {
      for (final output in [listPath, confirmPath, resultPath]) {
        expect(output, isNotEmpty);
      }
    }
    for (final (family, font) in [
      ('Roboto', cjk),
      ('Ahem', cjk),
      ('MaterialIcons', icons),
    ]) {
      final bytes = File(font).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final (fixture, runtime) = (await tester.runAsync(() async {
      final fixture = await ChatPinsFixture.create();
      final runtime = await fixture.openRuntime();
      return (fixture, runtime);
    }))!;
    final boundary = GlobalKey();
    try {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WhaleChatApp(model: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey(pinsChat)));
      await tester.pumpAndSettle();
      expect(find.text(peerText), findsOneWidget);
      expect(find.text(ownText), findsOneWidget);
      expect(find.text('消息已撤回'), findsOneWidget);
      expect(find.byKey(_list), before ? findsNothing : findsOneWidget);
      expect(fixture.reads, 0);
      expect(fixture.writes, isEmpty);

      Future<void> capture(String output) async {
        expect(tester.takeException(), isNull);
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final png = (await tester.runAsync(() async {
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

      await capture(path);
      if (before) return;
      await _tapAndRead(tester, _list, _peer);
      expect(
        find.byKey(const Key('chat-pinned-message-$hiddenMessage')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('chat-pinned-message-$recalledMessage')),
        findsNothing,
      );
      expect(find.text(hiddenActor), findsNothing);
      expect(fixture.writes, isEmpty);
      await capture(listPath);
      await tester.tap(find.byKey(_close));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('message-actions-$ownMessage')));
      await tester.pumpAndSettle();
      await _tapAndRead(tester, const Key('message-action-pin'), _confirm);
      expect(fixture.writes, isEmpty);
      await capture(confirmPath);
      await _tapAndRead(tester, _confirm, const Key('chat-pin-confirmed'));
      expect(fixture.writes, [
        (
          'POST',
          '/api/v1/conversations/$pinsChat/messages/$ownMessage/pin',
          '',
        ),
      ]);
      await tester.tap(find.byKey(_close));
      await tester.pumpAndSettle();
      await _tapAndRead(tester, _list, _own);
      expect(find.byKey(_peer), findsOneWidget);
      await capture(resultPath);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await tester.runAsync(fixture.cleanup);
    }
  });
}
