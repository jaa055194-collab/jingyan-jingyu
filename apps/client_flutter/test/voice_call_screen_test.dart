import 'package:client_flutter/features/voice/voice_call_screen.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_call_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

VoiceCallView _call() => VoiceCallView.fromJson({
  'callId': 'call-1',
  'aiId': 'ai-1',
  'peerAccountId': 'acct-1',
  'state': 'ringing',
  'startedAt': '2026-03-01T12:00:00Z',
});

Future<void> _pump(
  WidgetTester tester,
  Future<VoiceCallView> Function(String callId)? reader,
) async {
  await tester.pumpWidget(MaterialApp(home: VoiceCallScreen(readCall: reader)));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('unbound without an injected reader', (tester) async {
    await _pump(tester, null);
    expect(find.byKey(const Key('voice-call-unbound')), findsOneWidget);
    expect(find.byKey(const Key('voice-call-read')), findsNothing);
  });

  testWidgets('explicit callId renders read-only metadata', (tester) async {
    await _pump(tester, (id) async {
      expect(id, 'call-1');
      return _call();
    });
    await tester.enterText(
      find.byKey(const Key('voice-call-id-input')),
      'call-1',
    );
    await tester.tap(find.byKey(const Key('voice-call-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-call-metadata')), findsOneWidget);
    expect(find.textContaining('状态：响铃中'), findsOneWidget);
    expect(find.textContaining('对端账号：acct-1'), findsOneWidget);
    expect(find.textContaining('2026-03-01T12:00:00'), findsOneWidget);
  });

  testWidgets('denied is honest and hides upstream details', (tester) async {
    await _pump(tester, (id) async {
      throw const HostRequestException(
        Failure(FailureCode.forbidden, 'secret-denied-detail'),
      );
    });
    await tester.enterText(
      find.byKey(const Key('voice-call-id-input')),
      'call-1',
    );
    await tester.tap(find.byKey(const Key('voice-call-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-call-denied')), findsOneWidget);
    expect(find.textContaining('secret-denied-detail'), findsNothing);
    expect(find.textContaining('无权限'), findsOneWidget);
  });

  testWidgets('unknown and not-found are distinct honest states', (
    tester,
  ) async {
    await _pump(tester, (id) async {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'secret-transport-detail'),
      );
    });
    await tester.enterText(
      find.byKey(const Key('voice-call-id-input')),
      'call-1',
    );
    await tester.tap(find.byKey(const Key('voice-call-read')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('voice-call-unknown')), findsOneWidget);
    expect(find.textContaining('secret-transport-detail'), findsNothing);
    expect(find.textContaining('不会自动重试'), findsOneWidget);
  });
}
