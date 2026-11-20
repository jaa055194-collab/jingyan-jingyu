import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/device_sessions_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late DeviceSessionsApi api;
  late List<(String, String)> requests;
  Object? responseBody;
  late int status;
  String? rawBody;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = DeviceSessionsApi(connection);
    requests = [];
    responseBody = null;
    rawBody = null;
    status = 200;
    server.listen((request) async {
      await request.drain<void>();
      requests.add((request.method, request.uri.path));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      if (rawBody != null) {
        request.response.write(rawBody);
      } else if (responseBody != null) {
        request.response.write(jsonEncode(responseBody));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  Map<String, Object?> row(
    String id, {
    String name = '工作站',
    String used = '2026-11-18T02:03:04.000Z',
  }) => {'id': id, 'deviceName': name, 'lastUsedAt': used};

  test('reads GET /auth/devices with strict typed rows', () async {
    responseBody = [
      row('device-a', name: '工作站', used: '2026-11-18T02:03:04.000Z'),
      row('device-b', name: '手机', used: '2026-11-17T10:00:00Z'),
    ];
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.loaded);
    expect(read.devices.map((d) => d.id).toList(), ['device-a', 'device-b']);
    expect(read.devices.first.deviceName, '工作站');
    expect(read.devices.first.lastUsedAt, DateTime.utc(2026, 11, 18, 2, 3, 4));
    expect(read.devices.first.lastUsedAt.isUtc, isTrue);
    expect(read.devices.first.current, isFalse);
    expect(requests.single, ('GET', Routes.authDevices));
  });

  test('accepts real leap days and sub-second precision', () async {
    // The host serializes a real UTC instant, so valid leap days and up to six
    // fractional digits must load rather than be rejected as malformed.
    responseBody = [
      row('device-a', used: '2024-02-29T23:59:59.999999Z'),
      row('device-b', used: '2026-02-28T00:00:00.5Z'),
    ];
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.loaded);
    expect(
      read.devices.first.lastUsedAt,
      DateTime.utc(2024, 2, 29, 23, 59, 59, 999, 999),
    );
    expect(read.devices.last.lastUsedAt, DateTime.utc(2026, 2, 28, 0, 0, 0, 500));
  });

  test('marks only an explicit host current flag', () async {
    responseBody = [
      row('device-a'),
      {...row('device-b'), 'current': true},
    ];
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.loaded);
    expect(read.devices.map((d) => d.current).toList(), [false, true]);
  });

  test('empty list is a loaded read, not a failure', () async {
    responseBody = <Object?>[];
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.loaded);
    expect(read.devices, isEmpty);
  });

  test('rejects unknown, foreign and missing keys', () async {
    final payloads = <Object?>[
      // Envelope must be the host's plain array, never an object.
      {'devices': []},
      [
        {...row('device-a'), 'token': 'secret-access-token'},
      ],
      [
        {...row('device-a'), 'accessToken': 'secret-access-token'},
      ],
      [
        {'id': 'device-a', 'deviceName': '工作站'},
      ],
      [
        {'id': 'device-a', 'lastUsedAt': '2026-11-18T02:03:04.000Z'},
      ],
      [
        {'deviceName': '工作站', 'lastUsedAt': '2026-11-18T02:03:04.000Z'},
      ],
    ];
    for (final payload in payloads) {
      responseBody = payload;
      final read = await api.listDevices();
      expect(
        read.status,
        DeviceSessionsStatus.malformed,
        reason: '$payload',
      );
      expect(read.devices, isEmpty);
      expect(read.toString(), isNot(contains('secret-access-token')));
    }
  });

  test('rejects non-string, invalid and duplicate device ids', () async {
    final payloads = <Object?>[
      [
        {...row('device-a'), 'id': 42},
      ],
      [
        {...row('device-a'), 'id': null},
      ],
      [
        {...row('device-a'), 'id': 'bad id with spaces'},
      ],
      [
        {...row('device-a'), 'id': 'x' * 65},
      ],
      [row('device-a'), row('device-a', name: '另一台')],
      [row('device-a'), 42],
      ['device-a'],
    ];
    for (final payload in payloads) {
      responseBody = payload;
      final read = await api.listDevices();
      expect(read.status, DeviceSessionsStatus.malformed, reason: '$payload');
    }
  });

  test('rejects malformed or ambiguous timestamps', () async {
    final payloads = <String>[
      'not-a-date',
      '',
      '2026-11-18',
      '2026-11-18T02:03:04',
      '2026-11-18T02:03:04+08:00',
      '2026-02-30T02:03:04Z',
      '2026-13-01T02:03:04Z',
      '2026-11-18T24:00:00Z',
      '2026-11-18T02:60:00Z',
      '2026-11-18T02:03:04.1234567Z',
      '2026-11-18T02:03:04Z ',
    ];
    for (final used in payloads) {
      responseBody = [
        row('device-a', used: used),
      ];
      final read = await api.listDevices();
      expect(
        read.status,
        DeviceSessionsStatus.malformed,
        reason: used,
      );
    }
  });

  test('rejects a non-boolean current flag and empty/oversized names', () async {
    final payloads = <Object?>[
      [
        {...row('device-a'), 'current': 'true'},
      ],
      [
        {...row('device-a'), 'current': 1},
      ],
      [
        {...row('device-a'), 'deviceName': ''},
      ],
      [
        {...row('device-a'), 'deviceName': '   '},
      ],
      [
        {...row('device-a'), 'deviceName': 'n' * 101},
      ],
      [
        {...row('device-a'), 'deviceName': 'bad\u0000name'},
      ],
    ];
    for (final payload in payloads) {
      responseBody = payload;
      final read = await api.listDevices();
      expect(read.status, DeviceSessionsStatus.malformed, reason: '$payload');
    }
  });

  test('maps 401 to unauthenticated without exposing the body', () async {
    status = 401;
    rawBody = '{"error":"unauthenticated","detail":"secret-token"}';
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.unauthenticated);
    expect(read.devices, isEmpty);
    expect(read.toString(), isNot(contains('secret-token')));
  });

  test('maps transport and server failures to unavailable', () async {
    for (final failure in [500, 503, 429]) {
      status = failure;
      responseBody = {'error': 'unavailable'};
      final read = await api.listDevices();
      expect(read.status, DeviceSessionsStatus.unavailable, reason: '$failure');
    }
  });

  test('maps malformed JSON to malformed, never a throw', () async {
    rawBody = 'not json at all';
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.malformed);
  });

  test('unreachable host is unavailable, never a raw transport throw', () async {
    await server.close(force: true);
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.unavailable);
  });

  test('revoke posts to the encoded device path and requires confirmation', () async {
    // The host answers a void success with an empty body.
    rawBody = '';
    final result = await api.revokeDevice('device-a');
    expect(result.status, DeviceRevokeStatus.revoked);
    expect(requests.single, (
      'POST',
      Routes.authDeviceRevoke.replaceFirst('{deviceId}', 'device-a'),
    ));
  });

  test('revoke accepts the explicit revoked acknowledgement', () async {
    responseBody = {'revoked': true};
    final result = await api.revokeDevice('device-a');
    expect(result.status, DeviceRevokeStatus.revoked);
  });

  test('revoke never claims success for an unexpected body', () async {
    for (final body in <Object?>[
      {'revoked': false},
      {'revoked': 'true'},
      {'removed': true},
      {'revoked': true, 'detail': 'x'},
      <Object?>[],
    ]) {
      responseBody = body;
      final result = await api.revokeDevice('device-a');
      expect(
        result.status,
        DeviceRevokeStatus.malformed,
        reason: '$body',
      );
    }
  });

  test('revoke maps 401 to unauthenticated and never replays', () async {
    var calls = 0;
    final renewServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    renewServer.listen((request) async {
      await request.drain<void>();
      calls++;
      request.response.statusCode = 401;
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"unauthenticated"}');
      await request.response.close();
    });
    var renewals = 0;
    final renewed = HostConnection(
      Uri.parse('http://127.0.0.1:${renewServer.port}'),
      'stale',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    try {
      final result = await DeviceSessionsApi(renewed).revokeDevice('device-a');
      expect(result.status, DeviceRevokeStatus.unauthenticated);
      expect(calls, 1);
      expect(renewals, 0);
    } finally {
      await renewed.close();
      await renewServer.close(force: true);
    }
  });

  test('revoke maps 5xx and malformed input to honest outcomes', () async {
    status = 500;
    responseBody = {'error': 'unavailable'};
    expect(
      (await api.revokeDevice('device-a')).status,
      DeviceRevokeStatus.unavailable,
    );
    status = 200;
    rawBody = 'not json';
    expect(
      (await api.revokeDevice('device-a')).status,
      DeviceRevokeStatus.malformed,
    );
    // Invalid local arguments never reach the host.
    requests.clear();
    await expectLater(api.revokeDevice('bad id'), throwsFormatException);
    await expectLater(api.revokeDevice(''), throwsFormatException);
    expect(requests, isEmpty);
  });

  test('never retains credentials or tokens in parsed values', () async {
    responseBody = [row('device-a')];
    final read = await api.listDevices();
    expect(read.status, DeviceSessionsStatus.loaded);
    expect(read.toString(), isNot(contains('fixture-token')));
    expect(read.devices.single.toString(), isNot(contains('fixture-token')));
  });
}
