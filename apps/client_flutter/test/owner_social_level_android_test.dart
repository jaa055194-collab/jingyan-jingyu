import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/features/ai_config/owner_social_level_section.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/owner_social_level_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:material_ui/material_ui.dart';

const _profile = 'reef-ai';
const _path = '/api/v1/ai-profiles/reef-ai/social-level';
const _at = '2026-11-21T09:41:32.123456Z';
const _empty = {
  'configurationRequired': true,
  'level': null,
  'updatedAt': null,
};
const _privateDetail = 'private response detail';

Map<String, Object?> _configured(String level) => {
  'configurationRequired': false,
  'level': level,
  'updatedAt': _at,
};

void main() {
  group('owner social-level HTTP contract', () {
    late HostConnection connection;
    late OwnerSocialLevelApi api;
    late String response;
    late int status;
    late int renewals;
    final calls = <(String, String, String, String?)>[];

    setUp(() async {
      response = jsonEncode(_empty);
      status = 200;
      renewals = 0;
      calls.clear();
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        calls.add((
          request.method,
          request.uri.toString(),
          await utf8.decoder.bind(request).join(),
          request.headers.value(HttpHeaders.authorizationHeader),
        ));
        request.response.statusCode = status;
        request.response.headers.set(HttpHeaders.locationHeader, '/redirect');
        request.response.headers.contentType = ContentType.json;
        request.response.write(response);
        await request.response.close();
      });
      connection = HttpOverrides.runWithHttpOverrides(
        () => HostConnection(
          Uri.parse('http://127.0.0.1:${server.port}'),
          'synthetic-owner-bearer',
          onUnauthorized: () async {
            renewals++;
            return true;
          },
        ),
        _LoopbackHttp(server.port),
      );
      addTearDown(connection.close);
      api = OwnerSocialLevelApi(connection);
    });

    test(
      'bodyless owner GET distinguishes unconfigured from an explicit L0',
      () async {
        final readAbsent = await api.read(_profile);
        expect(readAbsent, isA<OwnerSocialLevelSnapshot>());
        final absent = readAbsent as OwnerSocialLevelSnapshot;
        expect(
          (absent.configurationRequired, absent.level, absent.updatedAt),
          (true, null, null),
        );
        response = jsonEncode(_configured('L0'));
        final silent = await api.read(_profile) as OwnerSocialLevelSnapshot;
        expect(
          (silent.configurationRequired, silent.level, silent.updatedAt),
          (
            false,
            OwnerSocialLevel.l0,
            DateTime.utc(2026, 11, 21, 9, 41, 32, 123, 456),
          ),
        );
        expect(
          calls,
          List.filled(2, ('GET', _path, '', 'Bearer synthetic-owner-bearer')),
        );
      },
    );

    test('invalid profile identifiers never send a request', () async {
      expect(await api.read('../other'), isA<OwnerSocialLevelFailure>());
      expect(
        await api.write('reef-ai?owner=other', OwnerSocialLevel.l1),
        isA<OwnerSocialLevelFailure>(),
      );
      expect(calls, isEmpty);
    });

    test(
      'GET rejects malformed, noncanonical, oversized and non-200 views',
      () async {
        final valid = _configured('L2');
        for (final body in <Object?>[
          [],
          {'configurationRequired': true, 'level': null, 'extra': null},
          {..._empty, 'level': 'L0'},
          {..._empty, 'updatedAt': _at},
          {..._empty, 'configurationRequired': 'true'},
          {..._empty, 'configurationRequired': false},
          {...valid, 'level': 'l2'},
          {...valid, 'level': 'L5'},
          {...valid, 'level': 2},
          {...valid, 'updatedAt': '2026-02-30T09:41:32.000Z'},
          {...valid, 'updatedAt': '2026-11-21T09:41:32.123456+00:00'},
          {...valid, 'updatedAt': '2026-11-21T09:41:32.123456'},
          {...valid, 'updatedAt': 0},
          {...valid, 'private': _privateDetail},
        ]) {
          response = jsonEncode(body);
          final result = await api.read(_profile);
          expect(result, isA<OwnerSocialLevelFailure>(), reason: response);
          expect(
            (result as OwnerSocialLevelFailure).problem,
            OwnerSocialLevelProblem.unavailable,
          );
        }
        response = '${jsonEncode(valid)}${' ' * 8192}';
        expect(await api.read(_profile), isA<OwnerSocialLevelFailure>());
        response = jsonEncode(valid);
        status = 201;
        expect(await api.read(_profile), isA<OwnerSocialLevelFailure>());
      },
    );

    test(
      'PUT sends only the requested level and requires a matching 200 receipt',
      () async {
        for (final (level, wire) in const [
          (OwnerSocialLevel.l0, 'L0'),
          (OwnerSocialLevel.l1, 'L1'),
          (OwnerSocialLevel.l2, 'L2'),
          (OwnerSocialLevel.l3, 'L3'),
          (OwnerSocialLevel.l4, 'L4'),
        ]) {
          response = jsonEncode(_configured(wire));
          final written =
              await api.write(_profile, level) as OwnerSocialLevelSnapshot;
          expect(written.level, level);
          final (method, uri, body, authorization) = calls.last;
          expect(
            (method, uri, authorization),
            ('PUT', _path, 'Bearer synthetic-owner-bearer'),
          );
          expect(jsonDecode(body), {'level': wire});
        }
        for (final (code, view) in [
          (200, _empty),
          (200, _configured('L1')),
          (200, {..._configured('L2'), 'updatedAt': ''}),
          (202, _configured('L2')),
          (500, {'error': _privateDetail}),
        ]) {
          status = code;
          response = jsonEncode(view);
          final failure = await api.write(
            _profile,
            OwnerSocialLevel.l2,
          ) as OwnerSocialLevelFailure;
          expect(failure.problem, OwnerSocialLevelProblem.unknown);
        }
        expect(calls, hasLength(10));
      },
    );

    test(
      'neither method follows redirects or renews and replays a 401',
      () async {
        status = 307;
        expect(await api.read(_profile), isA<OwnerSocialLevelFailure>());
        expect(
          await api.write(_profile, OwnerSocialLevel.l2),
          isA<OwnerSocialLevelFailure>(),
        );
        status = 401;
        response = jsonEncode({
          'error': 'unauthenticated',
          'detail': _privateDetail,
        });
        final read = await api.read(_profile) as OwnerSocialLevelFailure;
        final write = await api.write(
          _profile,
          OwnerSocialLevel.l2,
        ) as OwnerSocialLevelFailure;
        expect(read.problem, OwnerSocialLevelProblem.authenticationRequired);
        expect(write.problem, OwnerSocialLevelProblem.authenticationRequired);
        expect(calls.map((call) => (call.$1, call.$2)), [
          ('GET', _path),
          ('PUT', _path),
          ('GET', _path),
          ('PUT', _path),
        ]);
        expect(renewals, 0);
      },
    );
  });

  testWidgets('Android requires explicit read, selection and one save', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 725));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final fixture = _SectionFixture();
    await fixture.pump(tester);
    expect(fixture.host.calls, isEmpty);
    expect(_key('select'), findsNothing);
    expect(find.textContaining('尚未读取'), findsOneWidget);
    expect(find.textContaining('撤销'), findsOneWidget);
    expect(find.textContaining('不会授予或恢复授权'), findsOneWidget);
    expect(find.textContaining('不会开启 L4'), findsOneWidget);

    final pending = Completer<Map<String, Object?>>();
    fixture.host.reply = () => pending.future;
    final read = tester.widget<TextButton>(_key('read')).onPressed!;
    read();
    read();
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<TextButton>(_key('read')).onPressed, isNull);
    expect(fixture.host.calls, [('GET', _path, null)]);
    pending.complete(_empty);
    await tester.pumpAndSettle();
    expect(find.textContaining('未配置'), findsOneWidget);
    expect(fixture.invalidations, 0);
    for (final label in ['L0 静默', 'L1 礼貌', 'L2 友好', 'L3 主动', 'L4 开放']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.widget<ChoiceChip>(_key('L0')).selected, isFalse);
    expect(tester.widget<FilledButton>(_key('save')).onPressed, isNull);

    await _tap(tester, 'L0');
    expect(fixture.host.calls, hasLength(1));
    expect(fixture.invalidations, 0);
    final receipt = Completer<Map<String, Object?>>();
    fixture.host.reply = () => receipt.future;
    final save = tester.widget<FilledButton>(_key('save')).onPressed!;
    save();
    save();
    await tester.pump();
    expect(fixture.host.calls.last.$1, 'PUT');
    expect(fixture.host.calls.last.$2, _path);
    expect(fixture.host.calls.last.$3, {'level': 'L0'});
    expect(fixture.host.calls, hasLength(2));
    expect(fixture.invalidations, 0);
    // The same owner scope must invalidate dependents even if it goes offline.
    fixture.online = false;
    receipt.complete(_configured('L0'));
    await tester.pumpAndSettle();
    expect(fixture.invalidations, 1);
    expect(find.textContaining('已保存：L0'), findsOneWidget);
    expect(find.textContaining('未配置'), findsNothing);
    expect(tester.widget<FilledButton>(_key('save')).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an unknown write invalidates once and requires an explicit re-read',
    (tester) async {
      final fixture = _SectionFixture();
      fixture.host.reply = () async => _configured('L3');
      await fixture.pump(tester);
      await _tap(tester, 'read');
      await _tap(tester, 'L1');
      fixture.host.reply = () async => {
        ..._configured('L1'),
        'extra': _privateDetail,
      };
      await _tap(tester, 'save');
      expect(fixture.host.calls.map((call) => call.$1), ['GET', 'PUT']);
      expect(fixture.invalidations, 1);
      expect(find.textContaining('保存结果未知'), findsOneWidget);
      expect(find.textContaining('未配置'), findsNothing);
      expect(find.textContaining(_privateDetail), findsNothing);
      expect(_key('select'), findsNothing);
      expect(_key('save'), findsNothing);
      fixture.host.reply = () async => _configured('L1');
      await _tap(tester, 'read');
      expect(find.textContaining('已保存：L1'), findsOneWidget);
      expect(fixture.invalidations, 1);
    },
  );

  testWidgets(
    'an explicit authentication refusal clears controls without notifying saved',
    (tester) async {
      final fixture = _SectionFixture();
      await fixture.pump(tester);
      await _tap(tester, 'read');
      await _tap(tester, 'L4');
      fixture.host.reply = () async => throw const HostRequestException(
        Failure(FailureCode.unauthenticated, _privateDetail),
      );
      await _tap(tester, 'save');
      expect(fixture.invalidations, 0);
      expect(fixture.host.calls.map((call) => call.$1), ['GET', 'PUT']);
      expect(find.textContaining('重新连接宿主'), findsOneWidget);
      expect(find.textContaining(_privateDetail), findsNothing);
      expect(find.textContaining('未配置'), findsNothing);
      expect(_key('save'), findsNothing);
    },
  );

  testWidgets(
    'live context guards block old actions and discard a late write after profile change',
    (tester) async {
      final fixture = _SectionFixture();
      await fixture.pump(tester);
      final staleRead = tester.widget<TextButton>(_key('read')).onPressed!;
      fixture.online = false;
      staleRead();
      fixture.online = true;
      fixture.current = false;
      staleRead();
      expect(fixture.host.calls, isEmpty);
      fixture.current = true;
      await _tap(tester, 'read');
      await _tap(tester, 'L4');
      final pending = Completer<Map<String, Object?>>();
      fixture.host.reply = () => pending.future;
      final staleSave = tester.widget<FilledButton>(_key('save')).onPressed!;
      staleSave();
      await tester.pump();
      expect(fixture.host.calls.last.$1, 'PUT');
      expect(fixture.host.calls.last.$2, _path);
      expect(fixture.host.calls.last.$3, {'level': 'L4'});
      fixture.profileId = 'other-ai';
      await fixture.pump(tester);
      staleRead();
      staleSave();
      pending.complete(_configured('L4'));
      await tester.pumpAndSettle();
      expect(fixture.host.calls, hasLength(2));
      expect(fixture.invalidations, 0);
      expect(find.textContaining('已保存：L4'), findsNothing);
      expect(_key('select'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a fresh read retires previously rendered read and save actions',
    (tester) async {
      final fixture = _SectionFixture();
      await fixture.pump(tester);
      await _tap(tester, 'read');
      final previousRead = tester.widget<TextButton>(_key('read')).onPressed!;
      await _tap(tester, 'L2');
      final previousSave = tester.widget<FilledButton>(_key('save')).onPressed!;

      // Reading the same explicitly unconfigured state does not revive old UI
      // actions, even when the user selects the same level again.
      await _tap(tester, 'read');
      await _tap(tester, 'L2');
      previousSave();
      await tester.pumpAndSettle();
      previousRead();
      await tester.pumpAndSettle();
      expect(fixture.host.calls.map((call) => call.$1), ['GET', 'GET']);
      expect(fixture.invalidations, 0);
      expect(tester.widget<FilledButton>(_key('save')).onPressed, isNotNull);
    },
  );

  testWidgets('a late read cannot apply after losing the current session', (
    tester,
  ) async {
    final fixture = _SectionFixture();
    final pending = Completer<Map<String, Object?>>();
    fixture.host.reply = () => pending.future;
    await fixture.pump(tester);
    await tester.tap(_key('read'));
    await tester.pump();
    fixture.current = false;
    pending.complete(_configured('L3'));
    await tester.pumpAndSettle();
    fixture.current = true;
    await fixture.pump(tester);
    expect(_key('select'), findsNothing);
    expect(find.textContaining('已保存：L3'), findsNothing);
    expect(fixture.invalidations, 0);
    expect(tester.widget<TextButton>(_key('read')).onPressed, isNotNull);
  });

  testWidgets('Windows does not expose the Android owner controls', (
    tester,
  ) async {
    final fixture = _SectionFixture();
    await fixture.pump(tester);
    expect(find.byKey(const Key('owner-social-level')), findsNothing);
    expect(fixture.host.calls, isEmpty);
  }, variant: const TargetPlatformVariant({TargetPlatform.windows}));
}

Finder _key(String suffix) => find.byKey(Key('owner-social-level-$suffix'));

Future<void> _tap(WidgetTester tester, String suffix) async {
  final target = _key(suffix);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

class _SectionFixture {
  _SectionFixture() {
    addTearDown(host.close);
  }

  final host = _OwnerBoundary();
  late final api = OwnerSocialLevelApi(host);
  bool current = true;
  bool online = true;
  int invalidations = 0;
  String profileId = _profile;

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            OwnerSocialLevelSection(
              api: api,
              profileId: profileId,
              isCurrent: () => current,
              canContactHost: () => online,
              onSaved: () => invalidations++,
            ),
          ],
        ),
      ),
    ),
  );
}

/// Bypass the widget test binding's synthetic HTTP 400 only for the fixture.
class _LoopbackHttp extends HttpOverrides {
  _LoopbackHttp(this.port);
  final int port;

  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context)
        ..findProxy = (uri) {
          if (uri.scheme != 'http' ||
              uri.host != '127.0.0.1' ||
              uri.port != port) {
            throw StateError('Only the test loopback server is allowed');
          }
          return 'DIRECT';
        };
}

/// Only the external transport is replaced for widgets. The real adapter
/// still checks the receipt and decides whether a write could have committed.
class _OwnerBoundary extends HostConnection {
  _OwnerBoundary() : super(Uri.parse('https://host.example.test'), 'synthetic');

  final calls = <(String, String, Map<String, Object?>?)>[];
  Future<Map<String, Object?>> Function() reply = () async => _empty;

  @override
  Future<Map<String, Object?>> requestBoundedObject(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? query,
    required int maxResponseBytes,
    required int expectedStatus,
    HostReadCancellation? cancellation,
  }) {
    calls.add((method, path, body));
    return reply();
  }
}
