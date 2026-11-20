import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/creative_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

const _secret = 'CREATIVE-SECRET-SENTINEL';

Map<String, Object?> _report({String kind = 'weekly'}) => {
  'kind': kind,
  'periodKey': kind == 'weekly' ? '2026-11-15' : '2026',
  'windowStartDay': '2026-11-09',
  'windowEndDay': '2026-11-15',
  'generatedAt': '2026-11-15T13:31:00.000Z',
  'commonTopics': [
    {'label': '旅行', 'count': 3},
    {'label': '电影', 'count': 1},
  ],
  'completedAgreements': 2,
  'checkinDays': 4,
  'moodCurve': {'2026-11-11': 4.0, '2026-11-12': 3.5},
  'letter': '这一周我们聊了很多。',
  'keywords': kind == 'annual' ? ['旅行', '电影'] : <Object?>[],
  'milestones': kind == 'annual' ? ['2026-08-15 一起看海'] : <Object?>[],
  'busiestDay': kind == 'annual' ? '2026-08-15' : null,
  'sourceScopes': ['privateChat', 'moments'],
};

Map<String, Object?> _summary({
  String status = 'generated',
  bool withReport = true,
}) => {
  'aiId': 'ai-profile',
  'kind': 'weekly',
  'periodKey': '2026-11-15',
  'status': status,
  if (withReport) 'report': _report(),
};

Map<String, Object?> _episode() => {
  'aiId': 'ai-profile',
  'dateKey': '2026-11-16',
  'scheduledFor': '2026-11-16T15:00:00.000Z',
  'generatedAt': '2026-11-16T14:50:00.000Z',
  'voiceId': 'voice-1',
  'offlineCacheKey': 'cache/2026-11-16',
  'playableOffline': true,
  'script': {
    'text': '晚安。\n慢慢呼吸。',
    'segments': [
      {'kind': 'diary', 'text': '晚安。'},
      {'kind': 'comfort', 'text': '慢慢呼吸。'},
    ],
  },
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late CreativeApi api;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = CreativeApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Future<List<(String, String, String?, String)>> serveOnce(
    Object? response,
  ) async {
    final requests = <(String, String, String?, String)>[];
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        text,
      ));
      request.response.write(
        response is String ? response : jsonEncode(response),
      );
      await request.response.close();
    });
    return requests;
  }

  test(
    'listReports uses exact GET path, bearer, empty body and parses summaries',
    () async {
      final requests = await serveOnce({
        'reports': [_summary()],
      });
      final reports = await api.listReports();
      expect(requests.single.$1, 'GET');
      expect(requests.single.$2, '/api/v1/creative/reports');
      expect(requests.single.$3, 'Bearer fixture-token');
      expect(requests.single.$4, isEmpty);
      expect(reports, hasLength(1));
      final summary = reports.single;
      expect(summary.aiId, 'ai-profile');
      expect(summary.kind, 'weekly');
      expect(summary.periodKey, '2026-11-15');
      expect(summary.status, 'generated');
      expect(summary.report, isNotNull);
      expect(summary.report!.commonTopics.first.label, '旅行');
      expect(summary.report!.moodCurve['2026-11-12'], 3.5);
    },
  );

  test(
    'list preserves missing bodies without relabeling their status',
    () async {
      await serveOnce({
        'reports': [
          _summary(status: 'missed', withReport: false),
          _summary(withReport: false),
        ],
      });
      final reports = await api.listReports();
      expect(reports.map((row) => row.status), ['missed', 'generated']);
      expect(reports.map((row) => row.report), [null, null]);
    },
  );

  for (final mismatch in ['kind', 'periodKey']) {
    test('list rejects a payload that changes the row $mismatch', () async {
      await serveOnce({
        'reports': [
          {
            ..._summary(),
            'report': {
              ..._report(),
              mismatch: mismatch == 'kind' ? 'annual' : '2026-11-08',
            },
          },
        ],
      });
      await expectLater(api.listReports(), throwsFormatException);
    });
  }

  test(
    'getReport uses exact encoded path and parses full annual report',
    () async {
      final requests = await serveOnce(_report(kind: 'annual'));
      final report = await api.getReport(
        aiId: 'ai-profile',
        kind: 'annual',
        periodKey: '2026',
      );
      expect(requests.single.$1, 'GET');
      expect(
        requests.single.$2,
        '/api/v1/creative/reports/ai-profile/annual/2026',
      );
      expect(requests.single.$3, 'Bearer fixture-token');
      expect(requests.single.$4, isEmpty);
      expect(report.kind, 'annual');
      expect(report.keywords, ['旅行', '电影']);
      expect(report.milestones, ['2026-08-15 一起看海']);
      expect(report.busiestDay, '2026-08-15');
      expect(report.sourceScopes, ['privateChat', 'moments']);
      expect(report.generatedAt.isUtc, isTrue);
    },
  );

  test(
    'listRadio and getRadio use exact paths and parse script segments',
    () async {
      final requests = <(String, String)>[];
      server.listen((request) async {
        await request.drain<void>();
        requests.add((request.method, request.uri.toString()));
        final body = request.uri.path == '/api/v1/creative/radio'
            ? {
                'episodes': [_episode()],
              }
            : _episode();
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final list = await api.listRadio();
      expect(list.single.voiceId, 'voice-1');
      expect(list.single.playableOffline, isTrue);
      expect(list.single.script.segments, hasLength(2));
      final episode = await api.getRadio(
        aiId: 'ai-profile',
        dateKey: '2026-11-16',
      );
      expect(episode.script.text, '晚安。\n慢慢呼吸。');
      expect(episode.offlineCacheKey, 'cache/2026-11-16');
      expect(requests.map((r) => (r.$1, r.$2)), [
        ('GET', '/api/v1/creative/radio'),
        ('GET', '/api/v1/creative/radio/ai-profile/2026-11-16'),
      ]);
    },
  );

  test('strict DTOs reject malformed creative payloads with safe errors (no secret)', () async {
    final malformed = <Object?>[
      [], // list root not a map
      {'reports': 'nope'},
      {
        'reports': [
          {..._summary()}..remove('aiId'),
        ],
      },
      {
        'reports': [
          {..._summary(), 'extra': _secret},
        ],
      },
      {
        'reports': [
          {..._summary(), 'aiId': 'bad/id'},
        ],
      },
      {
        'reports': [
          {..._summary(), 'kind': 'yearly'},
        ],
      },
      {
        'reports': [
          {..._summary(), 'status': 'unknown'},
        ],
      },
      {
        'reports': [
          {..._summary(status: 'missed'), 'report': _report()},
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {..._report()}..remove('letter'),
          },
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {
              ..._report(),
              'commonTopics': [
                {'label': 'x', 'count': -1},
              ],
            },
          },
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {
              ..._report(),
              'moodCurve': {'d': 'high'},
            },
          },
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {..._report(), 'generatedAt': 'not-a-date'},
          },
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {..._report(), 'generatedAt': '2026-11-15T13:31:00'},
          },
        ],
      },
      {
        'reports': [
          {
            ..._summary(),
            'report': {
              ..._report(),
              'sourceScopes': ['all'],
            },
          },
        ],
      },
    ];
    var index = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(malformed[index++]));
      await request.response.close();
    });
    for (var i = 0; i < malformed.length; i++) {
      await expectLater(
        api.listReports(),
        throwsA(
          predicate(
            (error) =>
                error is FormatException &&
                error.source == null &&
                !error.toString().contains(_secret),
          ),
        ),
        reason: 'payload $i',
      );
    }
    expect(index, malformed.length);
  });

  test(
    'invalid identifiers/kinds never issue HTTP and never echo input',
    () async {
      var count = 0;
      server.listen((request) async {
        count++;
        await request.drain<void>();
        request.response.statusCode = 500;
        await request.response.close();
      });
      for (final aiId in ['', 'bad/id', 'x' * 65]) {
        await expectLater(
          api.getReport(aiId: aiId, kind: 'weekly', periodKey: '2026-11-15'),
          throwsA(
            predicate(
              (error) =>
                  error is FormatException &&
                  error.source == null &&
                  !error.toString().contains('bad/id'),
            ),
          ),
        );
        await expectLater(
          api.getRadio(aiId: aiId, dateKey: '2026-11-16'),
          throwsFormatException,
        );
      }
      await expectLater(
        api.getReport(
          aiId: 'ai-profile',
          kind: 'yearly',
          periodKey: '2026-11-15',
        ),
        throwsFormatException,
      );
      await expectLater(
        api.getReport(aiId: 'ai-profile', kind: 'weekly', periodKey: ''),
        throwsFormatException,
      );
      await expectLater(
        api.getRadio(aiId: 'ai-profile', dateKey: ''),
        throwsFormatException,
      );
      expect(count, 0);
    },
  );

  test(
    'unauthorized read surfaces safe unauthenticated failure without secret',
    () async {
      var count = 0;
      server.listen((request) async {
        count++;
        await request.drain<void>();
        request.response.statusCode = 401;
        request.response.write(
          jsonEncode({'error': 'unauthenticated', 'leak': _secret}),
        );
        await request.response.close();
      });
      await expectLater(
        api.listReports(),
        throwsA(
          predicate(
            (error) =>
                error is HostRequestException &&
                error.failure.code == FailureCode.unauthenticated &&
                !error.toString().contains(_secret),
          ),
        ),
      );
      expect(count, 1);
    },
  );

  test(
    'malformed success body is a safe FormatException with no secret',
    () async {
      await serveOnce('private-raw-body $_secret');
      await expectLater(
        api.listRadio(),
        throwsA(
          predicate(
            (error) =>
                error is FormatException &&
                error.source == null &&
                !error.toString().contains(_secret) &&
                !error.toString().contains('private-raw-body'),
          ),
        ),
      );
    },
  );
}
