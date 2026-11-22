import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/owner_memory_notes_fixture.dart';
import '../test/support/owner_reply_preferences_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets(
    'render matched Android memory note manager and permission review',
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

      final (connection, runtime) = (await t.runAsync(() async {
        final connection = MemoryNotesConnection();
        connection.memory[memoryProfileA] = memoryState(
          revision: 0,
          target: memoryTarget,
          notes: [
            memoryNote(),
            memoryNote(id: 'note-b', text: '第二句便签'),
          ],
        );
        return (connection, PreferencesRuntime(connection));
      }))!;
      final boundary = GlobalKey();
      Future<void> tapMemory(String key) async {
        final found = memoryKey(key);
        expect(found, findsOneWidget);
        t.testTextInput.hide();
        await t.ensureVisible(found);
        await t.pump();
        if (found.hitTestable().evaluate().isEmpty) {
          await t.scrollUntilVisible(
            found,
            120,
            scrollable: find.byType(Scrollable).first,
          );
          await t.pumpAndSettle();
        }
        await t.tap(found);
        await t.pumpAndSettle();
      }

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
        File('$output/owner-memory-notes-$name.png').writeAsBytesSync(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      }

      try {
        if (before) {
          await openPreferencesEditor(t, runtime, boundary: boundary);
          expect(memoryKey('owner-memory-notes-section'), findsNothing);
          await capture('before');
          return;
        }
        await openMemoryEditor(t, runtime, boundary: boundary);
        expect(memoryKey('owner-memory-notes-section'), findsOneWidget);
        expect(connection.memoryCalls, isEmpty);
        await capture('after');
        await tapMemory('memory-notes-read');
        expect(find.text('喜欢桂花'), findsOneWidget);
        await capture('list');
        await tapMemory('memory-notes-enabled');
        expect(memoryKey('memory-notes-enable-dialog'), findsOneWidget);
        expect(find.textContaining('仅当前本人 AI 私聊'), findsOneWidget);
        await capture('review');
      } finally {
        await t.pumpWidget(const SizedBox.shrink());
        runtime.dispose();
        await t.runAsync(connection.close);
      }
    },
  );
}
