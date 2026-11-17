import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/attachment_send_flow.dart';
import 'package:client_flutter/net/attachment_upload_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

const _digest = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

AttachmentContentSource _bytesSource(
  List<int> bytes, {
  String kind = 'file',
  String mime = 'application/octet-stream',
}) =>
    InjectedBytesContent(kind: kind, mime: mime, sha256: _digest, bytes: bytes);

void main() {
  late HttpServer server;
  late HostConnection connection;
  late AttachmentUploadApi api;
  late AttachmentSendFlow flow;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture',
    );
    api = AttachmentUploadApi(connection);
    flow = AttachmentSendFlow(api);
  });

  tearDown(() async {
    await connection.close();
    await server.close(force: true);
  });

  test('happy path uploads once and builds the outbox payload', () async {
    final requests = <(String, String, Object?)>[];
    server.listen((r) async {
      final raw = await utf8.decoder.bind(r).join();
      requests.add((r.method, r.uri.path, raw.isEmpty ? null : jsonDecode(raw)));
      r.response.write(switch (requests.length) {
        1 => '{"uploadId":"upload-1","chunkSize":524288}',
        2 => '{"received":3,"nextChunk":1}',
        _ => jsonEncode({'id': 'attachment-1', 'size': 3, 'sha256': _digest}),
      });
      await r.response.close();
    });

    final result = await flow.upload(
      source: _bytesSource([1, 2, 3]),
      conversationId: 'conv-1',
    );

    expect(result.attachmentId, 'attachment-1');
    expect(result.conversationId, 'conv-1');
    expect(result.kind, MessageKind.file);
    expect(result.size, 3);
    expect(result.sha256, _digest);
    expect(result.body, {'attachmentId': 'attachment-1'});

    final payload = result.outboxPayload('client-1');
    expect(payload, {
      'clientMsgId': 'client-1',
      'kind': 'file',
      'body': {'attachmentId': 'attachment-1'},
    });
    final submission = result.submission('client-1');
    expect(submission.conversationId, 'conv-1');
    expect(submission.payload, payload);

    expect(requests.map((r) => (r.$1, r.$2)).toList(), [
      ('POST', Routes.attachmentUploads),
      ('PUT', '/api/v1/attachments/uploads/upload-1/chunks/0'),
      ('POST', '/api/v1/attachments/uploads/upload-1/complete'),
    ]);
    expect(requests[0].$3, {
      'mime': 'application/octet-stream',
      'size': 3,
      'kind': 'file',
      'conversationId': 'conv-1',
    });
    expect(requests[1].$3, {'dataBase64': base64Encode([1, 2, 3])});
    expect(requests[2].$3, {'sha256': _digest});
  });

  test('chunks use the advertised size with a short trailing chunk', () async {
    final putPaths = <String>[];
    final chunks = <int, List<int>>{};
    var cumulative = 0;
    server.listen((r) async {
      final raw = await utf8.decoder.bind(r).join();
      final body = raw.isEmpty ? null : jsonDecode(raw);
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":4}');
      } else if (r.method == 'PUT') {
        putPaths.add(r.uri.path);
        final index = int.parse(r.uri.pathSegments.last);
        final data = base64Decode((body as Map)['dataBase64'] as String);
        chunks[index] = data;
        cumulative += data.length;
        r.response.write(jsonEncode({'received': cumulative, 'nextChunk': index + 1}));
      } else {
        r.response.write(jsonEncode({'id': 'a', 'size': 10, 'sha256': _digest}));
      }
      await r.response.close();
    });

    final result = await flow.upload(
      source: _bytesSource(List.generate(10, (i) => i)),
      conversationId: 'c',
    );

    expect(result.attachmentId, 'a');
    expect(chunks[0], [0, 1, 2, 3]);
    expect(chunks[1], [4, 5, 6, 7]);
    expect(chunks[2], [8, 9]);
    expect(putPaths, [
      '/api/v1/attachments/uploads/u/chunks/0',
      '/api/v1/attachments/uploads/u/chunks/1',
      '/api/v1/attachments/uploads/u/chunks/2',
    ]);
  });

  test('a single 401 on a chunk is retried once with a fresh token', () async {
    await connection.close();
    var renewals = 0;
    final authorizations = <String?>[];
    var putCalls = 0;
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
    flow = AttachmentSendFlow(api);
    server.listen((r) async {
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":524288}');
      } else if (r.method == 'PUT') {
        putCalls++;
        authorizations.add(r.headers[HttpHeaders.authorizationHeader]?.single);
        if (putCalls == 1) {
          r.response.statusCode = 401;
          r.response.write('{"error":"unauthenticated"}');
        } else {
          r.response.write('{"received":3,"nextChunk":1}');
        }
      } else {
        r.response.write(jsonEncode({'id': 'a', 'size': 3, 'sha256': _digest}));
      }
      await r.response.close();
    });

    final result = await flow.upload(
      source: _bytesSource([0, 127, 255]),
      conversationId: 'c',
    );

    expect(result.attachmentId, 'a');
    expect(renewals, 1);
    expect(putCalls, 2);
    expect(authorizations, ['Bearer old', 'Bearer fresh']);
  });

  test('persistent 401 stays bounded to one replay', () async {
    await connection.close();
    var renewals = 0;
    var putCalls = 0;
    var completeCalls = 0;
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
    flow = AttachmentSendFlow(api);
    server.listen((r) async {
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":524288}');
      } else if (r.method == 'PUT') {
        putCalls++;
        r.response.statusCode = 401;
        r.response.write('{"error":"unauthenticated"}');
      } else {
        completeCalls++;
        r.response.write('{}');
      }
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1]), conversationId: 'c'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unauthenticated,
        ),
      ),
    );
    expect(putCalls, 2);
    expect(renewals, 1);
    expect(completeCalls, 0);
  });

  test('malformed initiate is surfaced without a replay', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.write('private-raw-json');
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1]), conversationId: 'c'),
      throwsFormatException,
    );
    expect(calls, 1);
  });

  test('malformed chunk acknowledgement is surfaced without a replay', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.write(calls == 1
          ? '{"uploadId":"u","chunkSize":524288}'
          : '{"received":-1,"nextChunk":1}');
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1]), conversationId: 'c'),
      throwsFormatException,
    );
    expect(calls, 2);
  });

  test('503 at initiate is not silently replayed', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.statusCode = 503;
      r.response.write('{"error":"unavailable"}');
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1]), conversationId: 'c'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unavailable,
        ),
      ),
    );
    expect(calls, 1);
  });

  test('503 at complete is not silently replayed', () async {
    var calls = 0;
    var completeCalls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":524288}');
      } else if (r.method == 'PUT') {
        r.response.write('{"received":1,"nextChunk":1}');
      } else {
        completeCalls++;
        r.response.statusCode = 503;
        r.response.write('{"error":"unavailable"}');
      }
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1]), conversationId: 'c'),
      throwsA(
        isA<HostRequestException>().having(
          (e) => e.failure.code,
          'code',
          FailureCode.unavailable,
        ),
      ),
    );
    expect(completeCalls, 1);
    expect(calls, 3);
  });

  test('cancel before initiate issues no HTTP', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.write('{}');
      await r.response.close();
    });
    final cancellation = AttachmentSendCancellation()..cancel();

    await expectLater(
      flow.upload(
        source: _bytesSource([1, 2, 3]),
        conversationId: 'c',
        cancellation: cancellation,
      ),
      throwsA(isA<AttachmentSendCancelled>()),
    );
    expect(calls, 0);
  });

  test('cancel mid-upload stops before the next chunk and complete', () async {
    final cancellation = AttachmentSendCancellation();
    var putCalls = 0;
    var completeCalls = 0;
    server.listen((r) async {
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":4}');
      } else if (r.method == 'PUT') {
        putCalls++;
        cancellation.cancel();
        r.response.write('{"received":4,"nextChunk":1}');
      } else {
        completeCalls++;
        r.response.write(jsonEncode({'id': 'a', 'size': 6, 'sha256': _digest}));
      }
      await r.response.close();
    });

    await expectLater(
      flow.upload(
        source: _bytesSource(List.generate(6, (i) => i)),
        conversationId: 'c',
        cancellation: cancellation,
      ),
      throwsA(isA<AttachmentSendCancelled>()),
    );
    expect(putCalls, 1);
    expect(completeCalls, 0);
  });

  test('declared size mismatch aborts before complete', () async {
    var completeCalls = 0;
    server.listen((r) async {
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":524288}');
      } else if (r.method == 'PUT') {
        r.response.write('{"received":3,"nextChunk":1}');
      } else {
        completeCalls++;
        r.response.write(jsonEncode({'id': 'a', 'size': 5, 'sha256': _digest}));
      }
      await r.response.close();
    });
    final source = InjectedStreamContent(
      () => Stream<List<int>>.value([0, 1, 2]),
      kind: 'file',
      size: 5,
      mime: 'application/octet-stream',
      sha256: _digest,
    );

    await expectLater(
      flow.upload(source: source, conversationId: 'c'),
      throwsFormatException,
    );
    expect(completeCalls, 0);
  });

  test('host completed size mismatch is rejected', () async {
    server.listen((r) async {
      await r.drain<void>();
      if (r.method == 'POST' && r.uri.path == Routes.attachmentUploads) {
        r.response.write('{"uploadId":"u","chunkSize":524288}');
      } else if (r.method == 'PUT') {
        r.response.write('{"received":3,"nextChunk":1}');
      } else {
        r.response.write(jsonEncode({'id': 'a', 'size': 4, 'sha256': _digest}));
      }
      await r.response.close();
    });

    await expectLater(
      flow.upload(source: _bytesSource([1, 2, 3]), conversationId: 'c'),
      throwsFormatException,
    );
  });

  test('attachment kind maps to a message kind and video needs an override', () {
    expect(AttachmentSendFlow.messageKindFor('text'), MessageKind.text);
    expect(AttachmentSendFlow.messageKindFor('image'), MessageKind.image);
    expect(AttachmentSendFlow.messageKindFor('file'), MessageKind.file);
    expect(AttachmentSendFlow.messageKindFor('voice'), MessageKind.audio);
    expect(AttachmentSendFlow.messageKindFor('video'), isNull);
    expect(AttachmentSendFlow.messageKindFor('live2d'), isNull);
  });

  test('unsupported kind without an override issues no HTTP', () async {
    var calls = 0;
    server.listen((r) async {
      calls++;
      await r.drain<void>();
      r.response.write('{}');
      await r.response.close();
    });

    await expectLater(
      flow.upload(
        source: _bytesSource([1], kind: 'video'),
        conversationId: 'c',
      ),
      throwsFormatException,
    );
    expect(calls, 0);
  });
}
