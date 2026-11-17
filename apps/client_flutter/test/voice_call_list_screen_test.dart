import 'package:client_flutter/features/voice/voice_call_list_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_call_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

VoiceCallView _call(String id, {DateTime? startedAt}) => VoiceCallView.fromJson(
  {
    'callId': id,
    'aiId': 'ai-1',
    'peerAccountId': 'acct-1',
    'state': 'ended',
    'startedAt': (startedAt ?? DateTime.utc(2026, 3, 1, 12)).toIso8601String(),
  },
);

class _FakeLister {
  final List<({String? status, int limit, DateTime? before})> calls = [];
  final Map<String?, List<List<VoiceCallView>>> pages = {};
  Object? error;

  Future<List<VoiceCallView>> call({
    String? status,
    required int limit,
    DateTime? before,
  }) async {
    calls.add((status: status, limit: limit, before: before));
    final error = this.error;
    if (error != null) throw error;
    final pages = this.pages[status] ?? const [];
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
      home: VoiceCallListScreen(listCalls: lister?.call, pageSize: pageSize),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unbound without an injected lister', (tester) async {
    await _pump(tester, null);
    expect(find.byKey(const Key('voice-call-list-unbound')), findsOneWidget);
    expect(find.byKey(const Key('voice-call-list-refresh')), findsNothing);
  });

  testWidgets('empty list is an honest empty state', (tester) async {
    final lister = _FakeLister()..pages[null] = [<VoiceCallView>[]];
    await _pump(tester, lister);
    expect(find.byKey(const Key('voice-call-list-empty')), findsOneWidget);
    expect(lister.calls.single.limit, 50);
    expect(lister.calls.single.status, isNull);
  });

  testWidgets('renders metadata cards only (no audio/transcript UI)', (
    tester,
  ) async {
    final lister = _FakeLister()
      ..pages[null] = [
        [_call('call-1'), _call('call-2')],
      ];
    await _pump(tester, lister);
    expect(find.byKey(const Key('voice-call-item-call-1')), findsOneWidget);
    expect(find.byKey(const Key('voice-call-item-call-2')), findsOneWidget);
    expect(find.textContaining('状态：已结束'), findsWidgets);
    expect(find.textContaining('对端账号：acct-1'), findsWidgets);
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('denied is honest and hides details', (tester) async {
    final lister = _FakeLister()
      ..error = const HostRequestException(
        Failure(FailureCode.forbidden, 'secret-denied-detail'),
      );
    await _pump(tester, lister);
    expect(find.byKey(const Key('voice-call-list-denied')), findsOneWidget);
    expect(find.textContaining('secret-denied-detail'), findsNothing);
    expect(find.textContaining('无权限'), findsOneWidget);
  });

  testWidgets('unknown failure never auto-retries', (tester) async {
    final lister = _FakeLister()
      ..error = const HostRequestException(
        Failure(FailureCode.unavailable, 'secret-transport-detail'),
      );
    await _pump(tester, lister);
    expect(find.byKey(const Key('voice-call-list-unknown')), findsOneWidget);
    expect(find.textContaining('secret-transport-detail'), findsNothing);
    expect(lister.calls.length, 1);
  });

  testWidgets('status filter is passed explicitly', (tester) async {
    final lister = _FakeLister()..pages['missed'] = [<VoiceCallView>[]];
    await _pump(tester, lister);
    await tester.tap(find.byKey(const Key('voice-call-status-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未接来电').last);
    await tester.pumpAndSettle();
    expect(lister.calls.last.status, 'missed');
    expect(find.byKey(const Key('voice-call-list-empty')), findsOneWidget);
  });

  testWidgets('pages older calls with before = oldest startedAt', (
    tester,
  ) async {
    final lister = _FakeLister()
      ..pages[null] = [
        [
          _call('call-1'),
          _call('call-2', startedAt: DateTime.utc(2026, 3, 1, 10)),
        ],
        [_call('call-3', startedAt: DateTime.utc(2026, 3, 1, 8))],
      ];
    await _pump(tester, lister, pageSize: 2);
    final more = find.byKey(const Key('voice-call-list-load-more'));
    expect(more, findsOneWidget);
    await tester.ensureVisible(more);
    await tester.pumpAndSettle();
    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-call-item-call-3')), findsOneWidget);
    expect(lister.calls.length, 2);
    expect(lister.calls.last.before, DateTime.utc(2026, 3, 1, 10));
    expect(find.byKey(const Key('voice-call-list-load-more')), findsNothing);
  });
}
