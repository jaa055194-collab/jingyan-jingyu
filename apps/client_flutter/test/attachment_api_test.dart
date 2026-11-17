import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/attachment_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

const _secret = 'ATTACHMENT-SECRET-SENTINEL';

Map<String, Object?> _metadata() => {
  'id': 'attach-1',
  'ownerAccountId': 'owner',
  'conversationId': 'conv-1',
  'kind': 'image',
  'mime': 'image/png',
  'size': 2048,
  'sha256': 'a' * 64,
  'width': 640,
  'height': 480,
  'durationMs': null,
  'extractionStatus': 'pending',
  'createdAt': '2026-11-17T13:00:00.000Z',
};

void main() {
  late HttpServer server;
  late HostConnection connection;
  late AttachmentApi api;
  final requests = <(String, String, String?, String)>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-token',
    );
    api = AttachmentApi(connection);
    requests.clear();
  });
  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  void capture() {
    server.listen((request) async {
      final text = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
        text,
      ));
      request.response.write(jsonEncode(_metadata()));
      await request.response.close();
    });
  }

  test('readAttachment uses exact GET path with bearer and no body', () async {
    capture();
    final metadata = await api.readAttachment('attach-1');
    expect(requests.single.$1, 'GET');
    expect(requests.single.$2, '/api/v1/attachments/attach-1');
    expect(requests.single.$3, 'Bearer fixture-token');
    expect(requests.single.$4, isEmpty);
    expect(metadata.kind, 'image');
    expect(metadata.mime, 'image/png');
    expect(metadata.size, 2048);
    expect(metadata.conversationId, 'conv-1');
    expect(metadata.width, 640);
    expect(metadata.durationMs, isNull);
    expect(metadata.extractionStatus, 'pending');
  });

  test('URL-encodes the attachment id in the path', () async {
    capture();
    await api.readAttachment('abc_def-123');
    expect(requests.single.$2, '/api/v1/attachments/abc_def-123');
  });

  test(
    'invalid attachment id never issues HTTP and never echoes input',
    () async {
      var count = 0;
      server.listen((request) async {
        count++;
        await request.drain<void>();
        request.response.statusCode = 500;
        await request.response.close();
      });
      for (final id in ['', 'bad/id', 'x' * 65]) {
        await expectLater(
          api.readAttachment(id),
          throwsA(
            predicate(
              (error) =>
                  error is FormatException &&
                  error.source == null &&
                  !error.toString().contains('bad/id'),
            ),
          ),
        );
      }
      expect(count, 0);
    },
  );

  test('decrypted text is never accepted or surfaced', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(
        jsonEncode({..._metadata(), 'extractedText': 'PRIVATE $_secret'}),
      );
      await request.response.close();
    });
    await expectLater(
      api.readAttachment('attach-1'),
      throwsA(
        predicate(
          (error) =>
              error is FormatException &&
              error.source == null &&
              !error.toString().contains(_secret),
        ),
      ),
    );
  });

  test('not-found stays a safe failure with no leak', () async {
    server.listen((request) async {
      await request.drain<void>();
      request.response.statusCode = 404;
      request.response.write(
        jsonEncode({'error': 'not_found', 'leak': _secret}),
      );
      await request.response.close();
    });
    await expectLater(
      api.readAttachment('attach-1'),
      throwsA(
        predicate(
          (error) =>
              error is HostRequestException &&
              error.failure.code == FailureCode.notFound &&
              !error.toString().contains(_secret),
        ),
      ),
    );
  });

  test('malformed metadata fields are rejected with safe errors', () async {
    final invalid = <Object?>[
      [],
      {..._metadata()}..remove('kind'),
      {..._metadata(), 'extra': _secret},
      {..._metadata(), 'size': -1},
      {..._metadata(), 'size': 1.0},
      {..._metadata(), 'sha256': 'z' * 64},
      {..._metadata(), 'extractionStatus': 'unknown-status'},
      {..._metadata(), 'width': -4},
      {..._metadata(), 'createdAt': 'not-a-date'},
      {..._metadata(), 'conversationId': 3},
      {..._metadata(), 'mime': '   '},
    ];
    var index = 0;
    server.listen((request) async {
      await request.drain<void>();
      request.response.write(jsonEncode(invalid[index++]));
      await request.response.close();
    });
    for (var i = 0; i < invalid.length; i++) {
      await expectLater(
        api.readAttachment('attach-1'),
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
    expect(index, invalid.length);
  });
}
