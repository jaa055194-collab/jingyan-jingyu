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

import '../test/runtime_auth_test.dart' show Fixture;

const _chatId = 'message-ops-capture';
const _ownText = '收到，我会带上折叠椅。';
const _revised = '收到，我会带上两把折叠椅。';
const _peerText = '周末的野餐改到下午三点。';

/// The same synthetic loopback host and viewport serve the baseline and the
/// candidate. Only the production chat rendering differs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('capture the same chat before and after message operations', (
    tester,
  ) async {
    const output = String.fromEnvironment('CAPTURE_PATH');
    const sheetOutput = String.fromEnvironment('CAPTURE_SHEET_PATH');
    const editedOutput = String.fromEnvironment('CAPTURE_EDITED_PATH');
    const recallOutput = String.fromEnvironment('CAPTURE_RECALL_PATH');
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
    final fixture = (await tester.runAsync(() async {
      final host = await Fixture.create();
      host.secure = jsonEncode(host.session());
      await File('${host.root.path}/settings.json').writeAsString(
        jsonEncode({
          'preferences': {'theme': 'light', 'fontScale': 1},
        }),
      );
      final now = DateTime.now().toUtc();
      final rows = <Map<String, Object?>>[
        {
          'conversationId': _chatId,
          'seq': 1,
          'messageId': 'capture-peer',
          'senderId': 'bob',
          'kind': 'text',
          'body': {'text': _peerText},
          'sentAt': now.toIso8601String(),
        },
        {
          'conversationId': _chatId,
          'seq': 2,
          'messageId': 'capture-own',
          'senderId': 'alice',
          'kind': 'text',
          'body': {'text': _ownText},
          'sentAt': now.toIso8601String(),
        },
        {
          'conversationId': _chatId,
          'seq': 3,
          'messageId': 'capture-recalled',
          'senderId': 'bob',
          'kind': 'text',
          'body': {'recalled': true},
          'sentAt': now.toIso8601String(),
        },
      ];
      host.serve = (request) async {
        final path = request.uri.path;
        if (request.method == 'POST' && path.endsWith('/capture-own/edit')) {
          final body =
              jsonDecode(await utf8.decoder.bind(request).join()) as Map;
          rows[1]['body'] = body['body'];
          await host.reply(request, rows[1]);
          return;
        }
        await request.drain<void>();
        if (path == Routes.conversations) {
          await host.reply(request, {
            'conversations': [
              {'id': _chatId, 'name': '周末野餐'},
            ],
          });
        } else if (path == Routes.directConversations) {
          await host.reply(request, {'conversations': []});
        } else if (path == Routes.hostInfo) {
          await host.reply(request, {'isHostMachine': false});
        } else if (path.endsWith('/sync')) {
          final after = int.parse(request.uri.queryParameters['afterSeq']!);
          await host.reply(request, {
            'messages': [
              for (final row in rows)
                if ((row['seq'] as int) > after) row,
            ],
            'hasMore': false,
          });
        } else if (path.endsWith('/ack')) {
          await host.reply(request, {'acknowledgedSeq': rows.length});
        } else {
          await host.reply(request, {'error': 'not_found'}, status: 404);
        }
      };
      await runtime.initialize();
      runtime.reconnect?.cancel();
      await runtime.refreshConversations();
      await runtime.shell.markRead(_chatId, rows.length);
      await runtime.selectConversation(_chatId);
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
      await tester.pumpAndSettle();
      // On the mobile viewport the shell starts on the conversation list.
      await tester.tap(find.byKey(const ValueKey(_chatId)));
      await tester.pumpAndSettle();
      expect(find.text(_peerText), findsOneWidget);
      expect(find.text(_ownText), findsOneWidget);
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
      if (sheetOutput.isNotEmpty) {
        // Only the candidate renders an explicit operations affordance.
        final actions = find.byKey(const Key('message-actions-capture-own'));
        expect(actions, findsOneWidget);
        await tester.tap(actions);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('message-actions-sheet')), findsOneWidget);
        expect(find.byKey(const Key('message-action-edit')), findsOneWidget);
        expect(tester.takeException(), isNull);
        await capture(sheetOutput);
        if (editedOutput.isNotEmpty) {
          await tester.tap(find.byKey(const Key('message-action-edit')));
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const Key('edit-message-input')),
            _revised,
          );
          final marker = find.byKey(const Key('message-edited-capture-own'));
          final success = await tester.runAsync(() async {
            await tester.tap(find.byKey(const Key('edit-message-confirm')));
            final clock = Stopwatch()..start();
            while (marker.evaluate().isEmpty &&
                clock.elapsed < const Duration(seconds: 10)) {
              await tester.pump();
              await Future<void>.delayed(const Duration(milliseconds: 16));
            }
            return marker.evaluate().isNotEmpty;
          });
          expect(success, isTrue);
          await tester.pumpAndSettle();
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(find.text(_revised), findsOneWidget);
          expect(marker, findsOneWidget);
          expect(tester.takeException(), isNull);
          await capture(editedOutput);
        }
        if (recallOutput.isNotEmpty) {
          if (editedOutput.isEmpty) {
            await tester.tap(
              find.byKey(const Key('message-actions-sheet-close')),
            );
            await tester.pumpAndSettle();
          }
          await tester.tap(actions);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(const Key('message-action-recall')));
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('recall-message-dialog')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await capture(recallOutput);
        }
      }
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      runtime.dispose();
      await tester.runAsync(fixture.cleanup);
    }
  });
}
