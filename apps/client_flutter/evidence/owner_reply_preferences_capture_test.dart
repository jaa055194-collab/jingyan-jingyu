import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/owner_reply_preferences_fixture.dart';

void main() {
  testWidgets('capture matched editor, explicit target review and revocation', (
    tester,
  ) async {
    const before = bool.fromEnvironment('CAPTURE_BEFORE');
    const output = String.fromEnvironment('CAPTURE_PATH');
    const review = String.fromEnvironment('CAPTURE_REVIEW');
    const off = String.fromEnvironment('CAPTURE_DISABLED');
    const cjk = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    if (!before) {
      expect(review, isNotEmpty);
      expect(off, isNotEmpty);
    }
    for (final (family, path) in [
      ('Ahem', cjk),
      ('Roboto', cjk),
      ('MaterialIcons', icons),
    ]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final connection = PreferencesConnection();
    final runtime = PreferencesRuntime(connection);
    final boundary = GlobalKey();
    try {
      await openPreferencesEditor(tester, runtime, boundary: boundary);

      Future<void> capture(String path) async {
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
        File(path).writeAsBytesSync(
          png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
        );
      }

      expect(
        preferenceKey('owner-reply-preferences-read').hitTestable(),
        before ? findsNothing : findsOneWidget,
      );
      expect(connection.calls, [
        ('POST', preferencesRegister),
      ], reason: 'matched scene before preference reads or writes');
      await capture(output);
      if (before) return;

      await tapPreference(tester, 'owner-reply-preferences-read');
      await tapPreference(tester, 'owner-reply-length-brief');
      await tapPreference(tester, 'owner-reply-format-bullets');
      await tapPreference(tester, 'owner-reply-preferences-review');
      expect(connection.writes, isEmpty);
      expect(
        find
            .textContaining('https://provider.example.invalid:8443')
            .hitTestable(),
        findsOneWidget,
      );
      expect(
        find.textContaining('fixture-provider').hitTestable(),
        findsOneWidget,
      );
      expect(
        find.textContaining('fixture-chat-model').hitTestable(),
        findsOneWidget,
      );
      expect(find.textContaining('fixture-target-A'), findsNothing);
      expect(
        preferenceKey('owner-reply-preferences-confirm').hitTestable(),
        findsOneWidget,
      );
      await capture(review);

      await tapPreference(tester, 'owner-reply-preferences-confirm');
      expect(connection.writes.single['enabled'], true);
      await tapPreference(tester, 'owner-reply-preferences-disable');
      expect(connection.writes.last, {
        'expectedRevision': 1,
        'enabled': false,
        'length': 'brief',
        'format': 'bullets',
        'expectedTargetToken': null,
      });
      expect(find.text('未授权自动使用').hitTestable(), findsOneWidget);
      expect(
        tester
            .widget<ChoiceChip>(preferenceKey('owner-reply-length-brief'))
            .selected,
        isTrue,
      );
      expect(
        tester
            .widget<ChoiceChip>(preferenceKey('owner-reply-format-bullets'))
            .selected,
        isTrue,
      );
      expect(preferenceKey('owner-reply-preferences-disable'), findsNothing);
      await capture(off);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await connection.close();
    }
  });
}
