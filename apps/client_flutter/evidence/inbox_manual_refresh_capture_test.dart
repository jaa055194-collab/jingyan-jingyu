import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  int reads = 0;

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/notifications');
    expect(query, {'limit': '50'});
    expect(body, isNull);
    if (++reads == 1) {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'synthetic temporary failure'),
      );
    }
    return const [
      {
        'kind': 'friendRequest',
        'title': '好友邀请',
        'status': 'pending',
        'createdAt': '2026-11-18T00:00:00.000Z',
        'refId': 'fixture-alice',
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
  String? get connectedAccountId => 'fixture-recipient';
  @override
  ThemeMode get themeMode => ThemeMode.light;
}

void main() {
  testWidgets('capture production inbox, same temporary read failure', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const recovery = String.fromEnvironment('CAPTURE_RECOVERY');
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
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    await tester.tap(find.text('收件箱').last);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('inbox-message')), findsOneWidget);
    expect(connection.reads, 1);
    final action = find.byKey(const Key('inbox-refresh'));
    expect(action, recovery.isEmpty ? findsNothing : findsOneWidget);

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
    if (recovery.isNotEmpty) {
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(connection.reads, 2);
      expect(
        find.byKey(const Key('notification-fixture-alice')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('inbox-message')), findsNothing);
      await capture(recovery);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
