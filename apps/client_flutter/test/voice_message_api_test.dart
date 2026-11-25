import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:client_flutter/net/host_connection.dart';
import 'package:client_flutter/net/voice_message_api.dart';
import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:jingyu_core/jingyu_core.dart';

// The merged host tests use this same original AAC-LC mono 48 kHz silence.
Uint8List voiceSilence() =>
    File('../host/test/fixtures/voice-silence-aac-lc.m4a').readAsBytesSync();

Map<String, Object?> voiceResponse([Uint8List? content]) {
  final bytes = content ?? voiceSilence();
  return {
    'mime': 'audio/mp4',
    'size': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
    'dataBase64': base64Encode(bytes),
  };
}

const voicePath =
    '/api/v1/conversations/group/messages/voice-one/voice-attachment';

void main() {
  late HttpServer server;
  late HostConnection session;
  late VoiceMessageApi api;
  late Future<void> Function(HttpRequest) respond;
  late List<(String, String, String?)> requests;
  late int renewals;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    requests = [];
    renewals = 0;
    session = HostConnection(
      Uri.parse('http://127.0.0.1:${server.port}'),
      'voice-fixture-token',
      onUnauthorized: () async {
        renewals++;
        return true;
      },
    );
    api = VoiceMessageApi(session);
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(voiceResponse()));
      await request.response.close();
    };
    server.listen((request) async {
      requests.add((
        request.method,
        request.uri.toString(),
        request.headers.value(HttpHeaders.authorizationHeader),
      ));
      await respond(request);
    });
  });

  tearDown(() async {
    await session.close();
    await server.close(force: true);
  });

  Future<MessageVoice> read() =>
      api.read(conversationId: 'group', messageId: 'voice-one');

  test(
    'reads only the authorized message route and checks its exact bytes',
    () async {
      final voice = await read();
      expect(voice.bytes, orderedEquals(voiceSilence()));
      expect(voice.bytes.length, 778);
      expect(voice.mime, 'audio/mp4');
      expect(
        voice.sha256,
        '7e2348f52fb680c26eeff63da400dcb12f71b357c7c084906735d3a27d4d91de',
      );
      expect(requests, [('GET', voicePath, 'Bearer voice-fixture-token')]);
    },
  );

  test('rejects path-like ids without contacting the host', () async {
    await expectLater(
      api.read(conversationId: '../outside', messageId: 'voice-one'),
      throwsFormatException,
    );
    await expectLater(
      api.read(
        conversationId: 'group',
        messageId: 'https://example.invalid/audio',
      ),
      throwsFormatException,
    );
    expect(requests, isEmpty);
  });

  for (final (status, failure) in [
    (401, FailureCode.unauthenticated),
    (403, FailureCode.forbidden),
    (404, FailureCode.notFound),
    (503, FailureCode.unavailable),
  ]) {
    test(
      'HTTP $status is classified without auth replay or redirects',
      () async {
        respond = (request) async {
          request.response.statusCode = status;
          request.response.write('not a media response');
          await request.response.close();
        };
        await expectLater(
          read(),
          throwsA(
            isA<HostRequestException>().having(
              (error) => error.failure.code,
              'failure',
              failure,
            ),
          ),
        );
        expect(requests, hasLength(1));
        expect(renewals, 0);
      },
    );
  }

  test('redirect is not followed even on the same host', () async {
    respond = (request) async {
      request.response.statusCode = HttpStatus.found;
      request.response.headers.set(HttpHeaders.locationHeader, '/redirected');
      await request.response.close();
    };
    await expectLater(read(), throwsA(isA<HostRequestException>()));
    expect(requests, hasLength(1));
  });

  test(
    'rejects oversized declared HTTP bodies without waiting for bytes',
    () async {
      final finish = Completer<void>();
      respond = (request) async {
        request.response.contentLength = 12 * 1024 * 1024;
        request.response.add([32]);
        try {
          await request.response.flush();
          await finish.future;
          await request.response.close();
        } on HttpException {
          // The caller rejects the response before it is complete.
        }
      };
      try {
        await expectLater(
          read().timeout(const Duration(seconds: 4)),
          throwsFormatException,
        );
        expect(requests, hasLength(1));
      } finally {
        finish.complete();
      }
    },
  );

  test('bounds actual chunked bytes before UTF-8/JSON decode', () async {
    final finish = Completer<void>();
    respond = (request) async {
      request.response.bufferOutput = false;
      request.response.headers.chunkedTransferEncoding = true;
      // Not valid JSON, and the response deliberately never finishes while the
      // consumer waits. It must be rejected as soon as the streamed cap trips.
      request.response.add(List<int>.filled(65, 32));
      try {
        await request.response.flush();
        await finish.future;
        await request.response.close();
      } on HttpException {
        // Stream cancelled by bounded reader.
      }
    };
    try {
      await expectLater(
        session
            .getBoundedJson(voicePath, maxResponseBytes: 64)
            .timeout(const Duration(seconds: 4)),
        throwsFormatException,
      );
    } finally {
      finish.complete();
    }
  });

  test('cancels a bounded read waiting on the response body', () async {
    final writing = Completer<void>();
    final finish = Completer<void>();
    respond = (request) async {
      request.response.bufferOutput = false;
      request.response.headers.chunkedTransferEncoding = true;
      request.response.write('{');
      try {
        await request.response.flush();
        writing.complete();
        await finish.future;
        await request.response.close();
      } on HttpException {
        // Stream cancelled by the caller.
      }
    };
    final cancellation = HostReadCancellation();
    final reading = session.getBoundedJson(
      voicePath,
      maxResponseBytes: 1024,
      cancellation: cancellation,
    );
    final result = expectLater(
      reading.timeout(const Duration(seconds: 4)),
      throwsA(isA<HttpException>()),
    );
    try {
      await writing.future.timeout(const Duration(seconds: 4));
      cancellation.cancel();
      await result;
    } finally {
      finish.complete();
    }
  });

  test('strict DTO rejects invalid base64, size, digest, type and keys', () {
    final valid = voiceResponse();
    final base64 = valid['dataBase64']! as String;
    for (final change in <Map<String, Object?>>[
      {'mime': 'audio/m4a'},
      {'mime': 'video/mp4'},
      {'size': 0},
      {'size': 8 * 1024 * 1024 + 1},
      {'size': 777},
      {'size': '778'},
      {'sha256': '0' * 64},
      {'sha256': (valid['sha256']! as String).toUpperCase()},
      {'dataBase64': base64.substring(0, base64.length - 2)},
      {'dataBase64': '$base64\n'},
      {'dataBase64': '${base64.substring(0, base64.length - 3)}B=='},
      {'path': '/do-not-follow'},
    ]) {
      expect(
        () => MessageVoice.fromJson({...valid, ...change}),
        throwsFormatException,
        reason: 'reject invalid ${change.keys.single}',
      );
    }
    expect(
      () => MessageVoice.fromJson({...valid}..remove('sha256')),
      throwsFormatException,
    );
  });

  test('a matching digest does not bypass the MP4 header check', () {
    final wrongType = voiceSilence()..setAll(4, 'junk'.codeUnits);
    for (final bytes in [
      Uint8List.fromList([1, 2, 3]),
      wrongType,
    ]) {
      expect(
        () => MessageVoice.fromJson(voiceResponse(bytes)),
        throwsFormatException,
      );
    }
  });
}
