import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

/// Uses the production Settings → lifecycle route with synthetic transport at
/// both revisions. The matched frame is idle: no picker or host write occurs.
class _Connection extends HostConnection {
  _Connection() : super(Uri.parse('http://fixture.invalid'), 'fixture');
  final calls = <(String, String)>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    calls.add((method, path));
    return switch ((method, path)) {
      ('GET', Routes.lifecycleQuota) => {
        'usedBytes': 5 * 1024 * 1024,
        'quotaBytes': 2 * 1024 * 1024 * 1024,
        'diskFreeBytes': 8 * 1024 * 1024 * 1024,
        'diskTotalBytes': 16 * 1024 * 1024 * 1024,
      },
      ('GET', Routes.lifecycleDepartureSurvey) => {
        'objectCounts': {'conversations': 2, 'messages': 12},
        'momentsToAnonymize': 0,
        'totalObjects': 14,
      },
      ('GET', Routes.lifecycleCleanupPreview) => {
        'dayKey': '2026-03-01',
        'remindSoon': {'video': 0, 'voice': 0},
        'expiring': {'video': 0, 'voice': 0},
        'totalHeld': {'video': 0, 'voice': 0},
      },
      _ => throw StateError('Unexpected fixture request'),
    };
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_Connection connection) {
    this.connection = connection;
  }

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  bool get locked => false;
  @override
  String? get connectedAccountId => 'owner-fixture';
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  double get fontScale => 1;
}

void main() {
  testWidgets(
    'capture the production lifecycle editor at its initial position',
    (tester) async {
      const output = String.fromEnvironment('CAPTURE_PATH');
      const after = bool.fromEnvironment('CAPTURE_EXPECT_PREVIEW');
      const font = String.fromEnvironment('CAPTURE_CJK_FONT');
      const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
      expect(output, isNotEmpty);
      for (final (family, path) in [('Ahem', font), ('MaterialIcons', icons)]) {
        final bytes = File(path).readAsBytesSync();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      tester.view.physicalSize = const Size(1280, 960);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final connection = _Connection();
      final runtime = _Runtime(connection);
      addTearDown(runtime.dispose);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WhaleChatApp(model: runtime),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('设置'));
      await tester.pumpAndSettle();
      final entry = find.byKey(const Key('open-lifecycle-status'));
      await tester.scrollUntilVisible(
        entry,
        240,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(entry);
      await tester.pumpAndSettle();

      expect(find.text('配额与生命周期状态').hitTestable(), findsOneWidget);
      expect(
        find.byKey(const Key('export-lifecycle')).hitTestable(),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('preview-backup-file')).hitTestable(),
        after ? findsOneWidget : findsNothing,
      );
      expect(
        connection.calls,
        unorderedEquals([
          ('GET', Routes.lifecycleQuota),
          ('GET', Routes.lifecycleDepartureSurvey),
          ('GET', Routes.lifecycleCleanupPreview),
        ]),
      );
      expect(tester.takeException(), isNull);
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final image = await render.toImage();
        try {
          expect((image.width, image.height), (1280, 960));
          return await image.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          image.dispose();
        }
      });
      final file = File(output);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
