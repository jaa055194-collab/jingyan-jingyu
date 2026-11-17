import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/voice/doubao_tts_adapter.dart';
import 'package:jingyu_host/src/voice/doubao_ws_protocol.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:test/test.dart';

Uint8List _i32(int value) {
  final data = ByteData(4)..setInt32(0, value, Endian.big);
  return data.buffer.asUint8List();
}

/// Independently built server-side full-response frame (known openspeech layout).
Uint8List _serverEvent(
  int eventType, {
  String sessionId = '',
  Map<String, Object?> payload = const {},
}) {
  final body = utf8.encode(jsonEncode(payload));
  final sid = utf8.encode(sessionId);
  final buffer = BytesBuilder()
    ..addByte(0x11)
    ..addByte((DoubaoMessageType.fullServerResponse << 4) | 0x1)
    ..addByte(0x10)
    ..addByte(0)
    ..add(_i32(eventType))
    ..add(_i32(sid.length))
    ..add(sid)
    ..add(_i32(body.length))
    ..add(body);
  return buffer.takeBytes();
}

Uint8List _serverAudio(List<int> audio) {
  final buffer = BytesBuilder()
    ..addByte(0x11)
    ..addByte(DoubaoMessageType.audioOnlyResponse << 4)
    ..addByte(0x10)
    ..addByte(0)
    ..add(_i32(audio.length))
    ..add(audio);
  return buffer.takeBytes();
}

class _Recv {
  _Recv(this.headers, this.frame);
  final Map<String, String> headers;
  final DoubaoFrame frame;
}

class _FakeDoubaoServer {
  late HttpServer server;
  final List<_Recv> received = <_Recv>[];
  final List<Map<String, String>> handshakes = <Map<String, String>>[];
  int connections = 0;
  int? failSessionEvent; // e.g. DoubaoEvent.sessionFailed

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final headers = <String, String>{};
      request.headers.forEach(
        (name, values) => headers[name.toLowerCase()] = values.join(','),
      );
      final socket = await WebSocketTransformer.upgrade(request);
      connections++;
      handshakes.add(headers);
      socket.listen((data) {
        if (data is! List<int>) return;
        final frame = DoubaoBinaryProtocol.decodeFrame(
          Uint8List.fromList(data),
        );
        received.add(_Recv(headers, frame));
        switch (frame.eventType) {
          case DoubaoEvent.startConnection:
            socket.add(
              _serverEvent(DoubaoEvent.connectionStarted, payload: {}),
            );
          case DoubaoEvent.startSession:
            if (failSessionEvent != null) {
              socket.add(
                _serverEvent(
                  failSessionEvent!,
                  sessionId: frame.sessionId,
                  payload: {},
                ),
              );
            } else {
              socket.add(
                _serverEvent(
                  DoubaoEvent.sessionStarted,
                  sessionId: frame.sessionId,
                  payload: {},
                ),
              );
            }
          case DoubaoEvent.taskRequest:
            socket.add(
              _serverEvent(
                DoubaoEvent.ttsSentenceStart,
                sessionId: frame.sessionId,
                payload: {},
              ),
            );
            socket.add(_serverAudio(const [1, 2, 3, 4]));
            socket.add(
              _serverEvent(
                DoubaoEvent.ttsSentenceEnd,
                sessionId: frame.sessionId,
                payload: {},
              ),
            );
            socket.add(
              _serverEvent(
                DoubaoEvent.sessionFinished,
                sessionId: frame.sessionId,
                payload: {
                  'usage': {'text_words': 4},
                },
              ),
            );
          case DoubaoEvent.finishConnection:
            socket.add(
              _serverEvent(DoubaoEvent.connectionFinished, payload: {}),
            );
        }
      });
    });
  }

  String get endpoint => 'ws://127.0.0.1:${server.port}/api/v3/tts/bidirection';
  Future<void> close() => server.close(force: true);
}

DoubaoVoiceConfig _config(
  _FakeDoubaoServer server, {
  String token = 'local-secret-token',
  String cluster = 'seed-tts-2.0',
  String appid = 'app-1',
}) => DoubaoVoiceConfig(
  appid: appid,
  cluster: cluster,
  endpoint: server.endpoint,
  token: token,
);

void main() {
  late _FakeDoubaoServer server;

  setUp(() async {
    server = _FakeDoubaoServer();
    await server.start();
  });
  tearDown(() => server.close());

  test('binary frame layout matches known openspeech convention', () {
    final bytes = DoubaoBinaryProtocol.encodeClientEvent(
      messageType: DoubaoMessageType.fullClientRequest,
      eventType: DoubaoEvent.startConnection,
      sessionId: '',
      payload: const {},
    );
    expect(bytes[0], 0x11); // version 1, header 1 word
    expect(bytes[1] >> 4, DoubaoMessageType.fullClientRequest);
    expect(bytes[1] & 0x0F, 0x1); // has event
    expect(bytes[2] >> 4, 0x1); // JSON, no compression
    final data = ByteData.sublistView(bytes);
    var offset = 4;
    expect(data.getInt32(offset), DoubaoEvent.startConnection);
    offset += 4;
    expect(data.getInt32(offset), 0); // empty session id
    offset += 4;
    final length = data.getInt32(offset);
    offset += 4;
    expect(utf8.decode(bytes.sublist(offset, offset + length)), '{}');
    final decoded = DoubaoBinaryProtocol.decodeFrame(bytes);
    expect(decoded.eventType, DoubaoEvent.startConnection);
  });

  test('completes streaming handshake, events and collects audio', () async {
    final adapter = DoubaoWebSocketTtsAdapter(config: _config(server));
    final result = await adapter.synthesize(
      provider: 'doubao',
      model: 'seed-tts-2.0',
      voiceId: 'speaker-1',
      text: '你好世界',
      params: const {'format': 'pcm', 'sample_rate': 16000, 'speech_rate': 20},
    );
    expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    expect(result.value.ref, isNotEmpty);
    expect(adapter.vendorKey, isEmpty);

    final handshake = server.handshakes.single;
    expect(handshake['x-api-key'], 'local-secret-token');
    expect(handshake['x-api-resource-id'], 'seed-tts-2.0');
    expect(handshake['x-api-app-id'], 'app-1');
    expect(handshake['x-api-connect-id'], isNotEmpty);

    final events = server.received.map((r) => r.frame.eventType).toList();
    expect(
      events,
      containsAllInOrder([
        DoubaoEvent.startConnection,
        DoubaoEvent.startSession,
        DoubaoEvent.taskRequest,
        DoubaoEvent.finishSession,
        DoubaoEvent.finishConnection,
      ]),
    );
    final startSession = server.received
        .firstWhere((r) => r.frame.eventType == DoubaoEvent.startSession)
        .frame
        .payloadJson();
    final req = startSession['req_params']! as Map;
    expect(req['speaker'], 'speaker-1');
    expect(req['model'], 'seed-tts-2.0');
    final audioParams = req['audio_params']! as Map;
    expect(audioParams['format'], 'pcm');
    expect(audioParams['sample_rate'], 16000);
    expect(audioParams['speech_rate'], 20);
    final task = server.received
        .firstWhere((r) => r.frame.eventType == DoubaoEvent.taskRequest)
        .frame
        .payloadJson();
    expect(((task['req_params']! as Map)['text']), '你好世界');
  });

  test(
    'session failure event maps to safe modelUnavailable without leaking token',
    () async {
      server.failSessionEvent = DoubaoEvent.sessionFailed;
      final adapter = DoubaoWebSocketTtsAdapter(
        config: _config(server, token: 'top-secret-token'),
      );
      final result = await adapter.synthesize(
        provider: 'doubao',
        model: 'seed-tts-2.0',
        voiceId: 'speaker-1',
        text: 'hi',
        params: const {},
      );
      expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
      expect(result.toString().contains('top-secret-token'), isFalse);
      expect(
        result.failureOrNull!.details.toString().contains('top-secret-token'),
        isFalse,
      );
      expect(
        jsonEncode(server.handshakes).contains('top-secret-token'),
        isTrue,
        reason: 'handshake carries token on the wire but never in app errors',
      );
    },
  );

  test('unreachable endpoint maps to modelUnavailable', () async {
    final adapter = DoubaoWebSocketTtsAdapter(
      config: const DoubaoVoiceConfig(
        appid: 'a',
        cluster: 'seed-tts-2.0',
        endpoint: 'ws://127.0.0.1:1/api/v3/tts/bidirection',
        token: 'k',
      ),
      timeout: const Duration(seconds: 2),
    );
    final result = await adapter.synthesize(
      provider: 'doubao',
      model: 'seed-tts-2.0',
      voiceId: 'speaker-1',
      text: 'hi',
      params: const {},
    );
    expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
  });

  test('missing token or cluster fails closed without connecting', () async {
    for (final config in [
      _config(server, token: ''),
      _config(server, cluster: ''),
    ]) {
      final adapter = DoubaoWebSocketTtsAdapter(config: config);
      final result = await adapter.synthesize(
        provider: 'doubao',
        model: 'seed-tts-2.0',
        voiceId: 'speaker-1',
        text: 'hi',
        params: const {},
      );
      expect(result.failureOrNull?.code, FailureCode.modelUnavailable);
    }
    expect(server.connections, 0);
  });

  test('environment placeholders resolve without baking defaults', () {
    final empty = DoubaoVoiceConfig.fromEnvironment(const {});
    expect(empty.appid, isEmpty);
    expect(empty.cluster, isEmpty);
    expect(empty.token, isEmpty);
    expect(empty.endpoint, isNotEmpty); // documented WSS endpoint, not a secret
    expect(empty.isConfigured, isFalse);
    final full = DoubaoVoiceConfig.fromEnvironment(const {
      'DOUBAO_TTS_APPID': 'a',
      'DOUBAO_TTS_CLUSTER': 'seed-tts-2.0',
      'DOUBAO_TTS_ENDPOINT': 'wss://example.invalid/api/v3/tts/bidirection',
      'DOUBAO_TTS_TOKEN': 't',
    });
    expect(full.isConfigured, isTrue);
    expect(full.token, 't');
  });

  test(
    'VoiceGateway speaks with bound voice and degrades keeping voice_id',
    () async {
      final clock = FakeClock(DateTime.utc(2026, 1, 1));
      final profiles = InMemoryVoiceProfiles(clock: clock);
      await profiles.create(
        ai: AiId.parse('ai1'),
        provider: 'doubao',
        model: 'seed-tts-2.0',
        voiceId: 'speaker-1',
        consentRef: 'consent-1',
        grantedBy: 'owner',
      );
      final okGateway = VoiceGateway(
        profiles: profiles,
        tts: DoubaoWebSocketTtsAdapter(config: _config(server)),
        asr: FakeAsrAdapter(),
        clock: clock,
      );
      final spoken = await okGateway.speak(ai: AiId.parse('ai1'), text: '你好');
      expect(spoken.value.spoken, isTrue);
      expect(spoken.value.voiceId, 'speaker-1');
      expect(spoken.value.provider, 'doubao');

      server.failSessionEvent = DoubaoEvent.sessionFailed;
      final failGateway = VoiceGateway(
        profiles: profiles,
        tts: DoubaoWebSocketTtsAdapter(config: _config(server)),
        asr: FakeAsrAdapter(),
        clock: clock,
      );
      final degraded = await failGateway.speak(
        ai: AiId.parse('ai1'),
        text: '你好',
      );
      expect(degraded.isOk, isTrue);
      expect(degraded.value.spoken, isFalse);
      expect(degraded.value.degraded, isTrue);
      expect(degraded.value.voiceId, 'speaker-1');
      expect(degraded.value.provider, 'doubao');
      expect(
        (await profiles.get(ai: AiId.parse('ai1'))).value.voiceId,
        'speaker-1',
      );
    },
  );
}
