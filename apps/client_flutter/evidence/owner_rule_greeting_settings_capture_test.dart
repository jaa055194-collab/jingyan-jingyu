import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/owner_rule_greeting_fixture.dart';

void main() {
  testWidgets(
    'render matched Android Settings and rule greeting consent states',
    (t) async {
      const before = bool.fromEnvironment('CAPTURE_BEFORE');
      const output = String.fromEnvironment('CAPTURE_OUTPUT');
      const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
      const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
      expect(output, isNotEmpty);
      for (final (family, font) in [
        ('Ahem', cjk),
        ('Roboto', cjk),
        ('MaterialIcons', icons),
      ]) {
        final data = File(font).readAsBytesSync();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(data)))).load();
      }
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      t.platformDispatcher.textScaleFactorTestValue = 1;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);

      final host = GreetingConnection();
      final runtime = GreetingRuntime(host);
      final boundary = GlobalKey();
      Future<void> capture(String name) async {
        expect(t.takeException(), isNull);
        final paint =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bytes = (await t.runAsync(() async {
          final image = await paint.toImage();
          try {
            expect((image.width, image.height), (390, 844));
            return await image.toByteData(format: ui.ImageByteFormat.png);
          } finally {
            image.dispose();
          }
        }))!;
        File('$output/owner-rule-greeting-$name.png').writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }

      try {
        await openGreetingSettings(t, runtime, boundary: boundary);
        expect(
          greetingKey('open-owner-rule-greeting-global').hitTestable(),
          before ? findsNothing : findsOneWidget,
        );
        expect(host.calls, isEmpty);
        await capture(before ? 'before' : 'after');

        await openGreetingEditor(t);
        expect(host.calls, [('POST', greetingRegister)]);
        expect(
          greetingKey('owner-rule-greeting-read').hitTestable(),
          before ? findsNothing : findsOneWidget,
        );
        await capture(before ? 'editor-before' : 'editor-after');
        if (before) return;

        await revealGreetingCard(t);
        await tapGreeting(t, 'owner-rule-greeting-read');
        expect(find.text('未授权规则问候'), findsOneWidget);
        await enterGreeting(t, 'owner-rule-greeting-local', '01:30');
        await enterGreeting(t, 'owner-rule-greeting-offset', '+08:00');
        await tapGreeting(t, 'owner-rule-greeting-review');
        expect(
          greetingKey('owner-rule-greeting-confirm').hitTestable(),
          findsOneWidget,
        );
        expect(host.writes, isEmpty);
        await capture('review');
        await tapGreeting(t, 'owner-rule-greeting-confirm');
        expect(find.text('已授权规则问候'), findsOneWidget);
        await tapGreeting(t, 'owner-rule-greeting-disable');
        expect(find.text('未授权规则问候'), findsOneWidget);
        expect(
          t
              .widget<TextField>(greetingKey('owner-rule-greeting-offset'))
              .controller!
              .text,
          '+08:00',
        );
        expect(host.writes.map((w) => w.$2['enabled']), [true, false]);
        expect(
          greetingKey('owner-rule-greeting-state').hitTestable(),
          findsOneWidget,
        );
        expect(
          greetingKey('owner-rule-greeting-offset').hitTestable(),
          findsOneWidget,
        );
        await capture('disabled');

        await t.pageBack();
        await t.pumpAndSettle();
        t
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .jumpTo(0);
        await t.pumpAndSettle();
        await openGreetingGlobal(t);
        await tapGreeting(t, 'owner-rule-greeting-global-stop');
        await tapGreeting(t, 'owner-rule-greeting-global-confirm');
        expect(
          t
              .widget<SwitchListTile>(
                greetingKey('owner-rule-greeting-global-stop'),
              )
              .value,
          isTrue,
        );
        expect(host.writes.last.$1, greetingGlobalPath);
        await capture('blocked');
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        runtime.dispose();
        await host.close();
      }
    },
  );
}
