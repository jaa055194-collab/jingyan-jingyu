/// OpenAI 兼容的真实 TTS/ASR 厂商适配器（M08，FR-30/31、NFR-06、AC-11/13）。
///
/// 只依赖注入的受控 HTTP 传输（生产为 `GuardedHttpTransport.request`）与按
/// provider 解析的凭据；**不写死任何 key**。客户端永不见 key：适配器不经任何
/// 响应/日志/错误暴露凭据，`vendorKey` 恒为空串。
///
/// 语义（由 [VoiceGateway] 兜底）：不做本地 TTS；失败只降文字，绝不换音色、
/// 不跨厂商。本切片不落盘音频、不做音频处理。
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../security/guarded_http.dart';
import 'voice_gateway.dart';

/// 与 [GuardedHttpTransport.request] 完全同形的受控传输回调。
///
/// 生产直接注入 `GuardedHttpTransport(...).request`；测试注入 loopback 假传输。
typedef VoiceGuardedRequest =
    Future<Result<GuardedResponse>> Function(
      String method,
      Uri uri, {
      Map<String, String> headers,
      List<int>? body,
    });

/// 按 provider 解析出的厂商接入点。key 只在宿主内存里存在。
class VoiceVendorConfig {
  const VoiceVendorConfig({required this.baseUrl, required this.apiKey});
  final String baseUrl;
  final String apiKey;
}

/// 按 provider 解析厂商配置；失败返回 Err 且不会发起请求。
typedef VoiceVendorConfigResolver =
    Future<Result<VoiceVendorConfig>> Function(String provider);

Uri? _endpoint(String baseUrl, String suffix) {
  final Uri base;
  try {
    base = Uri.parse(baseUrl);
  } on FormatException {
    return null;
  }
  if ((base.scheme != 'http' && base.scheme != 'https') ||
      base.host.isEmpty ||
      base.hasQuery ||
      base.hasFragment ||
      base.userInfo.isNotEmpty ||
      base.authority.contains('@')) {
    return null;
  }
  final trimmed = base.path.replaceFirst(RegExp(r'/+$'), '');
  return base.replace(path: '$trimmed$suffix');
}

/// OpenAI 兼容 `/v1/audio/speech` 合成适配器。
class OpenAiCompatibleTtsAdapter implements TtsAdapter {
  OpenAiCompatibleTtsAdapter({
    required VoiceGuardedRequest request,
    required VoiceVendorConfigResolver resolveConfig,
  }) : _request = request,
       _resolveConfig = resolveConfig;

  final VoiceGuardedRequest _request;
  final VoiceVendorConfigResolver _resolveConfig;

  /// 真实适配器不暴露任何 key；客户端票据因此不可能带上厂商凭据。
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
    if (provider.trim().isEmpty ||
        model.trim().isEmpty ||
        voiceId.trim().isEmpty ||
        text.trim().isEmpty) {
      return err<SpeechArtifact>(FailureCode.invalidArgument, 'TTS 参数不完整');
    }
    final resolved = await _resolveConfig(provider);
    if (resolved.isErr) {
      final failure = resolved.failureOrNull!;
      return err<SpeechArtifact>(failure.code, failure.message);
    }
    final config = resolved.value;
    final endpoint = _endpoint(config.baseUrl, '/audio/speech');
    if (endpoint == null) {
      return err<SpeechArtifact>(FailureCode.forbidden, 'TTS 接入点无效');
    }
    final payload = <String, Object?>{
      'model': model,
      'input': text,
      'voice': voiceId,
    };
    final format = params['response_format'];
    payload['response_format'] = (format is String && format.trim().isNotEmpty)
        ? format
        : 'mp3';
    final speed = params['speed'];
    if (speed is num && speed > 0) payload['speed'] = speed;
    final instructions = params['instructions'];
    if (instructions is String && instructions.trim().isNotEmpty) {
      payload['instructions'] = instructions;
    }

    final response = await _request(
      'POST',
      endpoint,
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer ${config.apiKey}',
      },
      body: utf8.encode(jsonEncode(payload)),
    );
    if (response.isErr) {
      final code = response.failureOrNull!.code == FailureCode.forbidden
          ? FailureCode.forbidden
          : FailureCode.modelUnavailable;
      return err<SpeechArtifact>(code, 'TTS 厂商请求失败');
    }
    final value = response.value;
    if (value.statusCode == 401 || value.statusCode == 403) {
      return err<SpeechArtifact>(FailureCode.forbidden, 'TTS 厂商授权失败');
    }
    if (value.statusCode == 429) {
      return err<SpeechArtifact>(FailureCode.rateLimited, 'TTS 厂商限流');
    }
    if (value.statusCode != 200 || value.body.isEmpty) {
      return err<SpeechArtifact>(FailureCode.modelUnavailable, 'TTS 厂商不可用');
    }
    // 本切片不落盘、不解析时长；用内容哈希做 opaque 句柄，未知时长如实记 0。
    final digest = sha256.convert(value.body).toString();
    return Ok<SpeechArtifact>(
      SpeechArtifact(
        ref: 'vendor-tts:${digest.substring(0, 24)}',
        duration: Duration.zero,
      ),
    );
  }
}

/// OpenAI 兼容 `/v1/audio/transcriptions` 转写适配器。
class OpenAiCompatibleAsrAdapter implements AsrAdapter {
  OpenAiCompatibleAsrAdapter({
    required VoiceGuardedRequest request,
    required VoiceVendorConfigResolver resolveConfig,
    required String provider,
    required String model,
  }) : _request = request,
       _resolveConfig = resolveConfig,
       _provider = provider,
       _model = model;

  final VoiceGuardedRequest _request;
  final VoiceVendorConfigResolver _resolveConfig;
  final String _provider;
  final String _model;
  static final _random = Random.secure();

  @override
  Future<Result<Transcript>> transcribe({required List<int> audio}) async {
    if (audio.isEmpty) {
      return err<Transcript>(FailureCode.invalidArgument, '音频为空');
    }
    final resolved = await _resolveConfig(_provider);
    if (resolved.isErr) {
      final failure = resolved.failureOrNull!;
      return err<Transcript>(failure.code, failure.message);
    }
    final config = resolved.value;
    final endpoint = _endpoint(config.baseUrl, '/audio/transcriptions');
    if (endpoint == null) {
      return err<Transcript>(FailureCode.forbidden, 'ASR 接入点无效');
    }
    final boundary =
        '----jingyu${_random.nextInt(1 << 32).toRadixString(16)}${_random.nextInt(1 << 32).toRadixString(16)}';
    final head = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="model"\r\n\r\n'
      '$_model\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="audio.m4a"\r\n'
      'Content-Type: audio/m4a\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$boundary--\r\n');
    final body = <int>[...head, ...audio, ...tail];

    final response = await _request(
      'POST',
      endpoint,
      headers: {
        'content-type': 'multipart/form-data; boundary=$boundary',
        'authorization': 'Bearer ${config.apiKey}',
      },
      body: body,
    );
    if (response.isErr) {
      final code = response.failureOrNull!.code == FailureCode.forbidden
          ? FailureCode.forbidden
          : FailureCode.unavailable;
      return err<Transcript>(code, 'ASR 厂商请求失败');
    }
    final value = response.value;
    if (value.statusCode == 401 || value.statusCode == 403) {
      return err<Transcript>(FailureCode.forbidden, 'ASR 厂商授权失败');
    }
    if (value.statusCode == 429) {
      return err<Transcript>(FailureCode.rateLimited, 'ASR 厂商限流');
    }
    if (value.statusCode != 200) {
      return err<Transcript>(FailureCode.unavailable, 'ASR 厂商不可用');
    }
    try {
      final decoded = jsonDecode(utf8.decode(value.body));
      if (decoded is Map<String, dynamic> && decoded['text'] is String) {
        return Ok<Transcript>(Transcript(text: decoded['text'] as String));
      }
    } catch (_) {
      // Fall through to a safe unavailable result.
    }
    return err<Transcript>(FailureCode.unavailable, 'ASR 响应无效');
  }
}
