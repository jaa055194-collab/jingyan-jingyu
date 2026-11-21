import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/scheduled_messages_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('render matched Android group schedule states', (t) async {
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

    final (fixture, runtime) = (await t.runAsync(() async {
      final fixture = await ScheduledMessagesFixture.create();
      fixture.seed('scheduled-done', 'delivered');
      fixture.seed('scheduled-expired', 'expired');
      return (fixture, await fixture.open());
    }))!;
    final createdId = 'scheduled-fixture-${fixture.rows.length + 1}';
    final boundary = GlobalKey();
    Future<void> capture(String name) async {
      expect(t.takeException(), isNull);
      final paint =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final bytes = (await t.runAsync(() async {
        final image = await paint.toImage();
        try {
          expect((image.width, image.height), (390, 844));
          return await image.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          image.dispose();
        }
      }))!;
      File('$output/scheduled-messages-$name.png').writeAsBytesSync(
        bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
      );
    }

    try {
      await showScheduleChat(t, runtime, boundary: boundary);
      expect(
        scheduleKey('open-scheduled-messages').hitTestable(),
        before ? findsNothing : findsOneWidget,
      );
      expect(fixture.calls, isEmpty);
      await capture(before ? 'before' : 'after');
      if (before) return;

      await tapScheduleAndWait(
        t,
        'open-scheduled-messages',
        'schedule-compose',
      );
      expect(find.textContaining('周末野餐'), findsWidgets);
      await capture('list');
      await tapSchedule(t, 'schedule-compose');
      await enterScheduleFields(t);
      await capture('compose');
      await tapSchedule(t, 'schedule-review');
      expect(scheduleKey('schedule-confirm').hitTestable(), findsOneWidget);
      expect(
        find.text('UTC：${scheduledInstant.toIso8601String()}'),
        findsOneWidget,
      );
      await capture('review');
      await tapScheduleAndWait(t, 'schedule-confirm', 'schedule-created');
      expect(scheduleKey('schedule-row-$createdId'), findsOneWidget);
      await capture('created');
      await t.pageBack();
      await t.pumpAndSettle();
      expect(
        t.widget<TextField>(scheduleKey('composer')).controller!.text,
        scheduleDraft,
      );
    } finally {
      await t.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await t.runAsync(fixture.cleanup);
    }
  });
}
