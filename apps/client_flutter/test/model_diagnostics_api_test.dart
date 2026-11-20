import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/model_diagnostics_api.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _catalog() => {
  'models': [
    {'id': 'model-a'},
    {'id': 'model-b'},
  ],
};

Map<String, Object?> _usage() => {
  'budgetDay': '2026-11-20',
  'offsetMinutes': 480,
  'recordedTokens': '15',
  'byLayer': {
    'b0Life': '0',
    'b1FastBrain': '0',
    'b2DeepChat': '15',
    'b3Proactive': '0',
    'b4Maintenance': '0',
  },
  'byCapability': {
    'chat': '10',
    'chatFast': '0',
    'vision': '5',
    'imageGen': '0',
    'tts': '0',
    'asr': '0',
    'embedding': '0',
  },
  'sourceUsageUnknown': {
    'chat': false,
    'chatFast': true,
    'vision': false,
    'imageGen': false,
    'tts': false,
    'asr': false,
    'embedding': false,
  },
};

const _trendDays = [
  '2026-11-14',
  '2026-11-15',
  '2026-11-16',
  '2026-11-17',
  '2026-11-18',
  '2026-11-19',
  '2026-11-20',
];

Map<String, Object?> _trend() => {
  'window': 'rolling7',
  'basis': 'recordedBudgetDay',
  'offsetMinutes': 480,
  'startDay': '2026-11-14',
  'endDay': '2026-11-20',
  'days': [
    for (final (index, day) in _trendDays.indexed)
      {
        'day': day,
        'recordedTokens': '${index * 5}',
        'byLayer': {
          'b0Life': '0',
          'b1FastBrain': '0',
          'b2DeepChat': '${index * 5}',
          'b3Proactive': '0',
          'b4Maintenance': '0',
        },
        'sourceUsageUnknown': false,
      },
  ],
  // Host marks all historical pending rows, including days outside this window.
  'sourceUsageUnknown': true,
};

Map<String, Object?> _budget() => {
  'dailyTokens': 100,
  'layerLimits': {
    'b0Life': 10,
    'b1FastBrain': 10,
    'b2DeepChat': 40,
    'b3Proactive': 20,
    'b4Maintenance': 20,
  },
  'capabilityLimits': {
    'chat': 60,
    'chatFast': 10,
    'vision': 10,
    'imageGen': 5,
    'tts': 5,
    'asr': 5,
    'embedding': 5,
  },
  'offsetMinutes': 480,
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late ModelDiagnosticsApi api;
  late List<(String, String, String?, String)> requests;
  late Object? payload;
  late int status;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = ModelDiagnosticsApi(connection);
    requests = [];
    payload = _catalog();
    status = 200;
    server.listen((request) async {
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        await utf8.decoder.bind(request).join(),
      ));
      request.response.statusCode = status;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  void expectGetOnly(String target) {
    expect(requests, [('GET', target, 'Bearer fixture-token', '')]);
  }

  group('model catalog', () {
    test('reads the saved provider catalog with one GET and no query', () async {
      final read = await api.readModelCatalog('provider');
      expect(read.status, DiagnosticsReadStatus.loaded);
      expect(read.value!.models, ['model-a', 'model-b']);
      expect(() => read.value!.models.clear(), throwsUnsupportedError);
      expectGetOnly('/api/v1/model-providers/provider/models');
    });

    test('empty catalog is loaded-but-empty, never invented models', () async {
      payload = {'models': <Object?>[]};
      final read = await api.readModelCatalog('provider');
      expect(read.status, DiagnosticsReadStatus.loaded);
      expect(read.value!.models, isEmpty);
    });

    test('rejects foreign or malformed catalog shapes', () async {
      for (final value in <Object?>[
        {'models': [{'id': 'model-a'}], 'extra': 1},
        {'models': [{'id': 'model-a', 'owned_by': 'vendor'}]},
        {'models': [{'id': 7}]},
        {'models': [{'id': ''}]},
        {'models': [{'id': ' model-a '}]},
        {'models': [{'id': 'model\u0000a'}]},
        {'models': [{'id': 'model-a'}, {'id': 'model-a'}]},
        {'models': [{'name': 'model-a'}]},
        {'models': 'model-a'},
        {'models': [null]},
        {'data': [{'id': 'model-a'}]},
        <Object?>[],
      ]) {
        payload = value;
        final read = await api.readModelCatalog('provider');
        expect(read.status, DiagnosticsReadStatus.unknown, reason: '$value');
        expect(read.value, isNull);
      }
    });

    test('rejects an over-long or oversized catalog instead of truncating', () async {
      payload = {
        'models': [
          {'id': 'x' * 257},
        ],
      };
      expect(
        (await api.readModelCatalog('provider')).status,
        DiagnosticsReadStatus.unknown,
      );
      payload = {
        'models': [
          for (var i = 0; i <= 1000; i++) {'id': 'model-$i'},
        ],
      };
      expect(
        (await api.readModelCatalog('provider')).status,
        DiagnosticsReadStatus.unknown,
      );
    });

    test('invalid provider id is rejected before any HTTP', () async {
      await expectLater(
        api.readModelCatalog('private/secret'),
        throwsA(
          predicate(
            (e) =>
                e is FormatException &&
                e.source == null &&
                !e.toString().contains('secret'),
          ),
        ),
      );
      expect(requests, isEmpty);
    });
  });

  group('today recorded usage', () {
    test('keeps decimal strings as exact BigInt and pending as unknown', () async {
      payload = _usage();
      final read = await api.readTodayUsage('profile');
      expect(read.status, DiagnosticsReadStatus.loaded);
      final usage = read.value!;
      expect(usage.budgetDay, '2026-11-20');
      expect(usage.offsetMinutes, 480);
      expect(usage.recordedTokens, BigInt.from(15));
      expect(usage.byLayer['b2DeepChat'], BigInt.from(15));
      expect(usage.byCapability['chat'], BigInt.from(10));
      // Pending usage is reported as unknown, not as zero recorded tokens.
      expect(usage.sourceUsageUnknown['chatFast'], isTrue);
      expect(usage.sourceUsageUnknown['chat'], isFalse);
      expect(usage.unknownCapabilities, {'chatFast'});
      expect(usage.hasUnknown, isTrue);
      expect(() => usage.byLayer['b0Life'] = BigInt.one, throwsUnsupportedError);
      expect(read.toString(), isNot(contains('15')));
      expectGetOnly('/api/v1/ai-profiles/profile/usage');
    });

    test('large counters stay exact beyond 64-bit range', () async {
      payload = {
        ..._usage(),
        'recordedTokens': '99999999999999999999999999',
        'byLayer': {
          'b0Life': '0',
          'b1FastBrain': '0',
          'b2DeepChat': '99999999999999999999999999',
          'b3Proactive': '0',
          'b4Maintenance': '0',
        },
        'byCapability': {
          'chat': '99999999999999999999999999',
          'chatFast': '0',
          'vision': '0',
          'imageGen': '0',
          'tts': '0',
          'asr': '0',
          'embedding': '0',
        },
      };
      final usage = (await api.readTodayUsage('profile')).value!;
      expect(
        usage.recordedTokens,
        BigInt.parse('99999999999999999999999999'),
      );
    });

    test('configurationRequired is unconfigured, not zero usage', () async {
      payload = {'configurationRequired': true};
      final read = await api.readTodayUsage('profile');
      expect(read.status, DiagnosticsReadStatus.unconfigured);
      expect(read.value, isNull);
    });

    test('rejects invented, malformed and inconsistent counters', () async {
      for (final value in <Object?>[
        {'configurationRequired': true, 'extra': 1},
        {..._usage(), 'extra': 1},
        {..._usage()}..remove('budgetDay'),
        {..._usage(), 'budgetDay': '2026-11-20T00:00:00Z'},
        {..._usage(), 'budgetDay': 20261120},
        {..._usage(), 'offsetMinutes': 841},
        {..._usage(), 'offsetMinutes': '480'},
        {..._usage(), 'recordedTokens': 15},
        {..._usage(), 'recordedTokens': '-15'},
        {..._usage(), 'recordedTokens': '015'},
        {..._usage(), 'recordedTokens': '1.5'},
        {..._usage(), 'recordedTokens': ' 15'},
        {..._usage(), 'recordedTokens': '16'},
        {
          ..._usage(),
          'byLayer': {
            'b0Life': '0',
            'b1FastBrain': '0',
            'b2DeepChat': '10',
            'b3Proactive': '0',
          },
        },
        {
          ..._usage(),
          'byLayer': {
            'b0Life': '0',
            'b1FastBrain': '0',
            'b2DeepChat': '15',
            'b3Proactive': '0',
            'b4Maintenance': '0',
            'b5Invented': '0',
          },
        },
        {
          ..._usage(),
          'byCapability': {
            'chat': '10',
            'chatFast': '0',
            'vision': '5',
            'imageGen': '0',
            'tts': '0',
            'asr': '0',
          },
        },
        {
          ..._usage(),
          'sourceUsageUnknown': {
            'chat': false,
            'chatFast': false,
            'vision': false,
            'imageGen': false,
            'tts': false,
            'asr': false,
          },
        },
        {
          ..._usage(),
          'sourceUsageUnknown': {
            'chat': 'false',
            'chatFast': false,
            'vision': false,
            'imageGen': false,
            'tts': false,
            'asr': false,
            'embedding': false,
          },
        },
      ]) {
        payload = value;
        final read = await api.readTodayUsage('profile');
        expect(read.status, DiagnosticsReadStatus.unknown, reason: '$value');
        expect(read.value, isNull);
      }
    });

    test('invalid AI profile id is rejected before any HTTP', () async {
      await expectLater(
        api.readTodayUsage('bad id'),
        throwsA(isA<FormatException>()),
      );
      expect(requests, isEmpty);
    });
  });

  group('rolling seven recorded days', () {
    test('reads window/basis/days with exact counters and per-day unknown', () async {
      payload = _trend();
      final read = await api.readRolling7Trend('profile');
      expect(read.status, DiagnosticsReadStatus.loaded);
      final trend = read.value!;
      expect(trend.window, 'rolling7');
      expect(trend.basis, 'recordedBudgetDay');
      expect(trend.startDay, '2026-11-14');
      expect(trend.endDay, '2026-11-20');
      expect(trend.days.map((day) => day.day), _trendDays);
      expect(trend.days[2].recordedTokens, BigInt.from(10));
      expect(trend.days[2].byLayer['b2DeepChat'], BigInt.from(10));
      expect(trend.days.every((day) => !day.sourceUsageUnknown), isTrue);
      // Historical pending rows outside the window still set the global flag.
      expect(trend.hasUnknown, isTrue);
      expect(() => trend.days.clear(), throwsUnsupportedError);
      expectGetOnly('/api/v1/ai-profiles/profile/usage/trend');
    });

    test('configurationRequired is unconfigured, not an empty trend', () async {
      payload = {'configurationRequired': true};
      final read = await api.readRolling7Trend('profile');
      expect(read.status, DiagnosticsReadStatus.unconfigured);
      expect(read.value, isNull);
    });

    test('rejects a wrong window, gap, overlap or non-ascending days', () async {
      final base = _trend();
      final days = (base['days']! as List).cast<Map<String, Object?>>();
      for (final value in <Object?>[
        {...base, 'extra': 1},
        {...base, 'window': 'calendarWeek'},
        {...base, 'basis': 'utcDay'},
        {...base, 'startDay': '2026-11-13'},
        {...base, 'endDay': '2026-11-21'},
        {...base, 'offsetMinutes': 900},
        {
          ...base,
          'days': days.take(6).toList(),
        },
        {
          ...base,
          'days': [...days, days.last],
        },
        {
          ...base,
          'days': [
            days[1],
            days[0],
            ...days.skip(2),
          ],
        },
        {
          ...base,
          'days': [
            days[0],
            {...days[1], 'day': '2026-11-16'},
            ...days.skip(2),
          ],
        },
        {
          ...base,
          'days': [
            days[0],
            days[1],
            days[2],
            days[3],
            days[4],
            days[5],
            {...days[6], 'extra': 1},
          ],
        },
        {
          ...base,
          'days': [
            days[0],
            days[1],
            days[2],
            days[3],
            days[4],
            days[5],
            {...days[6], 'recordedTokens': '25'},
          ],
        },
        {
          ...base,
          'days': [
            days[0],
            days[1],
            days[2],
            days[3],
            days[4],
            days[5],
            {
              ...days[6],
              'byLayer': {
                'b0Life': '0',
                'b1FastBrain': '0',
                'b2DeepChat': '35',
                'b3Proactive': '0',
                'b4Maintenance': '0',
              },
            },
          ],
        },
        {...base, 'sourceUsageUnknown': 'true'},
        {
          ...base,
          'days': [
            days[0],
            days[1],
            days[2],
            days[3],
            days[4],
            days[5],
            {...days[6], 'sourceUsageUnknown': 0},
          ],
        },
      ]) {
        payload = value;
        final read = await api.readRolling7Trend('profile');
        expect(read.status, DiagnosticsReadStatus.unknown, reason: '$value');
        expect(read.value, isNull);
      }
    });
  });

  group('budget limits', () {
    test('reads the configured limits without usage or admission claims', () async {
      payload = _budget();
      final read = await api.readBudget('profile');
      expect(read.status, DiagnosticsReadStatus.loaded);
      final budget = read.value!;
      expect(budget.dailyTokens, 100);
      expect(budget.offsetMinutes, 480);
      expect(budget.layerLimits['b2DeepChat'], 40);
      expect(budget.capabilityLimits['chat'], 60);
      expect(() => budget.layerLimits.clear(), throwsUnsupportedError);
      expectGetOnly('/api/v1/ai-profiles/profile/budget');
    });

    test('configurationRequired is unconfigured, not a zero budget', () async {
      payload = {'configurationRequired': true};
      final read = await api.readBudget('profile');
      expect(read.status, DiagnosticsReadStatus.unconfigured);
      expect(read.value, isNull);
    });

    test('rejects partial, negative, non-integer and over-summed limits', () async {
      for (final value in <Object?>[
        {'configurationRequired': true, 'extra': 1},
        {..._budget(), 'extra': 1},
        {..._budget()}..remove('offsetMinutes'),
        {..._budget(), 'dailyTokens': -1},
        {..._budget(), 'dailyTokens': 1.0},
        {
          ..._budget(),
          'layerLimits': {'b0Life': 0},
        },
        {
          ..._budget(),
          'capabilityLimits': {
            ...(_budget()['capabilityLimits']! as Map),
            'chat': 101,
          },
        },
        {..._budget(), 'offsetMinutes': -841},
      ]) {
        payload = value;
        final read = await api.readBudget('profile');
        expect(read.status, DiagnosticsReadStatus.unknown, reason: '$value');
        expect(read.value, isNull);
      }
    });
  });

  group('honest failure states', () {
    for (final (code, expected) in [
      (404, DiagnosticsReadStatus.notFound),
      (401, DiagnosticsReadStatus.denied),
      (403, DiagnosticsReadStatus.denied),
      (503, DiagnosticsReadStatus.unavailable),
      (429, DiagnosticsReadStatus.unavailable),
      // HostConnection classifies an unlabelled 5xx as `unavailable`; this
      // adapter keeps that and never upgrades it to a configuration claim.
      (500, DiagnosticsReadStatus.unavailable),
    ]) {
      test('HTTP$code maps to ${expected.name} for every read', () async {
        status = code;
        payload = {'error': 'private-secret-detail'};
        final catalog = await api.readModelCatalog('provider');
        payload = {'error': 'private-secret-detail'};
        final usage = await api.readTodayUsage('profile');
        payload = {'error': 'private-secret-detail'};
        final trend = await api.readRolling7Trend('profile');
        payload = {'error': 'private-secret-detail'};
        final budget = await api.readBudget('profile');
        for (final read in [catalog, usage, trend, budget]) {
          expect(read.status, expected);
          expect(read.value, isNull);
          expect(read.toString(), isNot(contains('private-secret')));
        }
      });
    }

    test('closed port and malformed success are unavailable/unknown', () async {
      final dead = HostConnection(
        Uri.parse('http://127.0.0.1:1'),
        'fixture-token',
      );
      final deadApi = ModelDiagnosticsApi(dead);
      expect(
        (await deadApi.readTodayUsage('profile')).status,
        DiagnosticsReadStatus.unavailable,
      );
      expect(
        (await deadApi.readRolling7Trend('profile')).status,
        DiagnosticsReadStatus.unavailable,
      );
      expect(
        (await deadApi.readModelCatalog('provider')).status,
        DiagnosticsReadStatus.unavailable,
      );
      expect(
        (await deadApi.readBudget('profile')).status,
        DiagnosticsReadStatus.unavailable,
      );
      await dead.close();

      payload = {'models': 'not-a-list'};
      expect(
        (await api.readModelCatalog('provider')).status,
        DiagnosticsReadStatus.unknown,
      );
    });
  });
}
