import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/message_operations_api.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

final _sentAt = DateTime.utc(2026, 11, 20, 10, 11, 12);
final _original = MessageEventFrame(
  id: 'msg-2',
  at: _sentAt,
  conversationId: 'conv-1',
  seq: 2,
  messageId: 'msg-2',
  senderId: 'alice',
  kind: MessageKind.text,
  body: const {
    'text': '旧内容',
    'mentionAccountIds': ['ai-1'],
  },
  sentAt: _sentAt,
);
const _text = '改好的内容';
const _body = {
  'text': _text,
  'mentionAccountIds': ['ai-1'],
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection connection;
  late MessageOperationsApi api;
  Object? payload;
  int status = 200;
  final requests = <(String, String, Object?)>[];

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    connection = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'fixture-owner-token',
      onUnauthorized: () async => fail('mutations must not replay auth'),
    );
    api = MessageOperationsApi(connection);
    payload = null;
    status = 200;
    requests.clear();
    subscription = server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((
        request.method,
        request.uri.path,
        raw.isEmpty ? null : jsonDecode(raw),
      ));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(payload));
      await request.response.close();
    });
  });

  tearDown(() async {
    await subscription.cancel();
    await connection.close();
    await server.close(force: true);
  });

  test(
    'edit preserves non-text fields and validates an exact same-row receipt',
    () async {
      // Different key order is still the same body.
      payload = {
        ..._original.payload(),
        'body': {
          'mentionAccountIds': ['ai-1'],
          'text': _text,
        },
      };
      final result = await api.editMessage(source: _original, text: _text);
      expect(result, isA<EditAccepted>());
      expect((result as EditAccepted).body, _body);
      expect(requests.single.$1, 'POST');
      expect(
        requests.single.$2,
        '/api/v1/conversations/conv-1/messages/msg-2/edit',
      );
      expect(requests.single.$3, {'body': _body});
    },
  );

  test(
    'any changed identity or unexpected body is an unconfirmed edit',
    () async {
      for (final patch in <Map<String, Object?>>[
        {'conversationId': 'other'},
        {'messageId': 'other'},
        {'senderId': 'bob'},
        {'seq': 3},
        {'kind': 'image'},
        {'sentAt': '2026-11-20T11:11:12.000Z'},
        {
          'sentAt': '2026-11-20T09:71:12.000Z',
        }, // DateTime.parse would normalize it.
        {
          'body': {'text': _text},
        },
        {
          'body': {..._body, 'recalled': true},
        },
        {
          'body': {..._body, 'text': 'other'},
        },
      ]) {
        payload = {..._original.payload(), 'body': _body, ...patch};
        expect(
          await api.editMessage(source: _original, text: _text),
          isA<MessageWriteUnknown>(),
          reason: '$patch',
        );
      }
      expect(requests.length, 10, reason: 'no automatic replay');
    },
  );

  test(
    'empty, unchanged or larger than 4000 code units never reach transport',
    () async {
      for (final text in ['   ', '旧内容', 'x' * 4001]) {
        expect(
          await api.editMessage(source: _original, text: text),
          isA<MessageWriteRejected>(),
        );
      }
      expect(requests, isEmpty);
    },
  );

  test(
    'recall posts no plaintext and requires the exact positive receipt',
    () async {
      payload = const {'recalled': true};
      expect(
        await api.recallMessage(conversationId: 'conv-1', messageId: 'msg-2'),
        isA<MessageWriteAccepted>(),
      );
      expect(requests.single.$1, 'POST');
      expect(
        requests.single.$2,
        '/api/v1/conversations/conv-1/messages/msg-2/recall',
      );
      expect(requests.single.$3, isNull);
      for (final malformed in [
        {'recalled': false},
        {'recalled': 'true'},
        {'recalled': true, 'extra': 1},
      ]) {
        payload = malformed;
        expect(
          await api.recallMessage(conversationId: 'conv-1', messageId: 'msg-2'),
          isA<MessageWriteUnknown>(),
        );
      }
    },
  );

  test(
    'refusal and ambiguity stay distinct without retries for either write',
    () async {
      for (final (code, matcher) in [
        (400, isA<MessageWriteRejected>()),
        (401, isA<MessageWriteRejected>()),
        (403, isA<MessageWriteRejected>()),
        (404, isA<MessageWriteRejected>()),
        (409, isA<MessageWriteUnknown>()),
        (500, isA<MessageWriteUnknown>()),
      ]) {
        status = code;
        payload = const {'detail': 'synthetic raw host detail'};
        expect(await api.editMessage(source: _original, text: _text), matcher);
        expect(
          await api.recallMessage(conversationId: 'conv-1', messageId: 'msg-2'),
          matcher,
        );
      }
      expect(requests.length, 12);
    },
  );

  test('invalid recall identifiers do not reach transport', () async {
    expect(
      await api.recallMessage(conversationId: 'conv-1', messageId: '../other'),
      isA<MessageWriteRejected>(),
    );
    expect(requests, isEmpty);
  });
}
