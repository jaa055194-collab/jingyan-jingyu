import 'dart:convert';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/voice/openai_voice_adapter.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:test/test.dart';

class _Captured {
  _Captured(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

class _FakeVendorServer {
  late HttpServer server;
  final List<_Captured> requests = <_Captured>[];
  int status = 200;
  List<int> audio = const <int>[1, 2, 3, 4];
  String? jsonBody;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = await request.fold<List<int>>(
        <int>[],
        (acc, chunk) => acc..addAll(chunk),
      );
      final headerMap = <String, String>{};
      request.headers.forEach((name, values) {
        headerMap[name.toLowerCase()] = values.join(',');
      });
      requests.add(_Captured(request.method, request.uri, headerMap, body));
      request.response.statusCode = status;
      if (jsonBody != null) {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonBody);
      } else {
        request.response.add(audio);
      }
      await request.response.close();
    });
  }

  String get baseUrl => 'http://127.0.0.1:${server.port}/v1';

  Future<void> close() => server.close(force: true);
}

/// Injected guarded-style transport that performs a real loopback HTTP round
/// trip. Production composes `GuardedHttpTransport.request` instead.
VoiceGuardedRequest _loopbackTransport() =>
    (method, uri, {headers = const {}, body}) async {
      final client = HttpClient();
      try {
        final request = await client.openUrl(method, uri);
        headers.forEach(request.headers.set);
        if (body != null) request.add(body);
        final response = await request.close();
        final bytes = await response.fold<List<int>>(
          <int>[],
          (acc, chunk) => acc..addAll(chunk),
        );
        final responseHeaders = <String, List<String>>{};
        response.headers.forEach((name, values) {
          responseHeaders[name] = List<String>.of(values);
        });
        return Ok<GuardedResponse>(
          GuardedResponse(
            statusCode: response.statusCode,
            headers: responseHeaders,
            body: bytes,
          ),
        );
      } catch (_) {
        return err<GuardedResponse>(
          FailureCode.unavailable,
          'transport failed',
        );
      } finally {
        client.close(force: true);
      }
    };

VoiceVendorConfigResolver _resolver(
  _FakeVendorServer server, {
  String key = 'sk-test-secret',
}) =>
    (provider) async => Ok<VoiceVendorConfig>(
      VoiceVendorConfig(baseUrl: server.baseUrl, apiKey: key),
    );

const _aiValue = 'ai1';

bool _containsBytes(List<int> haystack, List<int> needle) {
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var match = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        match = false;
        break;
      }
    }
    if (match) return true;
  }
  return false;
}

void main() {
  late _FakeVendorServer server;
  final clock = FakeClock(DateTime.utc(2026, 1, 1));

  setUp(() async {
    server = _FakeVendorServer();
    await server.start();
  });
  tearDown(() => server.close());

  group('TTS adapter', () {
    test(
      'posts OpenAI-compatible speech payload and returns opaque artifact',
      () async {
        final adapter = OpenAiCompatibleTtsAdapter(
          request: _loopbackTransport(),
          resolveConfig: _resolver(server),
        );
        final result = await adapter.synthesize(
          provider: 'openai',
          model: 'tts-1',
          voiceId: 'v-100',
          text: '你好，世界',
          params: const {'speed': 1.25, 'response_format': 'mp3'},
        );
        expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
        expect(result.value.ref, isNotEmpty);
        expect(
          adapter.vendorKey,
          isEmpty,
          reason: 'real adapter must not expose key',
        );

        final captured = server.requests.single;
        expect(captured.method, 'POST');
        expect(captured.uri.path, '/v1/audio/speech');
        expect(captured.headers['authorization'], 'Bearer sk-test-secret');
        expect(captured.headers['content-type'], contains('application/json'));
        final payload = jsonDecode(utf8.decode(captured.body!)) as Map;
        expect(payload['model'], 'tts-1');
        expect(payload['input'], '你好，世界');
        expect(payload['voice'], 'v-100');
        expect(payload['response_format'], 'mp3');
        expect(payload['speed'], 1.25);
      },
    );

    test(
      'maps 401 to forbidden and 429 to rateLimited without leaking key',
      () async {
        final adapter = OpenAiCompatibleTtsAdapter(
          request: _loopbackTransport(),
          resolveConfig: _resolver(server, key: 'sk-very-secret'),
        );
        server.status = 401;
        final unauthorized = await adapter.synthesize(
          provider: 'openai',
          model: 'tts-1',
          voiceId: 'v-100',
          text: 'hi',
          params: const {},
        );
        expect(unauthorized.failureOrNull?.code, FailureCode.forbidden);
        server.status = 429;
        final limited = await adapter.synthesize(
          provider: 'openai',
          model: 'tts-1',
          voiceId: 'v-100',
          text: 'hi',
          params: const {},
        );
        expect(limited.failureOrNull?.code, FailureCode.rateLimited);
        for (final result in [unauthorized, limited]) {
          expect(
            result.failureOrNull!.details.toString().contains('sk-very-secret'),
            isFalse,
          );
        }
      },
    );

    test(
      'transport error degrades to modelUnavailable and never logs key',
      () async {
        final adapter = OpenAiCompatibleTtsAdapter(
          request: (method, uri, {headers = const {}, body}) async =>
              err<GuardedResponse>(FailureCode.unavailable, 'boom'),
          resolveConfig: _resolver(server, key: 'sk-logged-secret'),
        );
        final result = await adapter.synthesize(
          provider: 'openai',
          model: 'tts-1',
          voiceId: 'v-100',
          text: 'hi',
          params: const {},
        );
        expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
        expect(result.toString().contains('sk-logged-secret'), isFalse);
        expect(
          result.failureOrNull!.message.contains('sk-logged-secret'),
          isFalse,
        );
      },
    );

    test('resolver failure performs no vendor request', () async {
      final adapter = OpenAiCompatibleTtsAdapter(
        request: _loopbackTransport(),
        resolveConfig: (_) async =>
            err<VoiceVendorConfig>(FailureCode.modelUnavailable, 'no provider'),
      );
      final result = await adapter.synthesize(
        provider: 'missing',
        model: 'tts-1',
        voiceId: 'v-100',
        text: 'hi',
        params: const {},
      );
      expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
      expect(server.requests, isEmpty);
    });
  });

  group('VoiceGateway degradation with real adapters', () {
    late VoiceProfiles profiles;
    setUp(() async {
      profiles = InMemoryVoiceProfiles(clock: clock);
      await profiles.create(
        ai: AiId.parse(_aiValue),
        provider: 'openai',
        model: 'tts-1',
        voiceId: 'v-100',
        consentRef: 'consent-1',
        grantedBy: 'owner',
        params: const {'speed': 1.1},
      );
    });

    test('success speaks with bound voice_id', () async {
      final gateway = VoiceGateway(
        profiles: profiles,
        tts: OpenAiCompatibleTtsAdapter(
          request: _loopbackTransport(),
          resolveConfig: _resolver(server),
        ),
        asr: FakeAsrAdapter(),
        clock: clock,
      );
      final result = await gateway.speak(ai: AiId.parse(_aiValue), text: '你好');
      expect(result.value.spoken, isTrue);
      expect(result.value.voiceId, 'v-100');
      expect(result.value.provider, 'openai');
      final payload =
          jsonDecode(utf8.decode(server.requests.single.body!)) as Map;
      expect(payload['voice'], 'v-100');
    });

    test(
      'vendor failure degrades to text and keeps voice_id and provider',
      () async {
        server.status = 500;
        final gateway = VoiceGateway(
          profiles: profiles,
          tts: OpenAiCompatibleTtsAdapter(
            request: _loopbackTransport(),
            resolveConfig: _resolver(server),
          ),
          asr: FakeAsrAdapter(),
          clock: clock,
        );
        final result = await gateway.speak(
          ai: AiId.parse(_aiValue),
          text: '你好',
        );
        expect(result.isOk, isTrue);
        expect(result.value.spoken, isFalse);
        expect(result.value.degraded, isTrue);
        expect(result.value.text, '你好');
        expect(result.value.voiceId, 'v-100');
        expect(result.value.provider, 'openai');
        // Request still used the original voice; profile never switched.
        final payload =
            jsonDecode(utf8.decode(server.requests.single.body!)) as Map;
        expect(payload['voice'], 'v-100');
        expect(
          (await profiles.get(ai: AiId.parse(_aiValue))).value.voiceId,
          'v-100',
        );
      },
    );
  });

  group('ASR adapter', () {
    test('posts multipart transcription and parses text', () async {
      server.jsonBody = jsonEncode({'text': 'hello world'});
      final adapter = OpenAiCompatibleAsrAdapter(
        request: _loopbackTransport(),
        resolveConfig: _resolver(server),
        provider: 'openai',
        model: 'whisper-1',
      );
      final result = await adapter.transcribe(audio: const [9, 8, 7, 6]);
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.text, 'hello world');
      final captured = server.requests.single;
      expect(captured.uri.path, '/v1/audio/transcriptions');
      expect(captured.headers['authorization'], 'Bearer sk-test-secret');
      expect(
        captured.headers['content-type'],
        startsWith('multipart/form-data; boundary='),
      );
      final text = latin1.decode(captured.body!);
      expect(text.contains('name="model"'), isTrue);
      expect(text.contains('whisper-1'), isTrue);
      expect(text.contains('name="file"; filename="audio.m4a"'), isTrue);
      expect(_containsBytes(captured.body!, const [9, 8, 7, 6]), isTrue);
    });

    test('vendor failure returns safe unavailable error', () async {
      server.status = 500;
      final adapter = OpenAiCompatibleAsrAdapter(
        request: _loopbackTransport(),
        resolveConfig: _resolver(server, key: 'sk-asr-secret'),
        provider: 'openai',
        model: 'whisper-1',
      );
      final result = await adapter.transcribe(audio: const [1, 2]);
      expect(result.failureOrNull?.code, FailureCode.unavailable);
      expect(result.toString().contains('sk-asr-secret'), isFalse);
    });

    test('gateway transcriber degrades without throwing', () async {
      server.status = 500;
      final profiles = InMemoryVoiceProfiles(clock: clock);
      final gateway = VoiceGateway(
        profiles: profiles,
        tts: FakeTtsAdapter(),
        asr: OpenAiCompatibleAsrAdapter(
          request: _loopbackTransport(),
          resolveConfig: _resolver(server),
          provider: 'openai',
          model: 'whisper-1',
        ),
        clock: clock,
      );
      final result = await gateway.transcribe(
        ai: AiId.parse(_aiValue),
        audio: const [1],
      );
      expect(result.isOk, isTrue);
      expect(result.value.degraded, isTrue);
      expect(result.value.transcript, isNull);
    });
  });
}
