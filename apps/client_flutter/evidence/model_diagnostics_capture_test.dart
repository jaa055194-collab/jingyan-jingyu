import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Renders the real production `WhaleChatApp` + `ClientRuntime` shell with a
/// fixture connection and captures the Settings screen.
///
/// The same driver runs against the baseline revision (where the diagnostics
/// entry does not exist) and the delivered revision (where it does), so the
/// before/after pair differs only by that entry. To make the pair comparable
/// the list is scrolled deterministically: the existing "AI 运行配置体检" tile is
/// pinned to the top of the viewport in both revisions, and the delivered
/// revision's new entry then appears immediately below it.
///
/// When `CAPTURE_DETAIL_PATH` is supplied, the driver additionally taps the new
/// entry and captures the opened diagnostics screen as a follow-on state — never
/// as part of the before/after pair.
///
/// The fixture connection serves only what the shell itself needs to leave the
/// onboarding gate. It is not a host and performs no real request.
class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async => switch (path) {
    '/api/v1/accounts/me/ai' => {'accounts': <Object?>[]},
    _ => <String, Object?>{},
  };

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async => const <Object?>[];
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
  @override
  double get fontScale => 1;
  @override
  bool get locked => false;
  @override
  bool get authenticated => true;
  @override
  bool get busy => false;
  @override
  String? get error => null;
  @override
  bool get aiConsentGranted => false;
  @override
  bool get appLockEnabled => false;
  @override
  bool get hideNotificationBody => true;
  @override
  bool get autoStart => false;
}

void main() {
  testWidgets('capture the production settings screen', (tester) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const detail = String.fromEnvironment('CAPTURE_DETAIL_PATH');
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
    final connection = _FixtureConnection();
    final runtime = _FixtureRuntime(connection);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: WhaleChatApp(model: runtime)),
    );
    await tester.pumpAndSettle();

    // Enter Settings through the real app bar action, not a synthetic route.
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);

    // Pin the pre-existing AI config tile to the top of the viewport. It exists
    // in both revisions, so the scroll position is identical and the only
    // difference in the pair is the presence of the new entry below it.
    const anchorKey = Key('open-ai-config');
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(anchorKey),
      200,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final position = tester.state<ScrollableState>(scrollable).position;
    final anchorBox = tester.renderObject<RenderBox>(find.byKey(anchorKey));
    final viewportBox = tester.renderObject<RenderBox>(
      find.byType(ListView).first,
    );
    final delta =
        anchorBox.localToGlobal(Offset.zero).dy -
        viewportBox.localToGlobal(Offset.zero).dy;
    position.jumpTo(
      (position.pixels + delta).clamp(
        position.minScrollExtent,
        position.maxScrollExtent,
      ),
    );
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

    await capture(output);
    if (detail.isNotEmpty) {
      final entry = find.byKey(const Key('open-model-diagnostics'));
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('模型能力与预算诊断'), findsWidgets);
      await capture(detail);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
