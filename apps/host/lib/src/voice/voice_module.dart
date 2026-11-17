/// 语音模块（M08）。
///
/// 装配并登记三个宿主服务：[VoiceProfiles]、[VoiceGateway]、[CallService]，
/// 并声明语音 HTTP 路由（音色档案读取、短期试听票据、1v1 通话生命周期）。
///
/// 真实 TTS/ASR 厂商适配器、客户端 UI 与音频处理不在本模块；装配处通过
/// [VoiceModule.persistent] 注入 SQLite 存储与真实适配器。
library;

import 'dart:async';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/database.dart';
import 'calls.dart';
import 'sqlite_calls.dart';
import 'sqlite_voice_profiles.dart';
import 'voice_gateway.dart';
import 'voice_ownership.dart';
import 'voice_profiles.dart';

/// 语音宿主模块。
class VoiceModule extends HostModule {
  VoiceModule._({
    required this.profiles,
    required this.gateway,
    required this.calls,
    required Duration sweepInterval,
    this.authenticate,
    this.ownership,
  }) : _sweepInterval = sweepInterval;

  factory VoiceModule({
    VoiceProfiles? profiles,
    VoiceGateway? gateway,
    CallService? calls,
    Clock clock = const SystemClock(),
    TtsAdapter? tts,
    AsrAdapter? asr,
    Duration sweepInterval = const Duration(seconds: 1),
    Authenticator? authenticate,
    VoiceOwnership? ownership,
  }) {
    final resolvedProfiles = profiles ?? InMemoryVoiceProfiles(clock: clock);
    return VoiceModule._(
      profiles: resolvedProfiles,
      gateway:
          gateway ??
          VoiceGateway(
            profiles: resolvedProfiles,
            tts: tts ?? const UnavailableTtsAdapter(),
            asr: asr ?? const UnavailableAsrAdapter(),
            clock: clock,
          ),
      calls: calls ?? InMemoryCallService(clock: clock),
      sweepInterval: sweepInterval,
      authenticate: authenticate,
      ownership: ownership,
    );
  }

  /// 装配准备：用 SQLite 存储版本构建模块（宿主装配时一行接入）。
  ///
  /// `database` 由 StorageModule 提供，且已应用 `voiceMigrations`（700–799）。
  factory VoiceModule.persistent({
    required Database database,
    Clock clock = const SystemClock(),
    TtsAdapter? tts,
    AsrAdapter? asr,
    Duration sweepInterval = const Duration(seconds: 1),
    Authenticator? authenticate,
    VoiceOwnership? ownership,
  }) {
    final resolvedProfiles = SqliteVoiceProfiles(
      database: database,
      clock: clock,
    );
    return VoiceModule._(
      profiles: resolvedProfiles,
      gateway: VoiceGateway(
        profiles: resolvedProfiles,
        tts: tts ?? const UnavailableTtsAdapter(),
        asr: asr ?? const UnavailableAsrAdapter(),
        clock: clock,
      ),
      calls: SqliteCallService(database: database, clock: clock),
      sweepInterval: sweepInterval,
      authenticate: authenticate,
      ownership: ownership ?? DatabaseVoiceOwnership(database),
    );
  }

  final VoiceProfiles profiles;
  final VoiceGateway gateway;
  final CallService calls;

  /// 可选的二次认证：核对 live bearer 与管线注入的 principal 一致。
  final Authenticator? authenticate;

  /// AI 归属判定；缺失时按 fail-closed 拒绝（404）。
  final VoiceOwnership? ownership;

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
  void mount(Router router) {
    router.get(Routes.aiVoiceProfile, _readProfile);
    router.post(Routes.aiVoiceTicket, _issueTicket);
    router.get(Routes.voiceCallList, _listCalls);
    router.post(Routes.voiceCalls, _createCall);
    router.get(Routes.voiceCall, _readCall);
    router.post(Routes.voiceCallAnswer, _answerCall);
    router.post(Routes.voiceCallEnd, _endCall);
    router.post(Routes.voiceCallInterrupt, _interruptCall);
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

  // ---- 路由辅助 ----

  HostResponse _unauthenticated() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'Authentication required'),
  );

  HostResponse _invalid() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'Invalid input'),
  );

  HostResponse _hidden() =>
      HostResponse.failure(const Failure(FailureCode.notFound, 'Not found'));

  bool _isEmptyBody(HostRequest request) {
    final body = request.body;
    if (body == null) return true;
    return body is Map && body.isEmpty;
  }

  Future<Principal?> _principal(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return null;
    final live = authenticate;
    if (live != null) {
      final current = await live(request);
      if (current == null ||
          current.accountId != principal.accountId ||
          current.deviceId != principal.deviceId) {
        return null;
      }
    }
    return principal;
  }

  Future<bool> _owns(AccountId owner, AiId ai) async {
    final gate = ownership;
    if (gate == null) return false;
    return gate.ownsAi(owner: owner, ai: ai);
  }

  Future<Result<CallSession>> _authorizeCall(
    HostRequest request,
    Principal principal,
  ) async {
    final String callId;
    try {
      callId = validateId(request.pathParams['callId'] ?? '', kind: 'call');
    } on FormatException {
      return err<CallSession>(FailureCode.invalidArgument, 'call_id 非法');
    }
    final got = await calls.get(callId: callId);
    if (got.isErr) {
      // 不存在与无权看统一 404，避免探测。
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    final owner = AccountId.parse(principal.accountId);
    if (!await _owns(owner, got.value.aiId)) {
      return err<CallSession>(FailureCode.notFound, '通话不存在');
    }
    return got;
  }

  Future<HostResponse> _readProfile(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    final AiId ai;
    final AccountId owner;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
      owner = AccountId.parse(principal.accountId);
    } on FormatException {
      return _invalid();
    }
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    if (!await _owns(owner, ai)) return _hidden();
    final result = await profiles.get(ai: ai);
    if (result.isErr) return _hidden();
    return HostResponse.ok(result.value.toJson());
  }

  Future<HostResponse> _issueTicket(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    final AiId ai;
    final AccountId owner;
    try {
      ai = AiId.parse(request.pathParams['aiId'] ?? '');
      owner = AccountId.parse(principal.accountId);
    } on FormatException {
      return _invalid();
    }
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    if (!await _owns(owner, ai)) return _hidden();
    final result = await gateway.issueTicket(
      ai: ai,
      ownerAccountId: owner.value,
    );
    if (result.isErr) return _hidden();
    return HostResponse.ok(result.value.toJson());
  }

  Future<HostResponse> _createCall(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (request.query.isNotEmpty) return _invalid();
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) return _invalid();
    final json = body.value;
    const fields = {'callId', 'aiId'};
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key))) {
      return _invalid();
    }
    final rawCallId = json['callId'];
    final rawAi = json['aiId'];
    if (rawCallId is! String || rawAi is! String) return _invalid();
    final String callId;
    final AiId ai;
    final AccountId owner;
    try {
      callId = validateId(rawCallId, kind: 'call');
      ai = AiId.parse(rawAi);
      owner = AccountId.parse(principal.accountId);
    } on FormatException {
      return _invalid();
    }
    if (!await _owns(owner, ai)) return _hidden();
    final result = await calls.start(
      callId: callId,
      ai: ai,
      peerAccountId: owner.value,
    );
    return HostResponse.fromResult(result, (session) => session.toJson());
  }

  /// 只读通话列表：仅返回当前账号发起的通话元数据（存储按 peer 过滤）。
  ///
  /// query 仅允许 `status`/`limit`/`before`；只读，不产生任何音频/转写，
  /// 也不做应答/结束等写操作。
  Future<HostResponse> _listCalls(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (!_isEmptyBody(request)) return _invalid();
    const allowed = {'status', 'limit', 'before'};
    if (request.query.keys.any((key) => !allowed.contains(key))) {
      return _invalid();
    }
    CallState? status;
    if (request.query.containsKey('status')) {
      final raw = request.query['status'];
      for (final value in CallState.values) {
        if (value.name == raw) status = value;
      }
      if (status == null) return _invalid();
    }
    var limit = 50;
    if (request.query.containsKey('limit')) {
      final parsed = int.tryParse(request.query['limit'] ?? '');
      if (parsed == null || parsed < 1 || parsed > 100) return _invalid();
      limit = parsed;
    }
    DateTime? before;
    if (request.query.containsKey('before')) {
      before = DateTime.tryParse(request.query['before'] ?? '');
      if (before == null) return _invalid();
    }
    final result = await calls.list(
      accountId: principal.accountId,
      status: status,
      before: before,
      limit: limit,
    );
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    return HostResponse.ok({
      'calls': [for (final session in result.value) session.toJson()],
    });
  }

  Future<HostResponse> _readCall(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    final authorized = await _authorizeCall(request, principal);
    if (authorized.isErr) {
      return HostResponse.failure(authorized.failureOrNull!);
    }
    return HostResponse.ok(authorized.value.toJson());
  }

  Future<HostResponse> _answerCall(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    final authorized = await _authorizeCall(request, principal);
    if (authorized.isErr) {
      return HostResponse.failure(authorized.failureOrNull!);
    }
    final result = await calls.answer(callId: authorized.value.callId);
    return HostResponse.fromResult(result, (session) => session.toJson());
  }

  Future<HostResponse> _endCall(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    final authorized = await _authorizeCall(request, principal);
    if (authorized.isErr) {
      return HostResponse.failure(authorized.failureOrNull!);
    }
    final result = await calls.end(callId: authorized.value.callId);
    return HostResponse.fromResult(result, (session) => session.toJson());
  }

  Future<HostResponse> _interruptCall(HostRequest request) async {
    final principal = await _principal(request);
    if (principal == null) return _unauthenticated();
    if (request.query.isNotEmpty || !_isEmptyBody(request)) return _invalid();
    final authorized = await _authorizeCall(request, principal);
    if (authorized.isErr) {
      return HostResponse.failure(authorized.failureOrNull!);
    }
    final result = await calls.interrupt(callId: authorized.value.callId);
    return HostResponse.fromResult(result, (outcome) => outcome.toJson());
  }
}
