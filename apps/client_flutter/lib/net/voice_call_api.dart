/// 客户端语音通话只读 API（M08 客户端侧）。
///
/// 仅消费宿主已合并的 `GET Routes.voiceCall`（按 callId 读取一通通话的状态快照）。
/// **没有**通话列表读路由：宿主只暴露创建/应答/结束/打断等写路由，客户端不编造
/// 列表；读取单通需显式提供 callId。DTO 仅含元数据（callId/aiId/peerAccountId/
/// state/时间戳），绝不包含音频、转写正文或厂商密钥。错误沿用 [HostConnection]
/// 有界 401 续期，不新增重试；不含 UI、模型配置或厂商调用。
library;

import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// 一通通话的只读快照（元数据；无音频/正文）。
class VoiceCallView {
  const VoiceCallView._({
    required this.callId,
    required this.aiId,
    required this.peerAccountId,
    required this.state,
    required this.startedAt,
    this.answeredAt,
    this.endedAt,
  });

  final String callId;
  final String aiId;
  final String peerAccountId;
  final String state;
  final DateTime startedAt;
  final DateTime? answeredAt;
  final DateTime? endedAt;

  static const _states = {'ringing', 'active', 'missed', 'ended'};

  factory VoiceCallView.fromJson(Map<String, Object?> json) {
    const requiredKeys = {
      'callId',
      'aiId',
      'peerAccountId',
      'state',
      'startedAt',
    };
    const optionalKeys = {'answeredAt', 'endedAt'};
    try {
      if (json.keys.any(
            (key) => !requiredKeys.contains(key) && !optionalKeys.contains(key),
          ) ||
          requiredKeys.any((key) => !json.containsKey(key))) {
        throw const FormatException();
      }
      final callId = json['callId'];
      final aiId = json['aiId'];
      final peer = json['peerAccountId'];
      final state = json['state'];
      final startedAt = DateTime.tryParse(json['startedAt'] as String? ?? '');
      if (callId is! String ||
          aiId is! String ||
          peer is! String ||
          state is! String ||
          !_states.contains(state) ||
          startedAt == null) {
        throw const FormatException();
      }
      validateId(callId, kind: 'call');
      AiId.parse(aiId);
      validateId(peer, kind: 'account');
      final answeredAt = _optionalTime(json, 'answeredAt');
      final endedAt = _optionalTime(json, 'endedAt');
      return VoiceCallView._(
        callId: callId,
        aiId: aiId,
        peerAccountId: peer,
        state: state,
        startedAt: startedAt,
        answeredAt: answeredAt,
        endedAt: endedAt,
      );
    } on FormatException {
      throw const FormatException('通话状态响应无效');
    }
  }

  static DateTime? _optionalTime(Map<String, Object?> json, String key) {
    final value = json[key];
    if (value == null) return null;
    final parsed = DateTime.tryParse(value as String? ?? '');
    if (parsed == null) throw const FormatException();
    return parsed;
  }
}

/// Read-only voice call metadata adapter.
class VoiceCallApi {
  VoiceCallApi(this.connection);
  final HostConnection connection;

  /// Reads one call's metadata by explicit call id. Read-only: this adapter
  /// never answers, ends or interrupts a call.
  Future<VoiceCallView> readCall(
    String callId, {
    bool retryAuthentication = true,
  }) async {
    String path;
    try {
      path = Routes.voiceCall.replaceAll(
        '{callId}',
        Uri.encodeComponent(validateId(callId, kind: 'call')),
      );
    } on FormatException {
      throw const FormatException('通话标识参数无效');
    }
    try {
      final json = await connection.request(
        'GET',
        path,
        retryAuthentication: retryAuthentication,
      );
      return VoiceCallView.fromJson(json);
    } on FormatException {
      throw const FormatException('通话状态响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }

  /// Owner-scoped call list: `GET /voice/calls` (same path as POST create).
  ///
  /// Contract (host PR #118): query is exactly `status`/`limit`/`before`; the
  /// response is `{calls:[...]}` of metadata-only snapshots (no audio, no
  /// transcript); owner scope and filtering happen on the host. [before] pages
  /// older items (exclusive cursor = oldest `startedAt` of the previous page).
  Future<List<VoiceCallView>> listCalls({
    String? status,
    int limit = 50,
    DateTime? before,
    bool retryAuthentication = true,
  }) async {
    if (limit < 1 || limit > 100) {
      throw const FormatException('通话列表分页参数无效');
    }
    const states = {'ringing', 'active', 'missed', 'ended'};
    final query = <String, String>{'limit': '$limit'};
    if (status != null) {
      if (!states.contains(status)) throw const FormatException('状态参数无效');
      query['status'] = status;
    }
    if (before != null) query['before'] = before.toUtc().toIso8601String();
    try {
      final json = await connection.request(
        'GET',
        // Same path as POST create; host #118 mounts GET on Routes.voiceCalls
        // (its `voiceCallList` alias carries the identical value).
        Routes.voiceCalls,
        query: query,
        retryAuthentication: retryAuthentication,
      );
      if (json.keys.any((key) => key != 'calls') || json['calls'] is! List) {
        throw const FormatException();
      }
      return [
        for (final item in json['calls']! as List)
          if (item is Map<String, dynamic>)
            VoiceCallView.fromJson(item.cast<String, Object?>())
          else
            throw const FormatException(),
      ];
    } on FormatException {
      throw const FormatException('通话列表响应无效');
    } on SocketException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on HttpException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    } on TimeoutException {
      throw const HostRequestException(
        Failure(FailureCode.unavailable, '宿主暂不可用'),
      );
    }
  }
}
