import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/scheduled_messages_api.dart';
import 'package:flutter_test/flutter_test.dart';

const _group = 'group-a';
const _base = '/api/v1/conversations/group-a/scheduled-messages';
const _instant = '2090-06-15T09:32:00.000Z';

Map<String, Object?> row({
  String id = 'job-a',
  String group = _group,
  String at = _instant,
  String status = 'pending',
}) => {'id': id, 'conversationId': group, 'deliverAt': at, 'status': status};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late ScheduledMessagesApi api;
  late Object? response;
  late int status;
  late int authRenewals;
  final requests = <(String, String, String)>[];
  final at = DateTime.parse(_instant);

  setUp(() async {
    response = null;
    status = 200;
    authRenewals = 0;
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((request.method, request.uri.toString(), raw));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'synthetic',
      onUnauthorized: () async {
        authRenewals++;
        return true;
      },
    );
    api = ScheduledMessagesApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'legacy POST sends only plain text and verifies the pending 200 receipt',
    () async {
      response = row();
      final result = await api.create(_group, text: '相同文字\n第二行', at: at);
      expect(result, isA<ScheduleCreated>());
      final item = (result as ScheduleCreated).item;
      expect(
        (item.id, item.conversationId, item.at, item.status),
        ('job-a', _group, at, ScheduleStatus.pending),
      );
      expect(requests.single.$1, 'POST');
      expect(requests.single.$2, _base);
      expect(jsonDecode(requests.single.$3), {
        'kind': 'text',
        'body': {'text': '相同文字\n第二行'},
        'deliverAt': _instant,
      });
    },
  );

  test(
    'POST with mismatched or malformed success can never confirm a job',
    () async {
      for (final receipt in [
        row(group: 'group-b'),
        row(id: '../outside'),
        row(status: 'delivered'),
        row(at: '2090-06-15T09:33:00.000Z'),
        row(at: '2090-06-15T09:32:00+00:00'),
        {...row(), 'body': 'not expected'},
      ]) {
        response = receipt;
        expect(
          (await api.create(
            _group,
            text: 'synthetic',
            at: at,
          ) as ScheduleFailure).problem,
          ScheduleProblem.unknown,
        );
      }
      status = 200;
      for (final code in [201, 202, 204]) {
        status = code;
        response = row();
        expect(
          (await api.create(
            _group,
            text: 'synthetic',
            at: at,
          ) as ScheduleFailure).problem,
          ScheduleProblem.unknown,
          reason: 'HTTP $code',
        );
      }
      expect(requests, hasLength(9));
    },
  );

  test(
    'empty, oversized, invalid target and past requests never reach the host',
    () async {
      final results = [
        await api.create(_group, text: ' \t\n', at: at),
        await api.create(_group, text: '界' * 30000, at: at),
        await api.create('../outside', text: 'synthetic', at: at),
        await api.create(_group, text: 'synthetic', at: DateTime.utc(2000)),
        await api.read(_group, knownId: '../outside'),
      ];
      for (final result in results) {
        expect((result as ScheduleFailure).problem, ScheduleProblem.refused);
      }
      expect(requests, isEmpty);
    },
  );

  test(
    'reads strict sender metadata for one conversation and optional known ID',
    () async {
      response = {
        'scheduledMessages': [
          row(id: 'job-d', status: 'delivered'),
          row(id: 'job-c', status: 'cancelled'),
          row(id: 'job-b', status: 'expired'),
          row(),
        ],
        'hasMore': false,
      };
      final list = await api.read(_group) as ScheduleLoaded;
      expect(list.items.map((item) => item.status), [
        ScheduleStatus.delivered,
        ScheduleStatus.cancelled,
        ScheduleStatus.expired,
        ScheduleStatus.pending,
      ]);
      response = {
        'scheduledMessages': [row()],
        'hasMore': false,
      };
      final item = await api.read(_group, knownId: 'job-a') as ScheduleLoaded;
      expect(item.items.single.id, 'job-a');
      expect(requests, [
        ('GET', _base, ''),
        ('GET', '$_base?scheduledId=job-a', ''),
      ]);
      status = 404;
      response = {'error': 'not_found'};
      expect(
        (await api.read(_group, knownId: 'job-a') as ScheduleFailure).problem,
        ScheduleProblem.refused,
      );
    },
  );

  test('malformed or unbounded status data is rejected rather than partially displayed', () async {
    for (final rows in [
      [row(group: 'group-b')],
      [row(status: 'sent')],
      [row(at: '2090-02-30T09:32:00.000Z')],
      [row(), row()],
      [
        {...row(), 'senderId': 'other'},
      ],
      [for (var n = 0; n < 51; n++) row(id: 'id-$n')],
    ]) {
      response = {'scheduledMessages': rows, 'hasMore': false};
      expect(
        (await api.read(_group) as ScheduleFailure).problem,
        ScheduleProblem.unavailable,
      );
    }
    response = {
      'scheduledMessages': [row(id: 'job-b')],
      'hasMore': false,
    };
    expect(
      await api.read(_group, knownId: 'job-a'),
      const ScheduleFailure(ScheduleProblem.unavailable),
    );
    response = {
      'scheduledMessages': [],
      'hasMore': false,
      'unexpected': 'a' * 20000,
    };
    expect(
      await api.read(_group),
      const ScheduleFailure(ScheduleProblem.unavailable),
    );
  });

  test(
    'legacy DELETE is bodyless, strict, and never retries an unknown outcome',
    () async {
      response = {
        'scheduledMessages': [row(), row(id: 'job-d', status: 'delivered')],
        'hasMore': false,
      };
      final list = await api.read(_group) as ScheduleLoaded;
      final (pending, delivered) = (list.items.first, list.items.last);
      expect(
        await api.cancel(_group, item: delivered),
        const ScheduleFailure(ScheduleProblem.refused),
      );
      expect(
        await api.cancel('group-b', item: pending),
        const ScheduleFailure(ScheduleProblem.refused),
      );
      expect(requests, hasLength(1));
      for (final (code, body, result) in <(int, Object, ScheduleResult)>[
        (200, {'cancelled': true}, const ScheduleCancelled()),
        (
          200,
          {'cancelled': false},
          const ScheduleFailure(ScheduleProblem.unknown),
        ),
        (
          200,
          {'cancelled': true, 'message': 'other'},
          const ScheduleFailure(ScheduleProblem.unknown),
        ),
        (
          401,
          {'error': 'unauthenticated'},
          const ScheduleFailure(ScheduleProblem.refused),
        ),
        (
          403,
          {'error': 'forbidden'},
          const ScheduleFailure(ScheduleProblem.refused),
        ),
        (
          500,
          {'error': 'internal'},
          const ScheduleFailure(ScheduleProblem.unknown),
        ),
      ]) {
        status = code;
        response = body;
        expect(await api.cancel(_group, item: pending), result);
      }
      expect(requests.skip(1), List.filled(6, ('DELETE', '$_base/job-a', '')));
      expect(authRenewals, 0);
    },
  );

  test('ambiguous create does not repeat or infer identity', () async {
    status = 500;
    response = {'error': 'unavailable'};
    expect(
      await api.create(_group, text: 'synthetic', at: at),
      const ScheduleFailure(ScheduleProblem.unknown),
    );
    status = 401;
    expect(
      await api.create(_group, text: 'synthetic', at: at),
      const ScheduleFailure(ScheduleProblem.refused),
    );
    expect(requests.map((entry) => entry.$1), ['POST', 'POST']);
    expect(authRenewals, 0);
  });
}
