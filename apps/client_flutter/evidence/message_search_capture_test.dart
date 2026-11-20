import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Synthetic host answers for `GET /api/v1/search?type=message`.
///
/// Used only by the follow-on "search screen with synthetic results" capture.
/// The row shape mirrors the merged host route exactly (hits/conversationId/
/// messageId/seq/senderId/kind/body/sentAt/mode). No real account, conversation
/// or message content is involved.
class _FixtureConnection extends HostConnection {
  _FixtureConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  int searches = 0;

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    expect(method, 'GET');
    expect(path, '/api/v1/search');
    expect(query?['q'], '鲸落');
    expect(query?['type'], 'message');
    expect(body, isNull);
    searches++;
    return const {
      'hits': [
        {
          'conversationId': 'fixture-group-a',
          'messageId': 'fixture-msg-1',
          'seq': 42,
          'senderId': 'fixture-member-a',
          'kind': 'text',
          'body': {'text': '项目代号鲸落，下周一评审。'},
          'sentAt': '2026-11-14T09:00:00.000Z',
          'mode': 'blind',
        },
        {
          'conversationId': 'fixture-group-b',
          'messageId': 'fixture-msg-2',
          'seq': 7,
          'senderId': 'fixture-member-b',
          'kind': 'text',
          'body': {'text': '鲸落相关的会议纪要已经归档。'},
          'sentAt': '2026-11-15T02:30:00.000Z',
          'mode': 'scan',
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
  String? get connectedAccountId => 'fixture-account';
  @override
  ThemeMode get themeMode => ThemeMode.light;
}

void main() {
  testWidgets('capture production settings + global message search', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const followOn = String.fromEnvironment('CAPTURE_FOLLOW_ON');
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
    await tester.pumpAndSettle();

    // Open the real Settings screen through the real gear action.
    await tester.tap(find.byTooltip('设置'));
    await tester.pumpAndSettle();
    expect(find.text('开发者'), findsOneWidget);

    // Scroll to a fixed anchor so Before and After share one UI state: the
    // entry under test is fully visible and the read-only group is on screen.
    final entry = find.byKey(const Key('open-message-search'));
    final anchor = entry.evaluate().isEmpty
        ? find.byKey(const Key('open-lifecycle-status'))
        : entry;
    await tester.scrollUntilVisible(anchor, 240);
    await tester.pumpAndSettle();
    // Report presence so the driver proves Before lacks the entry.
    // ignore: avoid_print
    print(
      'CAPTURE_METRICS searchEntry=${entry.evaluate().length} '
      'searches=${connection.searches}',
    );

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
    expect(connection.searches, 0, reason: 'nothing may be searched on load');

    if (followOn.isNotEmpty) {
      expect(entry, findsOneWidget, reason: 'follow-on needs the After entry');
      await tester.tap(entry);
      await tester.pumpAndSettle();
      // Nothing fetched merely by opening the search screen.
      expect(connection.searches, 0);
      expect(find.byKey(const Key('search-idle')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('search-query')), '鲸落');
      await tester.tap(find.byKey(const Key('search-submit')));
      await tester.pumpAndSettle();
      expect(connection.searches, 1);
      expect(find.byKey(const Key('search-results')), findsOneWidget);
      expect(find.byKey(const Key('search-hit-fixture-msg-1')), findsOneWidget);
      await capture(followOn);
    }

    await tester.pumpWidget(const SizedBox.shrink());
    runtime.dispose();
  });
}
