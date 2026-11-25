import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/app/runtime.dart';
import 'package:client_flutter/app/shell_app.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/lifecycle_api.dart';
import 'package:client_flutter/platform/native_platform.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:material_ui/material_ui.dart';

const _owner = 'fixture-owner';
const _privatePath = 'conversations/private-identifier.jsonl';
const _privateText = 'private fixture conversation payload';

class _LifecycleConnection extends HostConnection {
  _LifecycleConnection()
    : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final calls = <(String, String)>[];

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    calls.add((method, path));
    return switch ((method, path)) {
      ('GET', Routes.lifecycleQuota) => {
        'usedBytes': 1024,
        'quotaBytes': 4096,
        'diskFreeBytes': 8192,
        'diskTotalBytes': 16384,
      },
      ('GET', Routes.lifecycleDepartureSurvey) => {
        'objectCounts': {'conversations': 1, 'messages': 2},
        'momentsToAnonymize': 0,
        'totalObjects': 3,
      },
      ('GET', Routes.lifecycleCleanupPreview) => {
        'dayKey': '2026-03-01',
        'remindSoon': {'video': 0, 'voice': 0},
        'expiring': {'video': 0, 'voice': 0},
        'totalHeld': {'video': 0, 'voice': 0},
      },
      _ => throw StateError('Unexpected fixture request'),
    };
  }
}

class _Runtime extends ClientRuntime {
  _Runtime(_LifecycleConnection host) {
    connection = host;
  }

  String? owner = _owner;
  int epoch = 0;
  Object lockEpoch = Object();
  bool isLocked = false;

  @override
  bool get ready => true;
  @override
  bool get onboarded => true;
  @override
  bool get chatEntered => true;
  @override
  bool get online => true;
  @override
  bool get locked => isLocked;
  @override
  String? get connectedAccountId => owner;
  @override
  Object? get ownAiSessionContext => authenticated ? epoch : null;
  @override
  Object? get ownAiDirectContext => authenticated && !locked ? lockEpoch : null;

  void lock() {
    isLocked = true;
    lockEpoch = Object();
    notifyListeners();
  }

  void releaseFixtureLock() {
    isLocked = false;
    notifyListeners();
  }
}

/// Uses ClientRuntime's real app-lock persistence and lifecycle callbacks;
/// only shell auth presentation and native method responses are fixtures.
class _LifecycleRuntime extends ClientRuntime {
  @override
  bool get chatEntered => true;
  @override
  String? get connectedAccountId => _owner;
}

Finder get _preview => find.byKey(const Key('preview-backup-file'));
Finder get _summary => find.byKey(const Key('backup-file-preview-summary'));

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

Future<void> _open(WidgetTester tester, ClientRuntime runtime) async {
  addTearDown(runtime.dispose);
  await tester.pumpWidget(WhaleChatApp(model: runtime));
  await tester.pumpAndSettle();
  await tester.tap(find.byTooltip('设置'));
  await tester.pumpAndSettle();
  final entry = find.byKey(const Key('open-lifecycle-status'));
  await _show(tester, entry);
  await tester.tap(entry);
  await tester.pumpAndSettle();
  await _show(tester, find.byKey(const Key('export-lifecycle')));
  expect(
    _preview,
    findsOneWidget,
    reason: 'preview belongs to the existing lifecycle page',
  );
  await _show(tester, _preview);
}

void _picker(WidgetTester tester, Future<Object?> Function() pick) {
  final messenger = tester.binding.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(NativePlatform.channel, (call) async {
    expect(call.method, 'pickAttachment');
    expect(call.arguments, {'kind': 'file'});
    return pick();
  });
  addTearDown(
    () => messenger.setMockMethodCallHandler(NativePlatform.channel, null),
  );
}

String _export({String owner = _owner}) {
  final manifest = <String, Object?>{
    'formatVersion': 1,
    'ownerAccountId': owner,
    'generatedAt': '2026-03-01T11:45:12.000Z',
    'counts': {
      'conversations': 1,
      'messages': 1,
      'memories': 0,
      'attachments': 0,
      'persona': 0,
    },
    'excluded': {'t2Memories': 0, 'byokSecrets': 'stripped'},
  };
  final files = <String, String>{
    'persona.json': '{}',
    'memories.json': '{"memories":[],"excludedT2Count":0}',
    'attachments.json': '{"attachments":[]}',
    'manifest.json': jsonEncode(manifest),
    _privatePath: jsonEncode({'seq': 1, 'text': _privateText}),
  };
  final sums = files.entries
      .map(
        (entry) => '${sha256.convert(utf8.encode(entry.value))}  ${entry.key}',
      )
      .join('\n');
  return LifecycleExportBundle.fromJson({
    'ownerAccountId': owner,
    'files': {...files, 'SHA256SUMS': sums},
    'manifest': manifest,
    'sha256sums': sums,
  }).exportFileContents();
}

File _writeFixture({String owner = _owner}) {
  final folder = Directory.systemTemp.createTempSync('jingyu-preview-route-');
  addTearDown(() => folder.deleteSync(recursive: true));
  return File('${folder.path}${Platform.pathSeparator}private-export.json')
    ..writeAsStringSync(_export(owner: owner));
}

Map<String, Object> _picked(File file) => {
  'path': file.path,
  'name': 'private-export.json',
};

/// Dispatch in the real zone, so the production dart:io calls can finish.
Future<void> _readRealFile(
  WidgetTester tester, {
  bool eventuallyEnabled = true,
}) async {
  await tester.runAsync(() async {
    tester.widget<OutlinedButton>(_preview).onPressed!();
    // The pending label differs from both success and sticky invalidation.
    await tester.pump();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (find.text('正在选择或预检…').evaluate().isNotEmpty &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await tester.pump();
    }
    expect(find.text('正在选择或预检…'), findsNothing);
  });
  await tester.pumpAndSettle();
  if (eventuallyEnabled) {
    expect(tester.widget<OutlinedButton>(_preview).onPressed, isNotNull);
  }
}

void main() {
  for (final enabled in [false, true]) {
    testWidgets(
      'real runtime inactive during picker with app lock enabled=$enabled',
      (tester) async {
        final root = Directory.systemTemp.createTempSync(
          'jingyu-lock-fixture-',
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final file = _writeFixture();
        final host = _LifecycleConnection();
        final runtime = _LifecycleRuntime();
        final methods = <String>[];
        final messenger = tester.binding.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(NativePlatform.channel, (
          call,
        ) async {
          methods.add(call.method);
          switch (call.method) {
            case 'initialize':
              return {'platform': 'windows'};
            case 'getDataDirectory':
              return root.path;
            case 'readSession':
            case 'lock':
              return null;
            case 'hasPin':
              return false;
            case 'configurePin':
            case 'unlockPin':
              return true;
            case 'pickAttachment':
              expect(call.arguments, {'kind': 'file'});
              final originalEpoch = runtime.ownAiDirectContext;
              runtime.didChangeAppLifecycleState(AppLifecycleState.inactive);
              expect(runtime.locked, enabled);
              if (enabled) await runtime.appLock.unlockWithPin('1234');
              runtime.didChangeAppLifecycleState(AppLifecycleState.resumed);
              expect(runtime.locked, isFalse);
              expect(runtime.ownAiDirectContext, isNot(same(originalEpoch)));
              return _picked(file);
            default:
              fail('Unexpected native method: ${call.method}');
          }
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(NativePlatform.channel, null),
        );
        await tester.runAsync(() async {
          await runtime.initialize();
          expect(runtime.error, isNull);
          if (enabled) await runtime.setAppLock(true, '1234');
        });
        runtime.reconnect?.cancel();
        expect(runtime.appLockEnabled, enabled);
        runtime.connection = host;
        await _open(tester, runtime);
        final reads = host.calls.toList();
        await _readRealFile(tester, eventuallyEnabled: !enabled);
        expect(_summary, enabled ? findsNothing : findsOneWidget);
        expect(
          methods.where((method) => method == 'pickAttachment'),
          hasLength(1),
        );
        expect(methods.where((method) => method == 'lock'), hasLength(1));
        expect(host.calls, reads);
      },
      skip: !Platform.isWindows,
    );
  }

  testWidgets(
    'Settings offers an explicit local pick and cancel makes no host request',
    (tester) async {
      final host = _LifecycleConnection();
      var picks = 0;
      _picker(tester, () async {
        picks++;
        return null;
      });
      await _open(tester, _Runtime(host));
      expect(picks, 0);
      final reads = host.calls.toList();
      expect(
        reads,
        unorderedEquals([
          ('GET', Routes.lifecycleQuota),
          ('GET', Routes.lifecycleDepartureSurvey),
          ('GET', Routes.lifecycleCleanupPreview),
        ]),
      );
      await tester.tap(_preview);
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(find.textContaining('已取消选择'), findsOneWidget);
      expect(_summary, findsNothing);
      expect(host.calls, reads);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'a real file renders only summary, never enables import, and cancel clears it',
    (tester) async {
      final file = _writeFixture();
      final host = _LifecycleConnection();
      var picks = 0;
      _picker(tester, () async => picks++ == 0 ? _picked(file) : null);
      tester.view.physicalSize = const Size(768, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _open(tester, _Runtime(host));
      final reads = host.calls.toList();
      await _readRealFile(tester);
      expect(_summary, findsOneWidget);
      expect(find.textContaining('清单计数：会话 1，消息 1'), findsOneWidget);
      for (final private in [
        file.path,
        'private-export.json',
        _privatePath,
        _privateText,
        _owner,
      ]) {
        expect(find.textContaining(private), findsNothing);
      }
      final import = find.byKey(const Key('import-lifecycle'));
      await tester.ensureVisible(import);
      expect(tester.widget<FilledButton>(import).onPressed, isNull);
      await _show(tester, _preview);
      await tester.tap(_preview);
      await tester.pumpAndSettle();
      expect(_summary, findsNothing);
      expect(find.textContaining('已取消选择'), findsOneWidget);
      expect(host.calls, reads);
      expect(file.readAsStringSync(), _export());
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'a different package owner is refused without revealing either account',
    (tester) async {
      final file = _writeFixture(owner: 'fixture-other-owner');
      final host = _LifecycleConnection();
      _picker(tester, () async => _picked(file));
      await _open(tester, _Runtime(host));
      final reads = host.calls.toList();
      await _readRealFile(tester);
      expect(_summary, findsNothing);
      expect(find.textContaining('不属于当前账号'), findsOneWidget);
      expect(find.textContaining('fixture-other-owner'), findsNothing);
      expect(find.textContaining(_owner), findsNothing);
      expect(host.calls, reads);
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'rapid lock/unlock clears a loaded preview and blocks retained pick callback',
    (tester) async {
      final file = _writeFixture();
      final host = _LifecycleConnection();
      final runtime = _Runtime(host);
      var picks = 0;
      _picker(tester, () async {
        picks++;
        return _picked(file);
      });
      await _open(tester, runtime);
      final reads = host.calls.toList();
      await _readRealFile(tester);
      expect(_summary, findsOneWidget);
      final retained = tester.widget<OutlinedButton>(_preview).onPressed!;
      runtime.lock();
      runtime.releaseFixtureLock();
      retained();
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(_summary, findsNothing);
      expect(tester.widget<OutlinedButton>(_preview).onPressed, isNull);
      expect(host.calls, reads);
    },
    skip: !Platform.isWindows,
  );

  for (final transition in [
    'lock',
    'logout',
    'account',
    'connection',
    'route pop',
  ]) {
    testWidgets('late picker failure cannot publish after $transition', (
      tester,
    ) async {
      final host = _LifecycleConnection();
      final runtime = _Runtime(host);
      final pick = Completer<Object?>();
      var picks = 0;
      _picker(tester, () async {
        picks++;
        return pick.future;
      });
      await _open(tester, runtime);
      final reads = host.calls.toList();
      final retained = tester.widget<OutlinedButton>(_preview).onPressed!;
      await tester.tap(_preview);
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(tester.widget<OutlinedButton>(_preview).onPressed, isNull);
      switch (transition) {
        case 'lock':
          runtime.lock();
          runtime.releaseFixtureLock();
        case 'logout':
          runtime.owner = null;
          runtime.notifyListeners();
          runtime.owner = _owner;
          runtime.epoch++;
          runtime.notifyListeners();
        case 'account':
          runtime.owner = 'replacement-owner';
          runtime.notifyListeners();
        case 'connection':
          final replacement = _LifecycleConnection();
          addTearDown(host.close);
          runtime.connection = replacement;
          runtime.notifyListeners();
          expect(replacement.calls, isEmpty);
        case 'route pop':
          Navigator.of(tester.element(_preview)).pop();
      }
      // A bad picker payload would produce a notice if the old route accepted it.
      pick.complete({'wrong': 'private selected path'});
      retained();
      await tester.pumpAndSettle();
      expect(picks, 1);
      expect(_summary, findsNothing);
      expect(find.byKey(const Key('backup-file-preview-notice')), findsNothing);
      expect(host.calls, reads);
      if (transition == 'route pop') {
        expect(_preview, findsNothing);
      } else {
        expect(tester.widget<OutlinedButton>(_preview).onPressed, isNull);
      }
    }, skip: !Platform.isWindows);
  }
}
