/// 已合并切片（PR#68 语音 vendor 适配器、PR#69 avatar/Live2D 契约）的验收回归。
///
/// 全部使用**注入的假 transport**，不建立真实 socket、不连接任何厂商、不使用任何
/// 真实凭据：只验证适配器/注册表的边界契约与降级语义，属于离线可跑的回归证据，
/// 不代表“真实厂商已联通”。
library;

import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/security/guarded_http.dart';
import 'package:jingyu_host/src/voice/openai_voice_adapter.dart';
import 'package:jingyu_host/src/voice/voice_gateway.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:test/test.dart';

/// 记录一次交给适配器的受控请求；从不发起真实网络。
class _Captured {
  _Captured(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final Map<String, String> headers;
  final List<int>? body;
}

class _Recorder {
  _Recorder(this.responder);
  final Future<Result<GuardedResponse>> Function(_Captured request) responder;
  final List<_Captured> calls = <_Captured>[];

  Future<Result<GuardedResponse>> transport(
    String method,
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
    List<int>? body,
  }) async {
    final captured = _Captured(method, uri, headers, body);
    calls.add(captured);
    return responder(captured);
  }
}

Future<Result<GuardedResponse>> _okJson(Map<String, Object?> json) async =>
    Ok<GuardedResponse>(
      GuardedResponse(
        statusCode: 200,
        headers: <String, List<String>>{
          'content-type': <String>['application/json'],
        },
        body: utf8.encode(jsonEncode(json)),
      ),
    );

Future<Result<GuardedResponse>> _okAudio(List<int> bytes) async =>
    Ok<GuardedResponse>(
      GuardedResponse(
        statusCode: 200,
        headers: <String, List<String>>{
          'content-type': <String>['audio/mpeg'],
        },
        body: bytes,
      ),
    );

VoiceVendorConfigResolver _config(String baseUrl, String apiKey) =>
    (_) async => Ok<VoiceVendorConfig>(
      VoiceVendorConfig(baseUrl: baseUrl, apiKey: apiKey),
    );

void main() {
  // 合成、非真实凭据；仅用于证明它不会出现在错误/结果/请求体里。
  const vendorSecret = 'sk-synthetic-vendor-secret';

  group('AC-11/13 语音 vendor 适配器验收回归（假 transport，无真实厂商）', () {
    test('TTS 走 /audio/speech，参数正确，客户端不可见 vendor key', () async {
      final recorder = _Recorder((_) => _okAudio(<int>[1, 2, 3, 4]));
      final adapter = OpenAiCompatibleTtsAdapter(
        request: recorder.transport,
        resolveConfig: _config('https://vendor.example/v1', vendorSecret),
      );

      final result = await adapter.synthesize(
        provider: 'openai',
        model: 'tts-1',
        voiceId: 'v-100',
        text: '你好，世界',
        params: const <String, Object?>{
          'response_format': 'mp3',
          'speed': 1.25,
        },
      );

      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.ref, startsWith('vendor-tts:'));
      expect(adapter.vendorKey, isEmpty);
      expect(result.toString().contains(vendorSecret), isFalse);

      final call = recorder.calls.single;
      expect(call.method, 'POST');
      expect(call.uri.path, '/v1/audio/speech');
      expect(call.headers['authorization'], 'Bearer $vendorSecret');
      final payload =
          jsonDecode(utf8.decode(call.body!)) as Map<String, Object?>;
      expect(payload['model'], 'tts-1');
      expect(payload['voice'], 'v-100');
      expect(payload['input'], '你好，世界');
      expect(payload['response_format'], 'mp3');
      expect(payload['speed'], 1.25);
    });

    test('ASR 走 /audio/transcriptions，音频在 body，key 只在 header', () async {
      final recorder = _Recorder(
        (_) => _okJson(<String, Object?>{'text': 'hello world'}),
      );
      final adapter = OpenAiCompatibleAsrAdapter(
        request: recorder.transport,
        resolveConfig: _config('https://vendor.example/v1', vendorSecret),
        provider: 'openai',
        model: 'whisper-1',
      );

      final result = await adapter.transcribe(audio: const <int>[9, 8, 7, 6]);

      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      expect(result.value.text, 'hello world');
      expect(result.toString().contains(vendorSecret), isFalse);

      final call = recorder.calls.single;
      expect(call.uri.path, '/v1/audio/transcriptions');
      expect(call.headers['authorization'], 'Bearer $vendorSecret');
      final bodyText = latin1.decode(call.body!);
      expect(bodyText.contains('whisper-1'), isTrue);
      expect(bodyText.contains('filename="audio.m4a"'), isTrue);
      // 凭据只在 header，绝不在正文。
      expect(bodyText.contains(vendorSecret), isFalse);
      expect(call.body!, containsAllInOrder(const <int>[9, 8, 7, 6]));
    });

    test(
      'transport 失败降级：TTS→modelUnavailable、ASR→unavailable，无 key 泄漏',
      () async {
        Future<Result<GuardedResponse>> down(_Captured _) async =>
            err<GuardedResponse>(FailureCode.unavailable, 'down');

        final tts =
            await OpenAiCompatibleTtsAdapter(
              request: _Recorder(down).transport,
              resolveConfig: _config('https://vendor.example/v1', vendorSecret),
            ).synthesize(
              provider: 'openai',
              model: 'tts-1',
              voiceId: 'v-100',
              text: 'hi',
              params: const <String, Object?>{},
            );
        expect(tts.failureOrNull?.code, FailureCode.modelUnavailable);
        expect(tts.toString().contains(vendorSecret), isFalse);

        final asr = await OpenAiCompatibleAsrAdapter(
          request: _Recorder(down).transport,
          resolveConfig: _config('https://vendor.example/v1', vendorSecret),
          provider: 'openai',
          model: 'whisper-1',
        ).transcribe(audio: const <int>[1, 2]);
        expect(asr.failureOrNull?.code, FailureCode.unavailable);
        expect(asr.toString().contains(vendorSecret), isFalse);
      },
    );

    test('非法/带 query 的 base_url 直接 forbidden，零厂商请求', () async {
      for (final baseUrl in <String>[
        'https://vendor.example/v1?token=1',
        'https://vendor.example/v1#frag',
        'ftp://vendor.example/v1',
        'https://user@vendor.example/v1',
      ]) {
        final recorder = _Recorder((_) => _okAudio(<int>[1]));
        final result =
            await OpenAiCompatibleTtsAdapter(
              request: recorder.transport,
              resolveConfig: _config(baseUrl, vendorSecret),
            ).synthesize(
              provider: 'openai',
              model: 'tts-1',
              voiceId: 'v-100',
              text: 'hi',
              params: const <String, Object?>{},
            );
        expect(
          result.failureOrNull?.code,
          FailureCode.forbidden,
          reason: baseUrl,
        );
        expect(recorder.calls, isEmpty, reason: baseUrl);
      }
    });

    test('vendor 500：gateway 只降文字，voice_id/provider 不变（不换音色/厂商）', () async {
      final clock = FakeClock(DateTime.utc(2026, 11, 17));
      final profiles = InMemoryVoiceProfiles(clock: clock);
      final ai = AiId.parse('ai-voice-1');
      await profiles.create(
        ai: ai,
        provider: 'openai',
        model: 'tts-1',
        voiceId: 'v-bound',
        consentRef: 'consent-1',
        grantedBy: 'owner',
        params: const <String, Object?>{},
      );
      final recorder = _Recorder(
        (_) async => Ok<GuardedResponse>(
          GuardedResponse(
            statusCode: 500,
            headers: const <String, List<String>>{},
            body: const <int>[],
          ),
        ),
      );
      final gateway = VoiceGateway(
        profiles: profiles,
        tts: OpenAiCompatibleTtsAdapter(
          request: recorder.transport,
          resolveConfig: _config('https://vendor.example/v1', vendorSecret),
        ),
        asr: FakeAsrAdapter(),
        clock: clock,
      );

      final result = await gateway.speak(ai: ai, text: '你好');

      expect(result.isOk, isTrue);
      expect(result.value.spoken, isFalse);
      expect(result.value.degraded, isTrue);
      expect(result.value.text, '你好');
      expect(result.value.voiceId, 'v-bound');
      expect(result.value.provider, 'openai');
      final payload =
          jsonDecode(utf8.decode(recorder.calls.single.body!))
              as Map<String, Object?>;
      expect(payload['voice'], 'v-bound');
      expect((await profiles.get(ai: ai)).value.voiceId, 'v-bound');
    });
  });

  group('AC-24/25 host AvatarRegistry 参考契约（VRM/Live2D，reference-only）', () {
    late InMemoryAvatarRegistry registry;
    setUp(() {
      registry = InMemoryAvatarRegistry(
        clock: FakeClock(DateTime.utc(2026, 11, 17, 8)),
      );
    });

    test('VRM 与 Live2D 仅登记引用，无 paramMap/modelBytes', () async {
      final vrm = (await registry.register(
        ownerId: 'owner-1',
        deviceId: 'phone',
        kind: AvatarKind.vrm,
        modelId: 'vrm_default',
      )).value;
      final live2d = (await registry.register(
        ownerId: 'owner-1',
        deviceId: 'phone',
        kind: AvatarKind.live2d,
        modelId: 'l2d_default',
      )).value;

      expect(vrm.kind, AvatarKind.vrm);
      expect(live2d.kind, AvatarKind.live2d);
      expect(live2d.profileRev, 1);
      final json = live2d.toJson();
      expect(json.keys, isNot(contains('paramMap')));
      expect(json.keys, isNot(contains('modelBytes')));
      expect((await registry.list('owner-1', 'phone')).length, 2);
    });

    test('按 (owner, device) 隔离，active 广播 modelId+profileRev 一致', () async {
      final phone = (await registry.register(
        ownerId: 'owner-1',
        deviceId: 'phone',
        kind: AvatarKind.live2d,
        modelId: 'l2d_phone',
      )).value;
      await registry.register(
        ownerId: 'owner-1',
        deviceId: 'pc',
        kind: AvatarKind.vrm,
        modelId: 'vrm_pc',
      );

      final enabled = (await registry.enable(
        ownerId: 'owner-1',
        deviceId: 'phone',
        avatarId: phone.avatarId,
        expectedRevision: phone.profileRev,
      )).value;
      expect(enabled.profileRev, phone.profileRev + 1);

      final broadcast = (await registry.active('owner-1', 'phone')).value;
      expect(broadcast.modelId, 'l2d_phone');
      expect(broadcast.profileRev, enabled.profileRev);
      expect(broadcast.kind, AvatarKind.live2d);

      // 同 owner 的 PC 仍是独立设备状态，没有 active。
      expect(
        (await registry.active('owner-1', 'pc')).failureOrNull?.code,
        FailureCode.notFound,
      );
      // 其他 owner / 其他设备看不到手机的形象。
      expect(
        (await registry.get(
          ownerId: 'owner-2',
          deviceId: 'phone',
          avatarId: phone.avatarId,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await registry.get(
          ownerId: 'owner-1',
          deviceId: 'tablet',
          avatarId: phone.avatarId,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
    });

    test('跨设备 enable 返回 notFound，不跨设备激活', () async {
      final phone = (await registry.register(
        ownerId: 'owner-1',
        deviceId: 'phone',
        kind: AvatarKind.live2d,
        modelId: 'l2d_phone',
      )).value;
      final crossDevice = await registry.enable(
        ownerId: 'owner-1',
        deviceId: 'pc',
        avatarId: phone.avatarId,
        expectedRevision: phone.profileRev,
      );
      expect(crossDevice.failureOrNull?.code, FailureCode.notFound);
    });

    test('disable 前进 revision 并清除 active', () async {
      final profile = (await registry.register(
        ownerId: 'owner-1',
        deviceId: 'phone',
        kind: AvatarKind.vrm,
        modelId: 'vrm_default',
      )).value;
      final enabled = (await registry.enable(
        ownerId: 'owner-1',
        deviceId: 'phone',
        avatarId: profile.avatarId,
        expectedRevision: profile.profileRev,
      )).value;
      final disabled = (await registry.disable(
        ownerId: 'owner-1',
        deviceId: 'phone',
        avatarId: profile.avatarId,
        expectedRevision: enabled.profileRev,
      )).value;
      expect(disabled.profileRev, enabled.profileRev + 1);
      expect(
        (await registry.active('owner-1', 'phone')).failureOrNull?.code,
        FailureCode.notFound,
      );
    });
  });
}
