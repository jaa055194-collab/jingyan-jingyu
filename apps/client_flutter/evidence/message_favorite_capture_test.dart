import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import '../test/runtime_auth_test.dart' show Fixture, channel;

/// The same synthetic, loopback-only host serves both revisions. The sole
/// difference under test is the explicit save affordance on a canonical row.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture matched production chat favorite states', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const followOn = String.fromEnvironment('CAPTURE_FOLLOW_ON');
    const expectAction = bool.fromEnvironment('CAPTURE_EXPECT_ACTION');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [
      ('Roboto', font),
      ('Ahem', font),
      ('MaterialIcons', icons),
    ]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final runtime = ClientRuntime();
    final writes = <Object?>[];
    var posts = 0;
    final fixture = (await tester.runAsync(() async {
      final host = await Fixture.create();
      host.secure = jsonEncode(host.session());
      await File('${host.root.path}/settings.json').writeAsString(
        jsonEncode({
          'preferences': {'theme': 'light', 'fontScale': 1},
        }),
      );
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        return switch (call.method) {
          'initialize' => <String, Object?>{},
          'getDataDirectory' => host.root.path,
          'readSession' => host.secure,
          'hasPin' => false,
          _ => null,
        };
      });
      host.serve = (request) async {
        final path = request.uri.path;
        if (path == Routes.favorites && request.method == 'POST') {
          posts++;
          writes.add(jsonDecode(await utf8.decoder.bind(request).join()));
          await host.reply(request, {
            'id': 'fixture-favorite',
            'kind': 'message',
            'title': null,
          });
        } else if (request.uri.path.endsWith('/ack')) {
          await request.drain<void>();
          await host.reply(request, {'acknowledgedSeq': 2});
        } else if (path == Routes.conversations) {
          await request.drain<void>();
          await host.reply(request, {
            'conversations': [
              {'id': 'favorite-fixture', 'name': '收藏示例会话'},
            ],
          });
        } else if (path.endsWith('/sync')) {
          await request.drain<void>();
          final after = int.parse(request.uri.queryParameters['afterSeq']!);
          await host.reply(request, {
            'firstVisibleSeq': 1,
            'messages': [
              for (final (seq, id, body) in [
                (1, 'fixture-canonical', {'text': '这是可被显式收藏的合成消息。'}),
                (2, 'fixture-recalled', {'recalled': true}),
              ])
                if (seq > after)
                  {
                    'seq': seq,
                    'conversationId': 'favorite-fixture',
                    'messageId': id,
                    'senderId': 'fixture-member',
                    'kind': 'text',
                    'body': body,
                    'sentAt': '2026-11-20T00:00:00.000Z',
                  },
            ],
            'hasMore': false,
          });
        } else {
          await request.drain<void>();
          await host.reply(request, {'conversations': []});
        }
      };
      await runtime.initialize();
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      runtime.reconnect?.cancel();
      await runtime.refreshConversations();
      await runtime.shell.markRead('favorite-fixture', 2);
      return host;
    }))!;
    try {
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WhaleChatApp(model: runtime),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('favorite-fixture')));
      await tester.pumpAndSettle();
      expect(find.text('收藏示例会话'), findsOneWidget);
      expect(find.text('这是可被显式收藏的合成消息。'), findsOneWidget);
      final action = find.byKey(const Key('save-favorite-fixture-canonical'));
      expect(
        action.hitTestable(),
        expectAction ? findsOneWidget : findsNothing,
      );
      expect(posts, 0, reason: 'opening chat must not write');
      expect(tester.takeException(), isNull);

      Future<void> capture(String path) async {
        final painter =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
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
        expect(posts, 0);
        // The POST uses real loopback I/O. Let that I/O finish while pumping
        // the submit and receipt frame barriers in the production control.
        final saved = await tester.runAsync(() async {
          await tester.tap(action);
          final watch = Stopwatch()..start();
          while (find.text('已收藏').evaluate().isEmpty &&
              watch.elapsed < const Duration(seconds: 5)) {
            await tester.pump();
            await Future<void>.delayed(const Duration(milliseconds: 16));
          }
          return find.text('已收藏').evaluate().isNotEmpty;
        });
        expect(saved, isTrue);
        await tester.pumpAndSettle();
        expect(posts, 1);
        expect(writes.single, {
          'kind': 'message',
          'conversationId': 'favorite-fixture',
          'messageId': 'fixture-canonical',
        });
        expect(find.text('已收藏'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(followOn);
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await tester.runAsync(fixture.cleanup);
    }
  });
}
