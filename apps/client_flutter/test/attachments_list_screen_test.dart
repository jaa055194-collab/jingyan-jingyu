import 'package:client_flutter/features/attachments/attachments_list_screen.dart';
import 'package:client_flutter/net/attachment_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

AttachmentListItem _item(String id, {String? conversation, int size = 2048}) =>
    AttachmentListItem(
      id: id,
      conversationId: conversation,
      kind: 'image',
      mime: 'image/png',
      size: size,
      extractionStatus: 'extracted',
      createdAt: DateTime.utc(2026, 3, 1, 12),
    );

class _FakeLister {
  final List<({String? conversationId, int limit, DateTime? before})> calls =
      [];
  final Map<String?, List<List<AttachmentListItem>>> pages = {};
  Object? error;

  Future<List<AttachmentListItem>> call({
    String? conversationId,
    required int limit,
    DateTime? before,
  }) async {
    calls.add((conversationId: conversationId, limit: limit, before: before));
    final error = this.error;
    if (error != null) throw error;
    final pages = this.pages[conversationId] ?? const [];
    final index = before == null ? 0 : 1;
    return index < pages.length ? pages[index] : const [];
  }
}

Future<void> _pump(
  WidgetTester tester,
  _FakeLister? lister, {
  int pageSize = 50,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: AttachmentsListScreen(
        listAttachments: lister?.call,
        pageSize: pageSize,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unbound without an injected lister', (tester) async {
    await _pump(tester, null);
    expect(find.byKey(const Key('attachments-unbound')), findsOneWidget);
    expect(find.byKey(const Key('attachments-refresh')), findsNothing);
  });

  testWidgets('empty list is an honest empty state', (tester) async {
    final lister = _FakeLister()..pages[null] = [<AttachmentListItem>[]];
    await _pump(tester, lister);
    expect(find.byKey(const Key('attachments-empty')), findsOneWidget);
    expect(lister.calls.single.limit, 50);
  });

  testWidgets('renders metadata cards and no file content', (tester) async {
    final lister = _FakeLister()
      ..pages[null] = [
        [_item('att-1', conversation: 'conv-1'), _item('att-2', size: 3145728)],
      ];
    await _pump(tester, lister);
    expect(find.byKey(const Key('attachment-item-att-1')), findsOneWidget);
    expect(find.byKey(const Key('attachment-item-att-2')), findsOneWidget);
    expect(find.textContaining('会话：conv-1'), findsOneWidget);
    expect(find.textContaining('会话：未绑定会话'), findsOneWidget);
    expect(find.textContaining('大小：3.0 MiB'), findsOneWidget);
    expect(find.textContaining('状态：已抽取'), findsWidgets);
  });

  testWidgets('denied is honest and hides details', (tester) async {
    final lister = _FakeLister()
      ..error = const HostRequestException(
        Failure(FailureCode.forbidden, 'secret-denied-detail'),
      );
    await _pump(tester, lister);
    expect(find.byKey(const Key('attachments-denied')), findsOneWidget);
    expect(find.textContaining('secret-denied-detail'), findsNothing);
    expect(find.textContaining('无权限'), findsOneWidget);
  });

  testWidgets('unknown failure never auto-retries', (tester) async {
    final lister = _FakeLister()
      ..error = const HostRequestException(
        Failure(FailureCode.unavailable, 'secret-transport-detail'),
      );
    await _pump(tester, lister);
    expect(find.byKey(const Key('attachments-unknown')), findsOneWidget);
    expect(find.textContaining('secret-transport-detail'), findsNothing);
    expect(lister.calls.length, 1);
  });

  testWidgets('passes conversation filter explicitly', (tester) async {
    final lister = _FakeLister()..pages['conv-1'] = [<AttachmentListItem>[]];
    await _pump(tester, lister);
    await tester.enterText(
      find.byKey(const Key('attachments-conversation')),
      'conv-1',
    );
    await tester.tap(find.byKey(const Key('attachments-refresh')));
    await tester.pumpAndSettle();
    expect(lister.calls.last.conversationId, 'conv-1');
    expect(find.byKey(const Key('attachments-empty')), findsOneWidget);
  });

  testWidgets('pages older items with before = oldest createdAt', (
    tester,
  ) async {
    final lister = _FakeLister()
      ..pages[null] = [
        [_item('att-1'), _item('att-2')],
        [_item('att-3')],
      ];
    await _pump(tester, lister, pageSize: 2);
    expect(find.byKey(const Key('attachment-item-att-2')), findsOneWidget);
    final more = find.byKey(const Key('attachments-load-more'));
    expect(more, findsOneWidget);
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('attachment-item-att-3')), findsOneWidget);
    expect(lister.calls.length, 2);
    expect(lister.calls.last.before, _item('att-2').createdAt);
    expect(find.byKey(const Key('attachments-load-more')), findsNothing);
  });
}
