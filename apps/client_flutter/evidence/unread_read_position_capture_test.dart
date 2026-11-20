import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

/// Headless render of the production conversation list with real unread state.
///
/// The real `ClientRuntime` runs against a loopback fixture host, so the badge
/// numbers come from the production unread projection and the production
/// `ConversationList` widget, not from a mock. The same driver is copied
/// unchanged into the baseline worktree, where the projection does not exist yet
/// and therefore renders no badge: that is the Before image.
///
/// This is a widget-harness render, not device, native or live-host acceptance.
const _channel = MethodChannel('jingyu/platform');

/// The baseline revision has no `readSeqFor`, so the driver must not reference
/// it statically: it would fail to compile there and the Before image could not
/// be produced from the same unedited file. Dynamic dispatch keeps one identical
/// driver working on both revisions.
bool _supportsReadPosition(ClientRuntime runtime) {
  final shell = runtime.shell as Object?;
  if (shell == null) return false;
  try {
    // ignore: avoid_dynamic_calls
    (shell as dynamic).readSeqFor('probe');
    return true;
  } catch (_) {
    return false;
  }
}

int _readSeqFor(ClientRuntime runtime, String id) {
  // ignore: avoid_dynamic_calls
  final value = (runtime.shell as dynamic).readSeqFor(id);
  return value is int ? value : 0;
}

const _conversations = <(String, String, int)>[
  ('team-project', '项目小组', 4),
  ('family', '家人', 2),
  ('quiet', '安静会话', 0),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture the production conversation list unread state', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const opened = String.fromEnvironment('CAPTURE_OPENED');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    for (final (family, path) in [('Ahem', font), ('MaterialIcons', icons)]) {
      final bytes = File(path).readAsBytesSync();
      await (FontLoader(
        family,
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
    }

    // Every real-IO await must run inside runAsync: in the fake-async test zone
    // a bare `await` on real filesystem or socket futures never completes.
    late final Directory root;
    late final HttpServer server;
    late final ClientRuntime runtime;
    final acks = <(String, Object?)>[];
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('unread-evidence-');
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      String? session = jsonEncode({
        'host': origin,
        'accountId': 'me',
        'deviceId': 'phone',
        'accessToken': 'fixture-access',
        'refreshToken': 'fixture-refresh',
        'onboarded': true,
      });

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
            switch (call.method) {
              case 'initialize':
                return <String, Object?>{};
              case 'getDataDirectory':
                return root.path;
              case 'readSession':
                return session;
              case 'hasPin':
                return false;
              case 'storeSession':
                session = (call.arguments as Map<Object?, Object?>)['json']
                    as String;
                return null;
              default:
                return null;
            }
          });

      Map<String, Object?> row(String conversationId, int seq) => {
        'conversationId': conversationId,
        'seq': seq,
        'messageId': '$conversationId-$seq',
        'senderId': 'friend',
        'kind': 'text',
        'body': {'text': '合成消息 $conversationId $seq'},
        'sentAt': '2026-11-20T00:00:00.000Z',
      };

      server.listen((request) async {
        Future<void> reply(Map<String, Object?> body, {int status = 200}) async {
          request.response.statusCode = status;
          request.response.headers.contentType = ContentType.json;
          request.response.write(jsonEncode(body));
          await request.response.close();
        }

        final path = request.uri.path;
        if (request.method == 'POST' && path.endsWith('/ack')) {
          // Read the body before any drain; draining first would consume it.
          final body = jsonDecode(await utf8.decoder.bind(request).join());
          acks.add((path, body));
          final requested = (body as Map)['seq'];
          return reply({
            'acknowledgedSeq': requested is int ? requested : 0,
          });
        }
        await request.drain<void>();
        if (path == Routes.hostInfo) {
          return reply({'error': 'forbidden'}, status: 403);
        }
        if (path == Routes.conversations) {
          return reply({
            'conversations': [
              for (final (id, name, _) in _conversations)
                {
                  'id': id,
                  'name': name,
                  'kind': 'group',
                  'ownerAccountId': 'me',
                },
            ],
          });
        }
        if (path == Routes.directConversations) {
          return reply({'conversations': []});
        }
        if (path.endsWith('/sync')) {
          final id = path.split('/')[4];
          final after = int.parse(request.uri.queryParameters['afterSeq']!);
          final count = _conversations.firstWhere((e) => e.$1 == id).$3;
          return reply({
            'messages': [
              for (var seq = 1; seq <= count; seq++)
                if (seq > after) row(id, seq),
            ],
            'hasMore': false,
          });
        }
        return reply({'error': 'not_found'}, status: 404);
      });

      runtime = ClientRuntime();
      await runtime.initialize();
      runtime.reconnect?.cancel();
      await runtime.refreshConversations();
    });

    addTearDown(() async {
      await server.close(force: true);
      try {
        await root.delete(recursive: true);
      } catch (_) {
        // A still-open snapshot file is a harness artifact, not a product signal.
      }
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    debugPrint(
      'capture: ready=${runtime.ready} online=${runtime.online} '
      'authenticated=${runtime.authenticated} locked=${runtime.locked} '
      'onboarded=${runtime.onboarded} error=${runtime.error} '
      'conversations=${runtime.conversations.length} '
      'unread=${runtime.conversations.map((e) => '${e.id}:${e.unread}').join(',')}',
    );
    expect(runtime.authenticated, isTrue);
    expect(runtime.online, isTrue);

    tester.view.physicalSize = const Size(1280, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(key: boundary, child: WhaleChatApp(model: runtime)),
    );
    // Bounded pumps: the shell must not rely on an indefinitely animating
    // placeholder to settle before a capture.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('项目小组'), findsOneWidget);

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

    // `readSeqFor`/`headSeqFor` and the unread projection do not exist on the
    // baseline revision, so the opened-state half of this driver only runs where
    // the feature is present. The Before image is the same widget, viewport,
    // theme and fixture without the projection; the unedited baseline render.
    final supportsReadPosition = _supportsReadPosition(runtime);
    debugPrint('capture: supportsReadPosition=$supportsReadPosition');
    if (opened.isNotEmpty && supportsReadPosition) {
      // Same viewport/theme; one conversation explicitly opened so its badge is
      // cleared while the others keep theirs.
      await tester.tap(find.byKey(const ValueKey('team-project')));
      // The local read position is checkpointed through real file IO, whose
      // continuation is scheduled in the fake-async zone. Alternating runAsync
      // (lets the IO complete) with pump (lets the continuation run) is what
      // drives the production path to completion here.
      var marked = false;
      for (var i = 0; i < 200 && !marked; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        marked = _readSeqFor(runtime, 'team-project') > 0;
      }
      expect(marked, isTrue, reason: 'the local read position was checkpointed');
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      debugPrint(
        'capture: after open unread='
        '${runtime.conversations.map((e) => '${e.id}:${e.unread}').join(',')} '
        'readSeq=${_readSeqFor(runtime, 'team-project')}',
      );
      expect(
        runtime.conversations
            .firstWhere((entry) => entry.id == 'team-project')
            .unread,
        0,
        reason: 'opening clears only that conversation badge',
      );
      expect(
        runtime.conversations
            .firstWhere((entry) => entry.id == 'family')
            .unread,
        2,
        reason: 'unopened conversations keep their badge',
      );
      await capture(opened);
      // The receipt is issued after the local mark and needs real IO, so keep
      // alternating runAsync (completes the socket) with pump (runs the
      // continuation) until the production report lands.
      for (var i = 0; i < 200 && acks.isEmpty; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(acks, hasLength(1), reason: 'exactly one read receipt per open');
      expect(acks.single.$1, '/api/v1/conversations/team-project/ack');
      expect((acks.single.$2 as Map)['seq'], 4);
      debugPrint(
        'capture: acks=${acks.map((e) => '${e.$1} ${e.$2}').join(';')}',
      );
    }

    await tester.pumpWidget(const SizedBox.shrink());
    // Cancel the runtime's periodic refresh timer before teardown: the harness
    // asserts no timer outlives the disposed widget tree.
    runtime.reconnect?.cancel();
    runtime.dispose();
  });
}
