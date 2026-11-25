import 'dart:async';

import 'package:client_flutter/features/settings/device_sessions_screen.dart';
import 'package:client_flutter/features/settings/settings_screen.dart';
import 'package:client_flutter/net/device_sessions_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'ui_test.dart' show TestShellModel;

DeviceSummary device(
  String id, {
  String name = '工作站',
  bool current = false,
  DateTime? lastUsedAt,
}) => DeviceSummary(
  id: id,
  deviceName: name,
  lastUsedAt: lastUsedAt ?? DateTime.utc(2026, 11, 18, 2, 3, 4),
  current: current,
);

DeviceSessionsRead loaded(List<DeviceSummary> devices) =>
    DeviceSessionsRead.loaded(devices);

class TestDeviceSession extends TestShellModel {
  Object sessionContext = Object();

  @override
  Object? get ownAiSessionContext =>
      connectedAccountId == null ? null : sessionContext;
}

TestDeviceSession signedIn({String account = 'account-a'}) =>
    TestDeviceSession()
      ..connectedAccountId = account
      ..online = true;

Future<void> pump(
  WidgetTester tester, {
  Future<DeviceSessionsRead> Function()? read,
  Future<DeviceRevokeOutcome> Function(String deviceId)? revoke,
  TestShellModel? session,
  bool settle = true,
}) async {
  // Tall enough that the list, a row action and the confirmation panel are all
  // on screen; the production layout scrolls on a real device.
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: DeviceSessionsScreen(
        listDevices: read,
        revokeDevice: revoke,
        session: session,
      ),
    ),
  );
  if (settle) await tester.pumpAndSettle();
}

/// Submits the open confirmation without waiting for a pending animation: an
/// in-flight revoke shows a progress indicator, so `pumpAndSettle` would hang.
Future<void> submitConfirmation(WidgetTester tester) async {
  final submit = find.byKey(const Key('device-confirm-submit'));
  await tester.ensureVisible(submit);
  await tester.pumpAndSettle();
  await tester.tap(submit);
  await tester.pump();
}

void main() {
  testWidgets('unbound screen states the missing connection and disables refresh', (
    tester,
  ) async {
    await pump(tester);
    expect(find.byKey(const Key('device-sessions-unbound')), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('device-sessions-refresh')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('lists devices with name and honest UTC last-used timestamps', (
    tester,
  ) async {
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device(
          'device-b',
          name: '手机',
          lastUsedAt: DateTime.utc(2026, 11, 17, 10),
        ),
      ]),
    );
    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
    expect(find.byKey(const Key('device-row-device-b')), findsOneWidget);
    expect(find.text('工作站'), findsOneWidget);
    expect(find.text('手机'), findsOneWidget);
    expect(find.textContaining('2026-11-18T02:03:04.000Z'), findsOneWidget);
  });

  testWidgets('marks the current device when the host reports one', (tester) async {
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
    );
    expect(find.byKey(const Key('device-current-device-b')), findsOneWidget);
    expect(find.byKey(const Key('device-current-device-a')), findsNothing);
    expect(find.text('本机'), findsOneWidget);
    expect(find.byKey(const Key('device-current-unknown')), findsNothing);
  });

  testWidgets('states honestly when the host reports no current device', (
    tester,
  ) async {
    await pump(tester, read: () async => loaded([device('device-a')]));
    expect(find.byKey(const Key('device-current-unknown')), findsOneWidget);
    expect(find.text('本机'), findsNothing);
  });

  testWidgets('empty list is a loaded empty state', (tester) async {
    await pump(tester, read: () async => loaded(const []));
    expect(find.byKey(const Key('device-sessions-empty')), findsOneWidget);
  });

  testWidgets('denied read is honest and never claims a list', (tester) async {
    await pump(
      tester,
      read: () async =>
          const DeviceSessionsRead(DeviceSessionsStatus.unauthenticated),
    );
    expect(find.byKey(const Key('device-sessions-denied')), findsOneWidget);
    expect(find.byKey(const Key('device-sessions-empty')), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('an unavailable read is honest and leaks nothing', (tester) async {
    await pump(
      tester,
      read: () async =>
          const DeviceSessionsRead(DeviceSessionsStatus.unavailable),
    );
    expect(find.byKey(const Key('device-sessions-unavailable')), findsOneWidget);
    expect(find.byKey(const Key('device-sessions-malformed')), findsNothing);
    expect(find.textContaining('secret'), findsNothing);
  });

  testWidgets('a malformed read is distinct from unavailable', (tester) async {
    await pump(
      tester,
      read: () async =>
          const DeviceSessionsRead(DeviceSessionsStatus.malformed),
    );
    expect(find.byKey(const Key('device-sessions-malformed')), findsOneWidget);
    expect(find.byKey(const Key('device-sessions-unavailable')), findsNothing);
  });

  testWidgets('a throwing reader is unavailable, never an unhandled error', (
    tester,
  ) async {
    await pump(tester, read: () async => throw StateError('secret detail'));
    expect(find.byKey(const Key('device-sessions-unavailable')), findsOneWidget);
    expect(find.textContaining('secret detail'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('another row and refresh cannot hide an in-flight revoke result', (
    tester,
  ) async {
    final gate = Completer<DeviceRevokeOutcome>();
    var reads = 0;
    final revokedIds = <String>[];
    await pump(
      tester,
      read: () async {
        reads++;
        return loaded([
          device('device-a', name: '工作站'),
          device('device-b', name: '手机', current: true),
        ]);
      },
      revoke: (id) {
        revokedIds.add(id);
        return gate.future;
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);

    await tester.tap(find.byKey(const Key('device-revoke-device-b')));
    await tester.pump();
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
    expect(find.text('设备：工作站（device-a）'), findsOneWidget);
    expect(
      tester.widget<TextButton>(
        find.byKey(const Key('device-revoke-device-b')),
      ).onPressed,
      isNull,
    );

    await tester.tap(find.byKey(const Key('device-sessions-refresh')));
    await tester.pump();
    expect(
      tester.widget<TextButton>(
        find.byKey(const Key('device-sessions-refresh')),
      ).onPressed,
      isNull,
    );
    expect(reads, 1);
    expect(revokedIds, ['device-a']);

    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-row-device-b')), findsOneWidget);
    expect(find.textContaining('已远程下线：工作站'), findsOneWidget);
    expect(reads, 1);
    expect(revokedIds, ['device-a']);
  });

  testWidgets('refresh cannot start a read while a revoke is in flight', (
    tester,
  ) async {
    final gate = Completer<DeviceRevokeOutcome>();
    var reads = 0;
    await pump(
      tester,
      read: () async {
        reads++;
        return loaded([
          device('device-a', name: '工作站'),
          device('device-b', name: '手机', current: true),
        ]);
      },
      revoke: (id) => gate.future,
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);

    await tester.tap(find.byKey(const Key('device-sessions-refresh')));
    await tester.pump();
    expect(reads, 1);
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);

    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.textContaining('已远程下线：工作站'), findsOneWidget);
    expect(reads, 1);
  });

  testWidgets('cancelling the confirmation never issues a revoke', (tester) async {
    final calls = <String>[];
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async {
        calls.add(id);
        return DeviceRevokeOutcome.revoked(id);
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
    await tester.tap(find.byKey(const Key('device-confirm-cancel')));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(find.byKey(const Key('device-confirm-panel')), findsNothing);
    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
  });

  testWidgets('confirmed revoke removes the row only after host confirmation', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async {
        calls.add(id);
        return DeviceRevokeOutcome.revoked(id);
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(calls, ['device-a']);
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-row-device-b')), findsOneWidget);
    expect(find.byKey(const Key('device-sessions-notice')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsOneWidget);
    expect(find.byKey(const Key('device-confirm-panel')), findsNothing);
  });

  testWidgets('a failed revoke shows a per-device failure and never auto-retries', (
    tester,
  ) async {
    var calls = 0;
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async {
        calls++;
        return DeviceRevokeOutcome.unavailable(id);
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.byKey(const Key('device-failure-device-a')), findsOneWidget);
    expect(find.textContaining('不会自动重试'), findsOneWidget);
    // The row is retained: nothing was revoked.
    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(calls, 1);
  });

  testWidgets('an unauthenticated revoke is reported as not revoked', (
    tester,
  ) async {
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async => DeviceRevokeOutcome.unauthenticated(id),
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-failure-device-a')), findsOneWidget);
    expect(find.textContaining('未确认下线'), findsOneWidget);
    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
  });

  testWidgets('a malformed revoke response never claims success', (tester) async {
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async => DeviceRevokeOutcome.malformed(id),
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-failure-device-a')), findsOneWidget);
    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsNothing);
  });

  testWidgets('a revoke result for another device leaves controls usable', (
    tester,
  ) async {
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (_) async => DeviceRevokeOutcome.revoked('device-b'),
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pump();

    expect(find.byKey(const Key('device-row-device-a')), findsOneWidget);
    expect(find.byKey(const Key('device-failure-device-a')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsNothing);
    expect(
      tester.widget<TextButton>(
        find.byKey(const Key('device-sessions-refresh')),
      ).onPressed,
      isNotNull,
    );
  });

  testWidgets('the host-reported current device needs a stronger confirmation', (
    tester,
  ) async {
    final calls = <String>[];
    await pump(
      tester,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async {
        calls.add(id);
        return DeviceRevokeOutcome.revoked(id);
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-b')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
    expect(find.byKey(const Key('device-confirm-name')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('device-confirm-submit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('device-confirm-name')), '手机');
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(calls, ['device-b']);
    expect(find.byKey(const Key('device-row-device-b')), findsNothing);
  });

  testWidgets('unknown current device forces the stronger gate for every row', (
    tester,
  ) async {
    await pump(
      tester,
      read: () async => loaded([device('device-a', name: '工作站')]),
      revoke: (id) async => DeviceRevokeOutcome.revoked(id),
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-name')), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('device-confirm-submit')))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byKey(const Key('device-confirm-name')), '手机');
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('device-confirm-submit')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('lock then unlock cannot restore a pending read result', (
    tester,
  ) async {
    final session = signedIn();
    final gate = Completer<DeviceSessionsRead>();
    var reads = 0;
    await pump(
      tester,
      session: session,
      read: () {
        reads++;
        return gate.future;
      },
      revoke: (id) async => DeviceRevokeOutcome.revoked(id),
      settle: false,
    );
    await tester.pump();
    expect(reads, 1);
    session.locked = true;
    session.notifyListeners();
    await tester.pumpAndSettle();
    session.locked = false;
    session.notifyListeners();
    await tester.pumpAndSettle();

    // The route's reader is still bound to the original connection. A lock
    // permanently invalidates it, even after the same account unlocks.
    await tester.tap(find.byKey(const Key('device-sessions-refresh')));
    await tester.pump();
    expect(reads, 1);
    gate.complete(loaded([device('private-device', name: '私密设备名')]));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byKey(const Key('device-row-private-device')), findsNothing);
    expect(find.text('私密设备名'), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
  });

  testWidgets('same-account session replacement discards pending revoke', (
    tester,
  ) async {
    final session = signedIn();
    final gate = Completer<DeviceRevokeOutcome>();
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '旧会话设备名'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) => gate.future,
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);

    final originalContext = session.sessionContext;
    session.sessionContext = Object();
    session.notifyListeners();
    await tester.pump();
    expect(find.byKey(const Key('device-confirm-panel')), findsNothing);
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);

    session.sessionContext = originalContext;
    session.notifyListeners();
    await tester.pump();
    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.text('旧会话设备名'), findsNothing);
    expect(find.byKey(const Key('device-sessions-notice')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
  });

  testWidgets('account change disables refresh on a route bound to old connection', (
    tester,
  ) async {
    final session = signedIn();
    var reads = 0;
    await pump(
      tester,
      session: session,
      read: () async {
        reads++;
        return loaded([device('device-a')]);
      },
      revoke: (id) async => DeviceRevokeOutcome.revoked(id),
    );
    expect(reads, 1);
    session.connectedAccountId = 'account-b';
    session.notifyListeners();
    await tester.pumpAndSettle();
    session.connectedAccountId = 'account-a';
    session.notifyListeners();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('device-sessions-refresh')));
    await tester.pumpAndSettle();
    expect(reads, 1);
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
  });

  testWidgets('lock clears a completed revoke message containing a device name', (
    tester,
  ) async {
    final session = signedIn();
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '私密设备名'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async => DeviceRevokeOutcome.revoked(id),
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    await tester.pumpAndSettle();
    expect(find.textContaining('私密设备名'), findsOneWidget);

    session.locked = true;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-sessions-notice')), findsNothing);
    expect(find.text('私密设备名'), findsNothing);
    expect(find.textContaining('已远程下线'), findsNothing);
  });

  testWidgets('lock during the request discards the result and the confirmation', (
    tester,
  ) async {
    final session = signedIn();
    final gate = Completer<DeviceRevokeOutcome>();
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) => gate.future,
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
    session.locked = true;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-panel')), findsNothing);
    session.locked = false;
    session.notifyListeners();
    await tester.pumpAndSettle();
    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();
    // Unlocking does not make the old request or its metadata current again.
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-sessions-notice')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsNothing);
  });

  testWidgets('account change during the request discards the result', (
    tester,
  ) async {
    final session = signedIn();
    final gate = Completer<DeviceRevokeOutcome>();
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) => gate.future,
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    session.connectedAccountId = 'account-b';
    session.notifyListeners();
    await tester.pumpAndSettle();
    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsNothing);
  });

  testWidgets('logout during the request discards the result', (tester) async {
    final session = signedIn();
    final gate = Completer<DeviceRevokeOutcome>();
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) => gate.future,
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    await submitConfirmation(tester);
    session.connectedAccountId = null;
    session.notifyListeners();
    await tester.pumpAndSettle();
    gate.complete(DeviceRevokeOutcome.revoked('device-a'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-row-device-a')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
    expect(find.textContaining('已远程下线'), findsNothing);
  });

  testWidgets('lock closes an open confirmation without revoking', (tester) async {
    final session = signedIn();
    var calls = 0;
    await pump(
      tester,
      session: session,
      read: () async => loaded([
        device('device-a', name: '工作站'),
        device('device-b', name: '手机', current: true),
      ]),
      revoke: (id) async {
        calls++;
        return DeviceRevokeOutcome.revoked(id);
      },
    );
    await tester.tap(find.byKey(const Key('device-revoke-device-a')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-panel')), findsOneWidget);
    session.locked = true;
    session.notifyListeners();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('device-confirm-panel')), findsNothing);
    expect(find.byKey(const Key('device-sessions-discarded')), findsOneWidget);
    expect(calls, 0);
  });

  testWidgets('settings exposes exactly one device sessions entry', (tester) async {
    final model = signedIn();
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: model,
          builder: (_, _) =>
              Scaffold(body: SettingsScreen(model: model, onBack: () {})),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final entry = find.byKey(const Key('open-device-sessions'));
    await tester.scrollUntilVisible(entry, 300);
    await tester.pumpAndSettle();
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.byType(DeviceSessionsScreen), findsOneWidget);
    // TestShellModel is not a ClientRuntime, so no host connection is bound.
    expect(find.byKey(const Key('device-sessions-unbound')), findsOneWidget);
  });
}
