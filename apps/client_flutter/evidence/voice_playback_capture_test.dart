import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

import '../test/runtime_auth_test.dart' show Fixture, channel;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture the same real chat before any voice action', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const after = bool.fromEnvironment('CAPTURE_EXPECT_PLAY');
    const font = String.fromEnvironment('CAPTURE_CJK_FONT');
    const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
    expect(output, isNotEmpty);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // The test engine uses Ahem as a fallback; the Android Material theme
    // can also ask for Roboto explicitly. Use the same CJK face for both.
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
    var voiceReads = 0;
    final nativePlayback = <String>[];
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
        if (call.method == 'playVoiceMessage' ||
            call.method == 'stopVoiceMessage') {
          nativePlayback.add(call.method);
        }
        return switch (call.method) {
          'initialize' => {
            'platform': 'android',
            'voicePlaybackEpoch': 1,
            'voicePlaybackResumed': true,
          },
          'getDataDirectory' => host.root.path,
          'readSession' => host.secure,
          'hasPin' => false,
          _ => null,
        };
      });
      host.serve = (request) async {
        await request.drain<void>();
        final path = request.uri.path;
        if (path.endsWith('/voice-attachment')) {
          voiceReads++;
          await host.reply(request, {'error': 'not_found'}, status: 404);
        } else if (path.endsWith('/ack')) {
          await host.reply(request, {'acknowledgedSeq': 2});
        } else if (path == Routes.conversations) {
          await host.reply(request, {
            'conversations': [
              {'id': 'voice-fixture', 'name': '语音会话示例'},
            ],
          });
        } else if (path.endsWith('/sync')) {
          final afterSeq = int.parse(request.uri.queryParameters['afterSeq']!);
          await host.reply(request, {
            'firstVisibleSeq': 1,
            'messages': [
              for (final (seq, id, kind, body) in [
                (1, 'fixture-text', 'text', {'text': '这是合成会话，仅用于界面验证。'}),
                (
                  2,
                  'fixture-voice',
                  'audio',
                  {'text': '合成语音', 'attachmentId': 'fixture-m4a'},
                ),
              ])
                if (seq > afterSeq)
                  {
                    'conversationId': 'voice-fixture',
                    'seq': seq,
                    'messageId': id,
                    'senderId': 'fixture-member',
                    'kind': kind,
                    'body': body,
                    'sentAt': '2026-11-20T00:00:00.000Z',
                  },
            ],
            'hasMore': false,
          });
        } else {
          await host.reply(request, {'conversations': []});
        }
      };
      await runtime.initialize();
      runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
      runtime.reconnect?.cancel();
      await runtime.refreshConversations();
      // Both captures depict the same already-read conversation, with no
      // pending receipt or other work started by opening it.
      await runtime.shell.markRead('voice-fixture', 2);
      return host;
    }))!;
    try {
      expect(runtime.online, isTrue);
      expect(runtime.locked, isFalse);
      expect(runtime.themeMode, ThemeMode.light);
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: WhaleChatApp(model: runtime),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('voice-fixture')));
      await tester.pumpAndSettle();
      expect(find.text('语音会话示例'), findsOneWidget);
      expect(find.text('合成语音'), findsOneWidget);
      final play = find.byKey(const Key('play-voice-fixture-voice'));
      expect(play.hitTestable(), after ? findsOneWidget : findsNothing);
      if (after) expect(tester.widget<TextButton>(play).onPressed, isNotNull);
      expect(voiceReads, 0);
      expect(nativePlayback, isEmpty);
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
      File(output).writeAsBytesSync(
        png!.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await tester.runAsync(fixture.cleanup);
    }
  });
}
