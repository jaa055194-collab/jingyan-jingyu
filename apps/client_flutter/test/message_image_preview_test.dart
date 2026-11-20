import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/attachment_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

List<int> _png() => const [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3, 4];

Map<String, Object?> _payload(List<int> bytes, {String? mime}) => {
  'mime': mime ?? 'image/png',
  'size': bytes.length,
  'sha256': sha256.convert(bytes).toString(),
  'dataBase64': base64Encode(bytes),
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> sub;
  late HostConnection connection;
  late AttachmentApi api;
  late List<(String, String)> requests;
  Map<String, Object?>? response;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'token',
    );
    api = AttachmentApi(connection);
    requests = [];
    response = null;
    sub = server.listen((request) async {
      requests.add((request.method, request.uri.path));
      await request.drain<void>();
      final body = response;
      if (body == null) {
        request.response.statusCode = 404;
        request.response.write('{"error":"notFound"}');
      } else {
        request.response.write(jsonEncode(body));
      }
      await request.response.close();
    });
  });
  tearDown(() async {
    await sub.cancel();
    await connection.close();
    await server.close(force: true);
  });

  test('reads one image through the message-scoped route', () async {
    final bytes = _png();
    response = _payload(bytes);

    final image = await api.readMessageImage(
      conversationId: 'group-1',
      messageId: 'message-1',
    );

    expect(image.bytes, bytes);
    expect(image.mime, 'image/png');
    expect(requests, [
      ('GET', '/api/v1/conversations/group-1/messages/message-1/attachment'),
    ]);
  });

  test('rejects a digest mismatch and never renders the payload', () async {
    final bytes = _png();
    response = _payload(bytes)..['sha256'] = 'deadbeef';

    await expectLater(
      api.readMessageImage(conversationId: 'c', messageId: 'm'),
      throwsFormatException,
    );
  });

  test('rejects non-image MIME, oversize and foreign fields', () async {
    final bytes = _png();
    for (final payload in <Map<String, Object?>>[
      _payload(bytes, mime: 'image/svg+xml'),
      _payload(bytes, mime: 'application/octet-stream'),
      {..._payload(bytes), 'size': 8 * 1024 * 1024 + 1},
      {..._payload(bytes), 'extractedText': 'private'},
      {..._payload(bytes), 'path': '/private/blob'},
      {..._payload(bytes), 'dataBase64': 'not-base64!!'},
    ]) {
      response = payload;
      await expectLater(
        api.readMessageImage(conversationId: 'c', messageId: 'm'),
        throwsFormatException,
      );
    }
  });

  test('missing message maps to not found without leaking details', () async {
    response = null;
    await expectLater(
      api.readMessageImage(conversationId: 'c', messageId: 'm'),
      throwsA(
        predicate(
          (error) =>
              error is HostRequestException &&
              !error.toString().contains('private'),
        ),
      ),
    );
  });
}
