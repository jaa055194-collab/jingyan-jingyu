/// 豆包（火山引擎）双向流式 TTS WebSocket 适配器（M08，FR-30/31、NFR-06）。
///
/// 实现现有 [TtsAdapter]。配置项 appid/cluster/endpoint/token 全部来自环境变量
/// 占位（DOUBAO_TTS_APPID/CLUSTER/ENDPOINT/TOKEN），**绝不写死或记录密钥**。
/// 缺配置时 `isConfigured=false`，调用直接返回 modelUnavailable 且不建连，不阻塞
/// 编译/装配。失败经 [VoiceGateway] 只降文字，绝不换音色/跨厂商。
///
/// 注意：二进制帧布局按 openspeech v3 的已知约定实现（见 doubao_ws_protocol.dart），
/// 文档缺少官方帧布局附件，**真实豆包联调需待附件/参数补齐后才能确认**；本切片
/// 不声称已与真实豆包连通。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import 'doubao_ws_protocol.dart';
import 'voice_gateway.dart';

/// 建立 WebSocket 的可信注入点（默认 dart:io WebSocket；测试注入本地假服务器）。
typedef DoubaoWsConnector =
    Future<WebSocket> Function(Uri uri, {Map<String, String> headers});

Future<WebSocket> _defaultConnect(
  Uri uri, {
  Map<String, String> headers = const {},
}) => WebSocket.connect(uri.toString(), headers: headers);

/// 豆包 TTS 配置。全部由环境变量占位注入，不含任何写死密钥。
class DoubaoVoiceConfig {
  const DoubaoVoiceConfig({
    required this.appid,
    required this.cluster,
    required this.endpoint,
    required this.token,
  });

  final String appid;
  final String cluster;
  final String endpoint;
  final String token;

  static const String defaultEndpoint =
      'wss://openspeech.bytedance.com/api/v3/tts/bidirection';

  /// token + cluster + endpoint 齐备才可发起真实请求；appid 可选。
  bool get isConfigured =>
      token.isNotEmpty && cluster.isNotEmpty && endpoint.isNotEmpty;

  factory DoubaoVoiceConfig.fromEnvironment(Map<String, String> env) =>
      DoubaoVoiceConfig(
        appid: env['DOUBAO_TTS_APPID'] ?? '',
        cluster: env['DOUBAO_TTS_CLUSTER'] ?? '',
        endpoint: env['DOUBAO_TTS_ENDPOINT'] ?? defaultEndpoint,
        token: env['DOUBAO_TTS_TOKEN'] ?? '',
      );
}

/// 豆包双向流式 WebSocket TTS 适配器。
class DoubaoWebSocketTtsAdapter implements TtsAdapter {
  DoubaoWebSocketTtsAdapter({
    required this.config,
    DoubaoWsConnector? connect,
    Duration timeout = const Duration(seconds: 10),
  }) : _connect = connect ?? _defaultConnect,
       _timeout = timeout;

  final DoubaoVoiceConfig config;
  final DoubaoWsConnector _connect;
  final Duration _timeout;
  static final _random = Random.secure();

  /// 真实适配器不暴露任何密钥。
  @override
  String get vendorKey => '';

  @override
  Future<Result<SpeechArtifact>> synthesize({
    required String provider,
    required String model,
    required String voiceId,
    required String text,
    required Map<String, Object?> params,
  }) async {
    if (!config.isConfigured) {
      return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 未配置');
    }
    if (voiceId.trim().isEmpty || text.trim().isEmpty) {
      return err<SpeechArtifact>(FailureCode.invalidArgument, '豆包 TTS 参数不完整');
    }
    final endpoint = Uri.tryParse(config.endpoint);
    if (endpoint == null ||
        (endpoint.scheme != 'ws' && endpoint.scheme != 'wss') ||
        endpoint.host.isEmpty) {
      return err<SpeechArtifact>(FailureCode.forbidden, '豆包 TTS 接入点无效');
    }
    // Header 只在内存构造；任何错误/日志都不包含 token 或 headers。
    final headers = <String, String>{
      'X-Api-Key': config.token,
      'X-Api-Resource-Id': config.cluster,
      'X-Api-Connect-Id': _id(),
      'X-Control-Require-Usage-Tokens-Return': '*',
      if (config.appid.isNotEmpty) 'X-Api-App-ID': config.appid,
    };
    WebSocket socket;
    try {
      socket = await _connect(endpoint, headers: headers).timeout(_timeout);
    } catch (_) {
      return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 连接失败');
    }
    try {
      return await _exchange(
        socket,
        sessionId: _id(),
        voiceId: voiceId,
        model: model,
        text: text,
        audioParams: _audioParams(params),
      ).timeout(_timeout);
    } on TimeoutException {
      return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 超时');
    } catch (_) {
      return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 失败');
    } finally {
      try {
        await socket.close();
      } catch (_) {}
    }
  }

  Future<Result<SpeechArtifact>> _exchange(
    WebSocket socket, {
    required String sessionId,
    required String voiceId,
    required String model,
    required String text,
    required Map<String, Object?> audioParams,
  }) async {
    final iterator = StreamIterator<dynamic>(socket);
    try {
      socket.add(
        DoubaoBinaryProtocol.encodeClientEvent(
          messageType: DoubaoMessageType.fullClientRequest,
          eventType: DoubaoEvent.startConnection,
          sessionId: '',
          payload: const {},
        ),
      );
      if (!await _awaitControl(iterator, DoubaoEvent.connectionStarted)) {
        return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 建连失败');
      }
      socket.add(
        DoubaoBinaryProtocol.encodeClientEvent(
          messageType: DoubaoMessageType.fullClientRequest,
          eventType: DoubaoEvent.startSession,
          sessionId: sessionId,
          payload: {
            'req_params': {
              'speaker': voiceId,
              if (model.trim().isNotEmpty) 'model': model,
              'audio_params': audioParams,
            },
          },
        ),
      );
      if (!await _awaitControl(iterator, DoubaoEvent.sessionStarted)) {
        return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 会话失败');
      }
      socket.add(
        DoubaoBinaryProtocol.encodeClientEvent(
          messageType: DoubaoMessageType.fullClientRequest,
          eventType: DoubaoEvent.taskRequest,
          sessionId: sessionId,
          payload: {
            'req_params': {'text': text},
          },
        ),
      );
      socket.add(
        DoubaoBinaryProtocol.encodeClientEvent(
          messageType: DoubaoMessageType.fullClientRequest,
          eventType: DoubaoEvent.finishSession,
          sessionId: sessionId,
          payload: const {},
        ),
      );
      final audio = BytesBuilder(copy: false);
      while (await iterator.moveNext()) {
        final frame = _frame(iterator.current);
        if (frame == null) continue;
        if (frame.isError) {
          return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 失败');
        }
        if (frame.isAudio) {
          audio.add(frame.payload);
          continue;
        }
        if (frame.isFullResponse) {
          if (frame.eventType == DoubaoEvent.sessionFailed ||
              frame.eventType == DoubaoEvent.connectionFailed ||
              frame.eventType == DoubaoEvent.sessionCanceled) {
            return err<SpeechArtifact>(
              FailureCode.modelUnavailable,
              '豆包 TTS 失败',
            );
          }
          if (frame.eventType == DoubaoEvent.sessionFinished) break;
        }
      }
      try {
        socket.add(
          DoubaoBinaryProtocol.encodeClientEvent(
            messageType: DoubaoMessageType.fullClientRequest,
            eventType: DoubaoEvent.finishConnection,
            sessionId: '',
            payload: const {},
          ),
        );
      } catch (_) {}
      final bytes = audio.takeBytes();
      if (bytes.isEmpty) {
        return err<SpeechArtifact>(FailureCode.modelUnavailable, '豆包 TTS 无音频');
      }
      final digest = sha256.convert(bytes).toString();
      return Ok<SpeechArtifact>(
        SpeechArtifact(
          ref: 'doubao-tts:${digest.substring(0, 24)}',
          duration: Duration.zero,
        ),
      );
    } finally {
      await iterator.cancel();
    }
  }

  Future<bool> _awaitControl(
    StreamIterator<dynamic> iterator,
    int expected,
  ) async {
    while (await iterator.moveNext()) {
      final frame = _frame(iterator.current);
      if (frame == null) continue;
      if (frame.isError) return false;
      if (frame.isFullResponse) {
        if (frame.eventType == DoubaoEvent.connectionFailed ||
            frame.eventType == DoubaoEvent.sessionFailed) {
          return false;
        }
        if (frame.eventType == expected) return true;
      }
    }
    return false;
  }

  DoubaoFrame? _frame(dynamic raw) {
    if (raw is List<int>) {
      return DoubaoBinaryProtocol.decodeFrame(Uint8List.fromList(raw));
    }
    return null;
  }

  Map<String, Object?> _audioParams(Map<String, Object?> params) {
    const formats = {'mp3', 'pcm', 'ogg_opus', 'wav'};
    const rates = {8000, 16000, 22050, 24000, 32000, 44100, 48000};
    final format = params['format'];
    final sampleRate = params['sample_rate'];
    final result = <String, Object?>{
      'format': format is String && formats.contains(format) ? format : 'mp3',
      'sample_rate': sampleRate is int && rates.contains(sampleRate)
          ? sampleRate
          : 24000,
    };
    for (final key in const ['bit_rate', 'speech_rate', 'loudness_rate']) {
      final value = params[key];
      if (value is int) result[key] = value;
    }
    return result;
  }

  String _id() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}
