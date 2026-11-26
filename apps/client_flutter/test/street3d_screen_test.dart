import 'dart:async';
import 'dart:convert';

import 'package:client_flutter/features/world/street3d_protocol.dart';
import 'package:client_flutter/features/world/street3d_screen.dart';
import 'package:client_flutter/features/world/street3d_source.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/world_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

final _now = DateTime.utc(2026, 11, 26);
const _down = HostRequestException(Failure(FailureCode.unavailable, 'down'));
const _hello = <String, Object?>{
  'v': '1.0',
  'caps': ['tap', 'camera', 'stats', 'focus', 'theme'],
  'limits': {'maxSpaces': 12, 'maxResidents': 8, 'maxResidentsPerMessage': 32},
  'renderer': {'three': 'r160', 'webgl': 2},
};

Street3DStreet _street({bool empty = false}) => Street3DStreet(
  spaces: [
    if (!empty)
      Street3DSpace(
        layout: WorldSpaceLayout(
          spaceId: 'alice',
          version: 1,
          style: 'seaside',
          mainColor: '#4f8fbf',
          rooms: const [],
          updatedAt: _now,
        ),
        slot: 0,
        label: '我的别墅',
        relation: Street3DRelation.self,
      ),
  ],
  people: const {'alice': Street3DPerson('我', Street3DRole.self)},
);

WorldPresenceRecord _record(String id) => WorldPresenceRecord(
  residentId: id,
  spaceId: 'alice',
  x: 1,
  y: 0,
  z: -3,
  motion: 'walk',
  updatedAt: _now,
);

class _Source implements Street3DDataSource {
  _Source(this.street, {this.records = const []});

  final Street3DStreet street;
  List<WorldPresenceRecord> records;
  Object? loadError;
  Object? presenceError;
  var loads = 0;
  var presenceCalls = 0;

  @override
  Future<Street3DStreet> loadStreet() async {
    loads += 1;
    final error = loadError;
    if (error != null) throw error;
    return street;
  }

  @override
  Future<List<WorldPresenceRecord>> presence(List<String> spaceIds) async {
    presenceCalls += 1;
    final error = presenceError;
    if (error != null) throw error;
    return records;
  }
}

/// Stands in for the WebView: records what the screen sends and lets a test
/// speak for the page.
class _Surface implements Street3DSurface {
  // Synchronous, so a test's page message is handled before its next pump.
  final _page = StreamController<String>.broadcast(sync: true);
  final failuresIn = StreamController<Street3DSurfaceFailure>.broadcast(
    sync: true,
  );
  final sent = <Map<String, Object?>>[];
  var pauses = 0;
  var resumes = 0;
  var disposed = false;

  @override
  Stream<String> get messages => _page.stream;

  @override
  Stream<Street3DSurfaceFailure> get failures => failuresIn.stream;

  @override
  Future<void> send(String json) async {
    sent.add(jsonDecode(json) as Map<String, Object?>);
  }

  @override
  Future<void> pause() async {
    pauses += 1;
  }

  @override
  Future<void> resume() async {
    resumes += 1;
  }

  @override
  void dispose() {
    disposed = true;
  }

  List<String> get types => [for (final m in sent) m['type'] as String];

  List<Map<String, Object?>> payloads(String type) => [
    for (final m in sent)
      if (m['type'] == type) m['payload'] as Map<String, Object?>,
  ];

  void say(String type, Map<String, Object?> payload) => _page.add(
    jsonEncode({'v': 1, 'type': type, 'ts': 1764115200000, 'payload': payload}),
  );
}

class _View extends StatefulWidget {
  const _View(this.onCreated, this.make);

  final ValueChanged<Street3DSurface> onCreated;
  final _Surface Function() make;

  @override
  State<_View> createState() => _ViewState();
}

class _ViewState extends State<_View> {
  @override
  void initState() {
    super.initState();
    final surface = widget.make();
    // Like a platform view, the surface exists only after the first frame.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => widget.onCreated(surface),
    );
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

class _Harness {
  _Harness(this.source, {this.android = true});

  final _Source? source;
  final bool android;
  final surfaces = <_Surface>[];

  Widget app() => MaterialApp(
    home: Street3DScreen(
      source: source,
      surfaceBuilder: android
          ? (context, onCreated) => _View(onCreated, () {
              final surface = _Surface();
              surfaces.add(surface);
              return surface;
            })
          : null,
    ),
  );

  Future<_Surface> open(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.pump();
    return surfaces.last;
  }

  Future<_Surface> connect(WidgetTester tester) async {
    final page = await open(tester);
    page.say('hello', _hello);
    await tester.pump();
    return page;
  }
}

void main() {
  testWidgets(
    'a page that says hello gets hello-ack, the layout and positions',
    (tester) async {
      final source = _Source(
        _street(),
        records: [_record('alice'), _record('bob')],
      );
      final h = _Harness(source);
      final page = await h.open(tester);
      expect(page.sent, isEmpty);
      expect(find.byKey(const Key('street3d-loading')), findsOneWidget);

      page.say('hello', _hello);
      await tester.pump();
      expect(page.types, ['hello-ack', 'layout', 'presence']);
      final spaces = page.payloads('layout').single['spaces'] as List;
      expect((spaces.single as Map)['label'], '我的别墅');
      final residents = page.payloads('presence').single['residents'] as List;
      expect((residents[0] as Map)['role'], 'self');
      expect((residents[1] as Map)['role'] ?? 'other', 'other');

      page.say('ready', {'restored': false, 'spaces': 1, 'residents': 2});
      await tester.pump();
      expect(find.byKey(const Key('street3d-loading')), findsNothing);

      await tester.pump(const Duration(milliseconds: 500));
      final times = [for (final p in page.payloads('presence')) p['t'] as num];
      expect(times, hasLength(2));
      expect(times[1], greaterThan(times[0]));

      await tester.pumpWidget(const SizedBox());
      expect(page.disposed, isTrue);
    },
  );

  testWidgets('positions are read only while the app is in the foreground', (
    tester,
  ) async {
    final source = _Source(_street(), records: [_record('alice')]);
    final page = await _Harness(source).connect(tester);
    expect(source.presenceCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 2));
    expect(source.presenceCalls, 1);
    expect(page.types.last, 'pause');
    expect(page.pauses, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(page.resumes, 1);
    expect(page.types, containsAllInOrder(['pause', 'resume', 'presence']));
    expect(source.presenceCalls, 2);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('tapping a resident asks the page to follow it', (tester) async {
    final page = await _Harness(_Source(_street())).connect(tester);
    page.say('tap', {'kind': 'resident', 'id': 'bob', 'spaceId': 'alice'});
    page.say('tap', {'kind': 'villa', 'id': 'alice'});
    await tester.pump();
    expect(page.payloads('focus'), [
      {'kind': 'resident', 'id': 'bob'},
    ]);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a crashed WebView explains itself and retry opens a new page', (
    tester,
  ) async {
    final source = _Source(_street());
    final h = _Harness(source);
    final page = await h.connect(tester);
    page.failuresIn.add(
      const Street3DSurfaceFailure(Street3DSurfaceFailureKind.crashed),
    );
    await tester.pump();
    expect(find.text('3D 画面意外停止'), findsOneWidget);
    expect(page.disposed, isTrue);

    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('street3d-retry')));
    await tester.pump();
    await tester.pump();
    expect(h.surfaces, hasLength(2));
    final again = h.surfaces.last..say('hello', _hello);
    await tester.pump();
    expect(again.types.take(2), ['hello-ack', 'layout']);
    expect(source.loads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('fatal page errors say what happened; only some can be retried', (
    tester,
  ) async {
    final page = await _Harness(_Source(_street())).connect(tester);
    page.say('error', {'code': 'internal', 'message': 'boom', 'fatal': true});
    await tester.pump();
    expect(find.text('3D 街区出错了'), findsOneWidget);
    expect(find.byKey(const Key('street3d-retry')), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    // Without WebGL the page reports the error instead of saying hello.
    final noGl = await _Harness(_Source(_street())).open(tester);
    noGl.say('error', {
      'code': 'webgl_unavailable',
      'message': 'no context',
      'fatal': true,
    });
    await tester.pump();
    expect(find.text('这台设备不能显示 3D 画面'), findsOneWidget);
    expect(find.byKey(const Key('street3d-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a street that cannot be read can be retried', (tester) async {
    final source = _Source(_street())..loadError = _down;
    await _Harness(source).open(tester);
    expect(find.text('暂时连不上宿主'), findsOneWidget);

    source.loadError = null;
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('street3d-retry')));
    await tester.pump();
    await tester.pump();
    expect(source.loads, 2);
    expect(find.byKey(const Key('street3d-problem')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'an empty street explains how villas appear and reads no positions',
    (tester) async {
      final source = _Source(_street(empty: true));
      final page = await _Harness(source).connect(tester);
      expect(page.types, ['hello-ack', 'layout']);
      expect(source.presenceCalls, 0);
      expect(find.textContaining('街区里还没有别墅'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'positions that keep failing show a notice until they come back',
    (tester) async {
      final source = _Source(_street(), records: [_record('alice')])
        ..presenceError = _down;
      await _Harness(source).connect(tester);
      expect(find.byKey(const Key('street3d-banner')), findsNothing);

      await tester.pump(const Duration(milliseconds: 1500));
      expect(find.textContaining('暂时读不到居民的位置'), findsOneWidget);

      source.presenceError = null;
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.byKey(const Key('street3d-banner')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('without a 3D view or a host the page says so', (tester) async {
    await tester.pumpWidget(_Harness(_Source(_street()), android: false).app());
    expect(find.text('这个平台还不能显示 3D 街区'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());

    await tester.pumpWidget(_Harness(null).app());
    expect(find.text('没有连接宿主'), findsOneWidget);
    expect(find.byKey(const Key('street3d-retry')), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
