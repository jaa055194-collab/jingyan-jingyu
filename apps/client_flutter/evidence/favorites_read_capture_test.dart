import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/app/shell_view_model.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  int reads = 0;

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    expect(path, Routes.favorites);
    expect(cancellation, isNotNull);
    reads++;
    return const {
      'favorites': [
        {
          'id': 'fixture-favorite',
          'kind': 'message',
          'messageId': 'fixture-message',
          'conversationId': 'fixture-chat',
          'title': '读书小组笔记',
          'content': '{"text":"下次读书会讨论《海边的房间》。"}',
          'tags': null,
          'note': null,
          'createdAt': '2026-11-20T09:00:00.000Z',
        },
        {
          'id': 'fixture-link',
          'kind': 'link',
          'messageId': null,
          'conversationId': null,
          'title': null,
          'content': 'https://fixture.invalid/hidden-link',
          'tags': null,
          'note': null,
          'createdAt': '2026-11-20T10:00:00.000Z',
        },
      ],
    };
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
  String get connectedAccountId => 'fixture-owner';
  @override
  ThemeMode get themeMode => ThemeMode.light;
  @override
  List<ShellConversation> get conversations => const [
    ShellConversation(id: 'fixture-chat', title: '读书小组', preview: '读书会准备中'),
  ];
}

void main() {
  testWidgets('capture matched production conversation-list states', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const followOn = String.fromEnvironment('CAPTURE_FOLLOW_ON');
    const expectEntry = bool.fromEnvironment('CAPTURE_EXPECT_ENTRY');
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
    final connection = _FixtureConnection();
    final runtime = _FixtureRuntime(connection);
    addTearDown(runtime.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: WhaleChatApp(model: runtime),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('读书小组'), findsOneWidget);
    expect(find.byKey(const Key('create-group')), findsOneWidget);
    expect(find.byKey(const Key('refresh-conversations')), findsOneWidget);
    final entry = find.byKey(const Key('open-favorites'));
    expect(entry, expectEntry ? findsOneWidget : findsNothing);
    expect(connection.reads, 0);

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

    await capture(output);
    if (followOn.isNotEmpty) {
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(connection.reads, 0, reason: 'opening the route must not read');
      await tester.tap(find.byKey(const Key('load-favorites')));
      await tester.pumpAndSettle();
      expect(connection.reads, 1);
      expect(find.text('下次读书会讨论《海边的房间》。'), findsOneWidget);
      expect(find.textContaining('fixture.invalid'), findsNothing);
      await capture(followOn);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
