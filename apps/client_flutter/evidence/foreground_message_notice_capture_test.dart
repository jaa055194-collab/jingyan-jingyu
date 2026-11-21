import 'dart:io';
import 'dart:ui' as ui;

import 'package:client_flutter/app/shell_app.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../test/support/foreground_notice_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;
  testWidgets(
    'capture the same authenticated Contacts page after inbound sync',
    (tester) async {
      const after = bool.fromEnvironment('CAPTURE_AFTER');
      const output = String.fromEnvironment('CAPTURE_PATH');
      const font = String.fromEnvironment('CAPTURE_CJK_FONT');
      const icons = String.fromEnvironment('CAPTURE_ICON_FONT');
      expect(output, isNotEmpty);
      for (final (family, path) in [
        ('Ahem', font),
        ('Roboto', font),
        ('MaterialIcons', icons),
      ]) {
        final bytes = File(path).readAsBytesSync();
        await (FontLoader(
          family,
        )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      }
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final fixture = (await tester.runAsync(ForegroundNoticeFixture.open))!;
      try {
        final boundary = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: WhaleChatApp(model: fixture.runtime),
          ),
        );
        await openNoticeFixturePage(tester, '联系人');
        expect(find.text(ForegroundNoticeFixture.notice), findsNothing);
        fixture.add();
        await fixture.refresh(tester);
        expect(
          find.text(ForegroundNoticeFixture.contactsEmpty),
          findsOneWidget,
        );
        expect(find.text(ForegroundNoticeFixture.peerText), findsNothing);
        expect(
          find.text(ForegroundNoticeFixture.notice),
          after ? findsOneWidget : findsNothing,
        );
        expect(
          fixture.runtime.shell.lastSeqFor(
            ForegroundNoticeFixture.conversation,
          ),
          1,
        );
        expect(fixture.runtime.conversations.single.unread, 1);
        expect(fixture.runtime.selectedConversationId, isNull);
        expect(fixture.writes, isEmpty);
        expect(tester.takeException(), isNull);
        final painter =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final bytes = await tester.runAsync(() async {
          final image = await painter.toImage();
          try {
            expect((image.width, image.height), (1280, 720));
            return await image.toByteData(format: ui.ImageByteFormat.png);
          } finally {
            image.dispose();
          }
        });
        File(output).writeAsBytesSync(
          bytes!.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(fixture.close);
      }
    },
  );
}
