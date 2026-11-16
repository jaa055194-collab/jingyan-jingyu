/// 语音模块（M08）。
///
/// 装配并登记三个宿主服务：[VoiceProfiles]、[VoiceGateway]、[CallService]。
///
/// 本切片只做宿主内核：真实 TTS/ASR 厂商适配器、客户端 UI、音频处理、
/// HTTP 路由与 `defaultModules` 装配都留待后续（路由需先加入 `Routes` 常量，
/// 见交付报告建议）。因此 [mount] 暂不声明路由，避免绕过路由常量约束。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'calls.dart';
import 'voice_gateway.dart';
import 'voice_profiles.dart';

/// 语音宿主模块。
class VoiceModule extends HostModule {
  VoiceModule._({
    required this.profiles,
    required this.gateway,
    required this.calls,
    required Duration sweepInterval,
  }) : _sweepInterval = sweepInterval;

  factory VoiceModule({
    VoiceProfiles? profiles,
    VoiceGateway? gateway,
    CallService? calls,
    Clock clock = const SystemClock(),
    TtsAdapter? tts,
    AsrAdapter? asr,
    Duration sweepInterval = const Duration(seconds: 1),
  }) {
    final resolvedProfiles = profiles ?? InMemoryVoiceProfiles(clock: clock);
    return VoiceModule._(
      profiles: resolvedProfiles,
      gateway: gateway ??
          VoiceGateway(
            profiles: resolvedProfiles,
            tts: tts ?? const UnavailableTtsAdapter(),
            asr: asr ?? const UnavailableAsrAdapter(),
            clock: clock,
          ),
      calls: calls ?? InMemoryCallService(clock: clock),
      sweepInterval: sweepInterval,
    );
  }

  final VoiceProfiles profiles;
  final VoiceGateway gateway;
  final CallService calls;

  final Duration _sweepInterval;
  Timer? _sweepTimer;

  @override
  String get name => 'voice';

  @override
  List<String> get dependsOn => const <String>['models'];

  @override
  Future<void> configure(HostServices services) async {
    services.provide<VoiceProfiles>(profiles, owner: name);
    services.provide<VoiceGateway>(gateway, owner: name);
    services.provide<CallService>(calls, owner: name);
  }

  @override
  Future<void> start() async {
    if (_sweepInterval <= Duration.zero) return;
    _sweepTimer = Timer.periodic(_sweepInterval, (_) async {
      try {
        await calls.sweepMissed();
      } catch (_) {
        // 下一 tick 重试；扫描失败不能拖垮宿主。
      }
    });
  }

  @override
  Future<void> stop() async {
    _sweepTimer?.cancel();
    _sweepTimer = null;
  }
}
