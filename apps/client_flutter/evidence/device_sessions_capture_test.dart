import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Device-session evidence driver.
///
/// Renders the real production `WhaleChatApp` + `ClientRuntime` against a
/// fixture [HostConnection] that answers `GET /api/v1/auth/devices`. The Before
/// revision has no settings entry, so the same driver only captures the settings
/// page there (`CAPTURE_STAGE=settings`); the After revision additionally opens
/// the device list (`CAPTURE_STAGE=list`).
class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  int reads = 0;
  final List<(String, String)> requests = [];

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    requests.add((method, path));
    expect(method, 'GET');
    expect(path, '/api/v1/auth/devices');
    expect(body, isNull);
    expect(query, isNull);
    reads++;
    return const [
      {
        'id': 'device-laptop',
        'deviceName': '工作室笔记本',
        'lastUsedAt': '2026-11-18T02:03:04.000Z',
      },
      {
        'id': 'device-phone',
        'deviceName': '随身手机',
        'lastUsedAt': '2026-11-17T10:00:00.000Z',
      },
    ];
  }
}

class _FixtureRuntime extends ClientRuntime {
  _FixtureRuntime(HostConnection fixture) {
    connection = fixture;
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
  String? get connectedAccountId => 'fixture-owner';
  @override
  ThemeMode get themeMode => ThemeMode.light;
}

void main() {
  testWidgets('capture device-session settings entry and opened list', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const stage = String.fromEnvironment(
      'CAPTURE_STAGE',
      defaultValue: 'settings',
    );
    const expectEntry = bool.fromEnvironment('CAPTURE_EXPECT_ENTRY');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    expect(stage, anyOf('settings', 'list'));
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
    final connection = _FixtureConnection();
    final runtime = _FixtureRuntime(connection);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: WhaleChatApp(model: runtime)),
    );
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();

    Future<void> capture(String path) async {
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
      File(path).writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    final scrollable = find
        .descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable))
        .first;
    expect(tester.state<ScrollableState>(scrollable).position.pixels, 0);
    final privacy = find.text('隐私与安全');
    final general = find.text('通用');
    expect(privacy, findsOneWidget);
    expect(general, findsOneWidget);
    expect(connection.reads, 0, reason: 'no device read before the entry opens');

    final entry = find.byKey(const Key('open-device-sessions'));
    if (expectEntry || stage == 'list') {
      expect(entry, findsOneWidget);
      // Remote sign-off is an account security action, not a read-only check.
      expect(tester.getTopLeft(entry).dy, greaterThan(tester.getBottomLeft(privacy).dy));
      expect(tester.getBottomLeft(entry).dy, lessThan(tester.getTopLeft(general).dy));
    }
    if (stage == 'settings') {
      // Before: the entry is absent. After: it is present and on screen.
      expect(entry, expectEntry ? findsOneWidget : findsNothing);
      if (expectEntry) {
        final rect = tester.getRect(entry);
        expect(rect.top, greaterThanOrEqualTo(0.0));
        expect(rect.bottom, lessThanOrEqualTo(960.0));
      }
      await capture(output);
    } else {
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(connection.reads, 1);
      expect(find.byKey(const Key('device-row-device-laptop')), findsOneWidget);
      expect(find.byKey(const Key('device-row-device-phone')), findsOneWidget);
      // The host reports no current device, so every row takes the stronger
      // gate; open one confirmation to show that honest state.
      await tester.tap(find.byKey(const Key('device-revoke-device-phone')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
      await capture(output);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
