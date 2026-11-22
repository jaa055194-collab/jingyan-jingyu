import 'dart:convert';

import 'package:client_flutter/features/ai_config/owner_auto_memory_section.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_auto_memory_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _target = {
  'providerId': 'fixture-provider',
  'model': 'fixture-model',
  'origin': 'https://provider.example.invalid:8443',
  'token': 'target-token-A',
};
const _created = '2026-01-01T09:00:00.000Z';

Map<String, Object?> _entry({
  String id = 'mem-a',
  String text = '记住我喜欢桂花',
  String tier = 't0',
  String status = 'active',
  String createdAt = _created,
}) => {
  'id': id,
  'text': text,
  'tier': tier,
  'status': status,
  'createdAt': createdAt,
};

Map<String, Object?> _settings({
  int revision = 0,
  bool enabled = false,
  Map<String, Object?>? target = _target,
}) => {'revision': revision, 'enabled': enabled, 'target': target};

Map<String, Object?> _list({
  int revision = 0,
  int maxEntries = 50,
  List<Map<String, Object?>>? entries,
}) => {
  'revision': revision,
  'maxEntries': maxEntries,
  'entries': entries ?? <Map<String, Object?>>[],
};

class _AutoMemoryConnection extends HostConnection {
  _AutoMemoryConnection() : super(Uri.parse('http://fixture.invalid'), 'fixture');

  final settings = <String, Map<String, Object?>>{
    'profile-a': _settings(),
    'profile-b': _settings(),
  };
  final entries = <String, Map<String, Object?>>{
    'profile-a': _list(),
    'profile-b': _list(),
  };
  final calls = <(String method, String path, String raw)>[];
  int readStatus = 200;
  int writeStatus = 200;

  String _profileOf(String path) => path.split('/')[4];
  bool _isSettings(String path) => path.endsWith('/owner-auto-memory/settings');

  @override
  Future<Map<String, Object?>> getBoundedJson(
    String path, {
    required int maxResponseBytes,
    HostReadCancellation? cancellation,
  }) async {
    calls.add(('GET', path, ''));
    if (readStatus != 200) {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, 'auto memory read unavailable'),
      );
    }
    final profile = _profileOf(path);
    final src = _isSettings(path) ? settings[profile]! : entries[profile]!;
    return Map<String, Object?>.from(src);
  }

  @override
  Future<Map<String, Object?>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    bool retryAuthentication = true,
    bool allowEmptySuccess = false,
  }) async {
    final raw = body == null ? '' : jsonEncode(body);
    calls.add((method, path, raw));
    if (writeStatus != 200) {
      throw HostRequestException(
        Failure(
          writeStatus == 409
              ? FailureCode.conflict
              : FailureCode.unavailable,
          'auto memory write failed',
        ),
      );
    }
    final profile = _profileOf(path);
    if (_isSettings(path) && method == 'PUT') {
      final expected = body!['expectedRevision'];
      final current = settings[profile]!;
      if (expected is! int || expected != current['revision']) {
        throw const HostRequestException(
          Failure(FailureCode.conflict, 'auto memory revision changed'),
        );
      }
      final enabled = body['enabled']! as bool;
      final target = current['target'] as Map<String, Object?>?;
      final token = body['expectedTargetToken'] as String?;
      if (enabled && (target == null || token != target['token'])) {
        throw const HostRequestException(
          Failure(FailureCode.conflict, 'auto memory target changed'),
        );
      }
      if (!enabled && token != null) {
        throw const HostRequestException(
          Failure(FailureCode.invalidArgument, 'bad auto memory token'),
        );
      }
      current['enabled'] = enabled;
      current['revision'] = expected + 1;
      entries[profile]!['revision'] = expected + 1;
      return Map<String, Object?>.from(current);
    }
    if (method == 'DELETE') {
      final expected = body!['expectedRevision'];
      final current = entries[profile]!;
      if (expected is! int || expected != current['revision']) {
        throw const HostRequestException(
          Failure(FailureCode.conflict, 'auto memory revision changed'),
        );
      }
      final list = (current['entries']! as List)
          .cast<Map<String, Object?>>()
          .toList();
      if (path.endsWith('/owner-auto-memory')) {
        list.clear();
      } else {
        final id = path.split('/').last;
        list.removeWhere((entry) => entry['id'] == id);
      }
      current['entries'] = list;
      current['revision'] = expected + 1;
      settings[profile]!['revision'] = expected + 1;
      return Map<String, Object?>.from(current);
    }
    throw StateError('unexpected auto memory route $method $path');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AutoMemoryConnection connection;
  late OwnerAutoMemoryApi api;
  setUp(() {
    connection = _AutoMemoryConnection();
    api = OwnerAutoMemoryApi(connection);
  });
  tearDown(() async {
    await connection.close();
  });

  Finder key(String value) => find.byKey(Key(value));

  Future<void> pumpSection(WidgetTester t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: OwnerAutoMemorySection(
              api: api,
              profile: 'profile-a',
              aiLabel: '示例 A',
              isCurrent: () => true,
              canContactHost: () => true,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String value) async {
    final found = key(value);
    expect(found, findsOneWidget, reason: value);
    await t.ensureVisible(found);
    await t.pumpAndSettle();
    await t.tap(found);
    await t.pumpAndSettle();
  }

  testWidgets('stays unloaded until explicit read', (t) async {
    await pumpSection(t);
    expect(find.text('尚未读取宿主状态。'), findsOneWidget);
    expect(connection.calls, isEmpty);
    await tap(t, 'auto-memory-read');
    expect(find.text('未授权采集（默认关闭）。开启需单独确认当前接收条件。'), findsOneWidget);
    expect(connection.calls.first.$1, 'GET');
  });

  testWidgets('enable requires second confirm and revoke retains entries', (
    t,
  ) async {
    connection.entries['profile-a'] = _list(entries: [_entry()]);
    await pumpSection(t);
    await tap(t, 'auto-memory-read');
    await tap(t, 'auto-memory-enabled');
    expect(key('auto-memory-enable-dialog'), findsOneWidget);
    expect(find.textContaining('仅采集当前本人 AI 私聊'), findsOneWidget);
    expect(find.textContaining('fixture-model'), findsOneWidget);
    expect(find.textContaining('target-token-A'), findsNothing);
    await tap(t, 'auto-memory-enable-cancel');
    expect(connection.calls.where((c) => c.$1 == 'PUT'), isEmpty);

    await tap(t, 'auto-memory-enabled');
    await tap(t, 'auto-memory-enable-confirm');
    expect(t.widget<SwitchListTile>(key('auto-memory-enabled')).value, isTrue);
    expect(jsonDecode(connection.calls.last.$3), {
      'expectedRevision': 0,
      'enabled': true,
      'expectedTargetToken': 'target-token-A',
    });

    await tap(t, 'auto-memory-enabled');
    expect(key('auto-memory-disable-dialog'), findsOneWidget);
    await tap(t, 'auto-memory-disable-confirm');
    expect(t.widget<SwitchListTile>(key('auto-memory-enabled')).value, isFalse);
    expect(find.text('记住我喜欢桂花'), findsOneWidget);
    expect(jsonDecode(connection.calls.last.$3), {
      'expectedRevision': 1,
      'enabled': false,
      'expectedTargetToken': null,
    });
  });

  testWidgets('delete single and clear are explicit and CAS-backed', (t) async {
    connection.entries['profile-a'] = _list(
      revision: 0,
      entries: [
        _entry(),
        _entry(id: 'mem-b', text: '我最近睡得很晚', tier: 't1', status: 'pending'),
      ],
    );
    await pumpSection(t);
    await tap(t, 'auto-memory-read');
    expect(key('auto-memory-entry-mem-a'), findsOneWidget);
    expect(key('auto-memory-entry-mem-b'), findsOneWidget);

    await tap(t, 'auto-memory-delete-mem-a');
    expect(key('auto-memory-delete-dialog'), findsOneWidget);
    await tap(t, 'auto-memory-delete-cancel');
    expect(key('auto-memory-entry-mem-a'), findsOneWidget);

    await tap(t, 'auto-memory-delete-mem-a');
    await tap(t, 'auto-memory-delete-confirm');
    expect(key('auto-memory-entry-mem-a'), findsNothing);
    expect(jsonDecode(connection.calls.last.$3), {'expectedRevision': 0});

    await tap(t, 'auto-memory-clear');
    expect(key('auto-memory-clear-dialog'), findsOneWidget);
    await tap(t, 'auto-memory-clear-confirm');
    expect(key('auto-memory-entry-mem-b'), findsNothing);
    expect(find.text('还没有采集到记忆。'), findsOneWidget);
    expect(jsonDecode(connection.calls.last.$3), {'expectedRevision': 1});
  });

  testWidgets('missing target disables enable but entries remain readable', (
    t,
  ) async {
    connection.settings['profile-a'] = _settings(target: null);
    await pumpSection(t);
    await tap(t, 'auto-memory-read');
    expect(find.textContaining('当前没有可用的本人私聊接收条件'), findsOneWidget);
    expect(t.widget<SwitchListTile>(key('auto-memory-enabled')).onChanged, isNull);
  });

  testWidgets('stale revision retires the pending action', (t) async {
    connection.settings['profile-a'] = _settings(revision: 0, target: _target);
    connection.entries['profile-a'] = _list(entries: [_entry()]);
    await pumpSection(t);
    await tap(t, 'auto-memory-read');
    // A revision change between read and write must never be guessed.
    connection.settings['profile-a'] = _settings(revision: 3, target: _target);
    connection.entries['profile-a'] = _list(revision: 3, entries: [_entry()]);
    await tap(t, 'auto-memory-enabled');
    await tap(t, 'auto-memory-enable-confirm');
    expect(key('auto-memory-unknown'), findsOneWidget);
    expect(connection.calls.where((c) => c.$1 == 'PUT'), hasLength(1));
  });
}
