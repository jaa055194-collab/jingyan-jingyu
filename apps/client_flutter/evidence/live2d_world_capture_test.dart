import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/features/world/world_screen.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// No runtime initialization, host connection, stored session, or model asset.
class _FixtureRuntime extends ClientRuntime {
  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  String? get connectedAccountId => 'live2d-evidence-fixture';
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
}

void main() {
  testWidgets('capture the production World tab without opening any picker', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const phase = String.fromEnvironment('CAPTURE_PHASE');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    expect(phase, isIn(['before', 'after']));
    // The test engine lacks system CJK fallback. Cover both the widget-test
    // default and Material's explicit Roboto text styles with the same font.
    for (final (family, path) in [
      ('Ahem', font),
      ('Roboto', font),
      ('MaterialIcons', icons),
    ]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }

    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final runtime = _FixtureRuntime();
    expect(runtime.authenticated, isTrue);
    expect(runtime.locked, isFalse);
    expect(runtime.busy, isFalse);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    await tester.tap(find.text('世界'));
    await tester.pumpAndSettle();

    expect(find.byType(WorldScreen), findsOneWidget);
    expect(find.text('世界与形象').hitTestable(), findsOneWidget);
    expect(find.text('形象与房间已设置。').hitTestable(), findsOneWidget);
    expect(find.byKey(const Key('world-open-setup')), findsNothing);
    expect(
      find.byKey(const Key('world-open-perf')).hitTestable(),
      findsOneWidget,
    );
    expect(find.textContaining('尚未接入').hitTestable(), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    final action = find.text('选择 Live2D ZIP');
    expect(action, phase == 'before' ? findsNothing : findsOneWidget);
    if (phase == 'after') {
      expect(action.hitTestable(), findsOneWidget);
      final button = find.ancestor(
        of: action,
        matching: find.byWidgetPredicate(
          (widget) => widget is ButtonStyleButton && widget.onPressed != null,
        ),
      );
      expect(button, findsOneWidget);
    }
    expect(tester.takeException(), isNull);

    final painter =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final png = await tester.runAsync(() async {
      final pixels = await painter.toImage();
      try {
        expect((pixels.width, pixels.height), (1280, 960));
        return await pixels.toByteData(format: ui.ImageByteFormat.png);
      } finally {
        pixels.dispose();
      }
    });
    File(output).writeAsBytesSync(
      png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
