import 'package:client_flutter/features/attachments/attachments_screen.dart';
import 'package:client_flutter/net/attachment_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

AttachmentMetadata _metadata() => AttachmentMetadata(
  id: 'attach-1',
  ownerAccountId: 'owner',
  conversationId: 'conv-1',
  kind: 'image',
  mime: 'image/png',
  size: 2048,
  sha256: 'a' * 64,
  width: 640,
  height: 480,
  durationMs: null,
  extractionStatus: 'pending',
  createdAt: DateTime.utc(2026, 11, 17, 13),
);

void main() {
  testWidgets(
    'without a host reader the attachment surface is honest unbound',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: AttachmentsScreen()));
      expect(find.byKey(const Key('attachment-unbound')), findsOneWidget);
      expect(find.byKey(const Key('attachment-read')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('attachment-read')))
            .onPressed,
        isNull,
      );
    },
  );

  testWidgets('entered id reads and renders honest metadata only', (
    tester,
  ) async {
    final ids = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentsScreen(
          readAttachment: (id) async {
            ids.add(id);
            return _metadata();
          },
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('attachment-id-input')),
      'attach-1',
    );
    await tester.tap(find.byKey(const Key('attachment-read')));
    await tester.pumpAndSettle();
    expect(ids, ['attach-1']);
    expect(find.byKey(const Key('attachment-metadata')), findsOneWidget);
    expect(find.text('类型：image · MIME：image/png'), findsOneWidget);
    expect(find.text('大小：2.0 KiB'), findsOneWidget);
    expect(find.text('状态：抽取中'), findsOneWidget);
    expect(find.text('会话：conv-1'), findsOneWidget);
  });

  testWidgets('failure hides upstream detail and keeps no stale metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: AttachmentsScreen(
          readAttachment: (id) async =>
              throw const FormatException('PRIVATE-DETAIL'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('attachment-id-input')),
      'attach-1',
    );
    await tester.tap(find.byKey(const Key('attachment-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-notice')), findsOneWidget);
    expect(find.textContaining('未找到或读取失败'), findsOneWidget);
    expect(find.textContaining('PRIVATE-DETAIL'), findsNothing);
    expect(find.byKey(const Key('attachment-metadata')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('attachment-id-input')),
      'other',
    );
    await tester.tap(find.byKey(const Key('attachment-read')));
    await tester.pumpAndSettle();
    expect(find.textContaining('未找到或读取失败'), findsOneWidget);
    expect(find.byKey(const Key('attachment-metadata')), findsNothing);
  });
}
