import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _CaptureConnection extends HostConnection {
  _CaptureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  int reads = 0;
  final writes = <String>[];

  @override
  Future<List<Object?>> requestList(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
  }) async {
    expect((method, path, body, query), ('GET', '/api/v1/friends', null, null));
    reads++;
    return const [
      {
        'accountId': 'fixture-friend',
        'displayName': 'Fixture Friend',
        'state': 'friends',
      },
    ];
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    writes.add('$method $path');
    expect((body, query, retryAuthentication, allowEmptySuccess), (
      null,
      null,
      false,
      true,
    ));
    return {};
  }
}

class _CaptureRuntime extends ClientRuntime {
  _CaptureRuntime(HostConnection fixture) {
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
  String? get connectedAccountId => 'fixture-sender';
  @override
  ThemeMode get themeMode => ThemeMode.light;
}

void main() {
  testWidgets('capture the production Contacts route for the same fixture', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const confirm = String.fromEnvironment('CAPTURE_CONFIRM');
    const sent = String.fromEnvironment('CAPTURE_SENT');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [('Ahem', font), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final connection = _CaptureConnection();
    final runtime = _CaptureRuntime(connection);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: WhaleChatApp(model: runtime)),
    );
    await tester.tap(find.text('联系人'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('contacts-friend-fixture-friend')), findsOneWidget);
    expect(connection.reads, 1);
    expect(connection.writes, isEmpty);

    Future<void> capture(String path) async {
      expect(tester.takeException(), isNull);
      final painter =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final png = await tester.runAsync(() async {
        final pixels = await painter.toImage();
        try {
          expect((pixels.width, pixels.height), (390, 844));
          return await pixels.toByteData(format: ui.ImageByteFormat.png);
        } finally {
          pixels.dispose();
        }
      });
      File(path).writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    }

    final field = find.byKey(const Key('contacts-request-account'));
    final review = find.byKey(const Key('contacts-request-review'));
    final dialog = find.byKey(const Key('contacts-request-confirmation'));
    expect(field, confirm.isEmpty ? findsNothing : findsOneWidget);
    expect(review, confirm.isEmpty ? findsNothing : findsOneWidget);
    expect(dialog, findsNothing);
    await capture(output);
    if (confirm.isNotEmpty) {
      await tester.enterText(field, 'Fixture_Target-02');
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(of: dialog, matching: find.textContaining('Fixture_Target-02')),
        findsOneWidget,
      );
      expect(connection.writes, isEmpty);
      await capture(confirm);
      if (sent.isNotEmpty) {
        await tester.tap(find.byKey(const Key('contacts-request-send')));
        await tester.pumpAndSettle();
        expect(connection.writes, ['POST /api/v1/friends/Fixture_Target-02/requests']);
        expect(find.byKey(const Key('contacts-request-result')), findsOneWidget);
        expect(find.byKey(const Key('contacts-friend-fixture-friend')), findsOneWidget);
        expect(connection.reads, 1);
        await capture(sent);
      }
    }

    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
