import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/attachment_upload_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

void main() {
  late HttpServer server;
  late HostConnection connection;
  late AttachmentUploadApi api;
  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = AttachmentUploadApi(connection);
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test(
    'explicit stages use existing routes and canonical acknowledgements',
    () async {
      final requests = <(String, String, Object?, String?)>[];
      server.listen((r) async {
        requests.add((
          r.method,
          r.uri.path,
          jsonDecode(await utf8.decoder.bind(r).join()),
          r.headers[HttpHeaders.authorizationHeader]?.single,
        ));
        r.response.write(switch (requests.length) {
          1 => '{"uploadId":"upload-1","chunkSize":524288}',
          2 => '{"received":3,"nextChunk":1}',
          _ => jsonEncode({
            'id': 'attachment-1',
            'size': 3,
            'sha256': 'a' * 64,
            'extractionStatus': 'unsupported',
          }),
        });
        await r.response.close();
      });
      final upload = await api.initiate(
        mime: ' application/octet-stream ',
        size: 3,
        kind: 'file',
        conversationId: 'group',
      );
      expect(upload.uploadId, 'upload-1');
      expect(upload.chunkSize, 524288);
      final progress = await api.putChunk(
        uploadId: upload.uploadId,
        index: 0,
        bytes: [0, 127, 255],
      );
      expect((progress.received, progress.nextChunk), (3, 1));
      final completed = await api.complete(
        uploadId: upload.uploadId,
        expectedSha256: 'a' * 64,
      );
      expect(
        (completed.attachmentId, completed.size, completed.sha256),
        ('attachment-1', 3, 'a' * 64),
      );
      expect(requests.map((r) => (r.$1, r.$2, r.$4)).toList(), [
        ('POST', Routes.attachmentUploads, 'Bearer fixture'),
        (
          'PUT',
          '/api/v1/attachments/uploads/upload-1/chunks/0',
          'Bearer fixture',
        ),
        (
          'POST',
          '/api/v1/attachments/uploads/upload-1/complete',
          'Bearer fixture',
        ),
      ]);
      expect(requests[0].$3, {
        'mime': 'application/octet-stream',
        'size': 3,
        'kind': 'file',
        'conversationId': 'group',
      });
      expect(requests[1].$3, {'dataBase64': 'AH//'});
      expect(requests[2].$3, {'sha256': 'a' * 64});
    },
  );

  test('in-flight caller mutation cannot change encoded bytes or acknowledgement validation', () async {
    final bytes = <int>[1];
    server.listen((r) async {
      final body = jsonDecode(await utf8.decoder.bind(r).join());
      expect(body, {'dataBase64': 'AQ=='});
      bytes.addAll([2, 3]);
      r.response.write('{"received":1,"nextChunk":1}');
      await r.response.close();
    });
    final progress = await api.putChunk(uploadId: 'u', index: 0, bytes: bytes);
    expect(progress.received, 1);
  });

  test('invalid local input never issues HTTP', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.write('{}');
      await r.response.close();
    });
    for (final size in [-1, 128 * 1024 * 1024 + 1]) {
      await expectLater(
        api.initiate(mime: 'text/plain', size: size, kind: 'file'),
        throwsFormatException,
      );
    }
    await expectLater(
      api.initiate(mime: ' ', size: 0, kind: 'file'),
      throwsFormatException,
    );
    await expectLater(
      api.initiate(mime: 'text/plain', size: 0, kind: 'unknown'),
      throwsFormatException,
    );
    await expectLater(
      api.initiate(
        mime: 'text/plain',
        size: 0,
        kind: 'text',
        conversationId: 'bad/id',
      ),
      throwsFormatException,
    );
    await expectLater(
      api.putChunk(uploadId: 'bad/id', index: 0, bytes: [1]),
      throwsFormatException,
    );
    await expectLater(
      api.putChunk(uploadId: 'u', index: -1, bytes: [1]),
      throwsFormatException,
    );
    await expectLater(
      api.putChunk(uploadId: 'u', index: 0, bytes: [256]),
      throwsFormatException,
    );
    await expectLater(
      api.putChunk(uploadId: 'u', index: 0, bytes: List.filled(524289, 0)),
      throwsFormatException,
    );
    await expectLater(
      api.complete(uploadId: 'u', expectedSha256: 'wrong'),
      throwsFormatException,
    );
    expect(calls, 0);
  });

  test('malformed DTO and JSON failures never echo upstream data', () async {
    final bodies = <String>[
      '{"uploadId":"private/id","chunkSize":1}',
      '{"uploadId":"u","chunkSize":524289}',
      '{"received":-1,"nextChunk":1}',
      '{"received":1,"nextChunk":0}',
      '{"id":"private/id","size":1,"sha256":"${'a' * 64}"}',
      'private-raw-json',
    ];
    var next = 0;
    server.listen((r) async {
      await r.drain<void>();
      r.response.write(bodies[next++]);
      await r.response.close();
    });
    final actions = <Future<Object> Function()>[
      () => api.initiate(mime: 'text/plain', size: 1, kind: 'file'),
      () => api.initiate(mime: 'text/plain', size: 1, kind: 'file'),
      () => api.putChunk(uploadId: 'u', index: 0, bytes: [1]),
      () => api.putChunk(uploadId: 'u', index: 0, bytes: [1]),
      () => api.complete(uploadId: 'u'),
      () => api.complete(uploadId: 'u'),
    ];
    for (final action in actions) {
      try {
        await action();
        fail('must reject malformed host response');
      } on FormatException catch (error) {
        expect(error.toString(), isNot(contains('private')));
      }
    }
  });

  test(
    'uncertain initiate and complete failures are not automatically replayed',
    () async {
      var calls = 0;
      server.listen((r) async {
        calls++;
        await r.drain<void>();
        r.response.statusCode = 503;
        r.response.write('{"error":"unavailable"}');
        await r.response.close();
      });
      for (final action in <Future<Object> Function()>[
        () => api.initiate(mime: 'text/plain', size: 1, kind: 'file'),
        () => api.complete(uploadId: 'u'),
      ]) {
        await expectLater(
          action(),
          throwsA(
            isA<HostRequestException>().having(
              (e) => e.failure.code,
              'code',
              FailureCode.unavailable,
            ),
          ),
        );
      }
      expect(calls, 2);
    },
  );

  test(
    'chunk authentication replay keeps exact index and byte-identical body',
    () async {
      final bytes = <int>[0, 127, 255];
      final requests = <(String, String, String, String?)>[];
      var renewals = 0;
      await connection.close();
      connection = HostConnection(
        Uri.parse('http://127.0.0.1:${server.port}'),
        'old',
        onUnauthorized: () async {
          renewals++;
          bytes.setAll(0, [9, 9, 9]);
          connection.updateAccessToken('fresh');
          return true;
        },
      );
      api = AttachmentUploadApi(connection);
      server.listen((r) async {
        requests.add((
          r.method,
          r.uri.path,
          await utf8.decoder.bind(r).join(),
          r.headers[HttpHeaders.authorizationHeader]?.single,
        ));
        if (requests.length == 1) {
          r.response.statusCode = 401;
          r.response.write('{"error":"unauthenticated"}');
        } else {
          r.response.write('{"received":3,"nextChunk":8}');
        }
        await r.response.close();
      });
      final progress = await api.putChunk(
        uploadId: 'u',
        index: 7,
        bytes: bytes,
      );
      expect((progress.received, progress.nextChunk), (3, 8));
      expect(renewals, 1);
      expect(requests, hasLength(2));
      expect(requests[0].$1, 'PUT');
      expect(requests[1].$1, 'PUT');
      expect(requests[0].$2, '/api/v1/attachments/uploads/u/chunks/7');
      expect(requests[1].$2, requests[0].$2);
      expect(requests[1].$3, requests[0].$3);
      expect(jsonDecode(requests[0].$3), {'dataBase64': 'AH//'});
      expect(requests[0].$4, 'Bearer old');
      expect(requests[1].$4, 'Bearer fresh');
    },
  );

  test('401 renewal shares existing connection and does not swallow terminal rejection', () async {
    var calls = 0, renewals = 0;
    await connection.close();
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'old',
      onUnauthorized: () async {
        renewals++;
        connection.updateAccessToken('fresh');
        return true;
      },
    );
    api = AttachmentUploadApi(connection);
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      if (calls == 1 || calls > 2) {
        r.response.statusCode = 401;
        r.response.write('{"error":"unauthenticated"}');
      } else {
        r.response.write('{"uploadId":"u","chunkSize":1}');
      }
      await r.response.close();
    });
    expect(
      (await api.initiate(mime: 'text/plain', size: 1, kind: 'file')).uploadId,
      'u',
    );
    expect(renewals, 1);
    await expectLater(
      api.complete(uploadId: 'u'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unauthenticated,
        ),
      ),
    );
    expect(calls, 4);
  });
}
