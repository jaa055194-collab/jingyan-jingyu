import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:client_flutter/net/chat_pins_api.dart';
import 'package:client_flutter/net/host_connection.dart';
import 'package:flutter_test/flutter_test.dart';

const _pinRow = {
  'messageId': 'm-1',
  'pinnedBy': 'peer-1',
  'pinnedAt': '2026-11-20T09:03:02.000Z',
};

void main() {
  late HttpServer server;
  late StreamSubscription<HttpRequest> subscription;
  late HostConnection transport;
  late ChatPinsApi api;
  late Object? response;
  late int status;
  final requests = <(String, String, String)>[];

  setUp(() async {
    requests.clear();
    response = null;
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    transport = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'synthetic-auth',
      onUnauthorized: () async => fail('a pins request must not replay auth'),
    );
    api = ChatPinsApi(transport);
    subscription = server.listen((request) async {
      final raw = await utf8.decoder.bind(request).join();
      requests.add((request.method, request.uri.path, raw));
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
  });
  tearDown(() async {
    await transport.close();
    await subscription.cancel();
    await server.close(force: true);
  });

  test('only the IDs are retained from a valid ordered list', () async {
    response = {
      'pins': [
        _pinRow,
        {..._pinRow, 'messageId': 'm-2'},
      ],
    };
    final result = await api.read('c-1');
    expect(result, isA<ChatPinsLoaded>());
    expect((result as ChatPinsLoaded).ids, ['m-1', 'm-2']);
    expect(requests, [('GET', '/api/v1/conversations/c-1/pins', '')]);
  });

  test(
    'a confirmed empty list differs from malformed or refused reads',
    () async {
      response = {'pins': []};
      final empty = await api.read('c-1');
      expect(empty, isA<ChatPinsLoaded>());
      expect((empty as ChatPinsLoaded).ids, isEmpty);
      for (final invalid in [
        {
          'pins': [_pinRow, _pinRow],
        },
        {
          'pins': [
            {'messageId': 'm-1'},
          ],
        },
        {
          'pins': [
            {..._pinRow, 'pinnedAt': '2026-11-99T09:03:02.000Z'},
          ],
        },
        {
          'pins': [
            {..._pinRow, 'pinnedBy': '../outside'},
          ],
        },
        {
          'pins': [
            {..._pinRow, 'messageId': '../outside'},
          ],
        },
        {
          'pins': [
            {..._pinRow, 'text': 'payload must not pass through'},
          ],
        },
        {
          'pins': [
            for (var seq = 0; seq < 51; seq++)
              {..._pinRow, 'messageId': 'm-$seq'},
          ],
        },
      ]) {
        response = invalid;
        expect(
          await api.read('c-1'),
          isA<ChatPinsUnavailable>(),
          reason: '$invalid',
        );
      }
      status = 404;
      expect(await api.read('c-1'), isA<ChatPinsUnavailable>());
    },
  );

  test(
    'pin and unpin require their exact receipts, with no request body',
    () async {
      response = {'pinned': true, 'duplicate': true};
      expect(
        await api.setPinned('c-1', 'm-1', pinned: true),
        ChatPinWrite.confirmed,
      );
      response = {'pinned': false};
      expect(
        await api.setPinned('c-1', 'm-1', pinned: false),
        ChatPinWrite.confirmed,
      );
      expect(requests, [
        ('POST', '/api/v1/conversations/c-1/messages/m-1/pin', ''),
        ('DELETE', '/api/v1/conversations/c-1/messages/m-1/pin', ''),
      ]);
    },
  );

  test('an ambiguous receipt remains unknown and is not replayed', () async {
    for (final (adding, payload) in [
      (true, {'pinned': true}),
      (true, {'pinned': true, 'duplicate': 'false'}),
      (true, {'pinned': false, 'duplicate': false}),
      (false, {'pinned': true}),
      (false, {'pinned': false, 'extra': 0}),
    ]) {
      response = payload;
      expect(
        await api.setPinned('c-1', 'm-1', pinned: adding),
        ChatPinWrite.unknown,
      );
    }
    status = 500;
    expect(
      await api.setPinned('c-1', 'm-1', pinned: true),
      ChatPinWrite.unknown,
    );
    status = 401;
    expect(
      await api.setPinned('c-1', 'm-1', pinned: false),
      ChatPinWrite.refused,
    );
    expect(requests.length, 7);
  });

  test('bad IDs never reach the transport', () async {
    expect(await api.read('../outside'), isA<ChatPinsUnavailable>());
    expect(
      await api.setPinned('c-1', '../outside', pinned: true),
      ChatPinWrite.refused,
    );
    expect(requests, isEmpty);
  });
}
