/// 客户端语音只读 API（M08 客户端侧）。
///
/// 仅消费宿主已合并的语音路由：
/// * `GET Routes.aiVoiceProfile` 读取某 AI 的音色档案；
/// * `POST Routes.aiVoiceTicket` 签发 5 分钟短期会话票据（空 body）。
///
/// 严格 DTO：字段集合受限、类型/范围校验、响应 `aiId` 必须等于请求值；
/// 未知字段（例如误配 `apiKey`/`vendorKey`）一律拒绝，客户端绝不摄入或回显
/// 任何厂商 key。错误沿用 [HostConnection] 有界 401 续期，不新增重试；不含
/// UI、模型配置或厂商调用。
library;

import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

bool _label(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.trim() == value &&
    !_control.hasMatch(value);

Map<String, Object?> _map(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException();
  }
  return value.cast<String, Object?>();
}

/// 音色档案只读视图。字段与宿主 `VoiceProfile.toJson()` 对齐；不含厂商 key。
class VoiceProfileView {
  const VoiceProfileView._({
    required this.aiId,
    required this.provider,
    required this.model,
    required this.voiceId,
    required this.params,
    required this.revision,
    required this.consentRef,
    required this.activatedAt,
    this.pendingRevision,
    this.pendingParams,
  });

  final String aiId;
  final String provider;
  final String model;
  final String voiceId;
  final Map<String, Object?> params;
  final int revision;
  final String consentRef;
  final DateTime activatedAt;
  final int? pendingRevision;
  final Map<String, Object?>? pendingParams;

  factory VoiceProfileView.fromJson(
    Map<String, Object?> json, {
    required String expectedAiId,
  }) {
    try {
      const fields = {
        'aiId',
        'provider',
        'model',
        'voiceId',
        'params',
        'revision',
        'consentRef',
        'activatedAt',
        'pendingRevision',
        'pendingParams',
      };
      if (json.keys.any((key) => !fields.contains(key))) {
        throw const FormatException();
      }
      final aiId = json['aiId'];
      final revision = json['revision'];
      final activatedAt = json['activatedAt'];
      if (aiId is! String || aiId != expectedAiId) {
        throw const FormatException();
      }
      if (!_label(json['provider']) ||
          !_label(json['model']) ||
          !_label(json['voiceId']) ||
          !_label(json['consentRef'])) {
        throw const FormatException();
      }
      if (revision is! int || revision < 1) throw const FormatException();
      if (activatedAt is! String || DateTime.tryParse(activatedAt) == null) {
        throw const FormatException();
      }
      final params = _map(json['params']);
      final pendingRevision = json['pendingRevision'];
      final pendingParams = json['pendingParams'];
      if ((pendingRevision == null) != (pendingParams == null)) {
        throw const FormatException();
      }
      if (pendingRevision != null &&
          (pendingRevision is! int || pendingRevision < 1)) {
        throw const FormatException();
      }
      return VoiceProfileView._(
        aiId: aiId,
        provider: json['provider'] as String,
        model: json['model'] as String,
        voiceId: json['voiceId'] as String,
        params: params,
        revision: revision,
        consentRef: json['consentRef'] as String,
        activatedAt: DateTime.parse(activatedAt),
        pendingRevision: pendingRevision as int?,
        pendingParams: pendingParams == null ? null : _map(pendingParams),
      );
    } on FormatException {
      // Core ID/JSON parser errors may contain supplied source; keep it generic.
      throw const FormatException('音色档案响应无效');
    } on TypeError {
      throw const FormatException('音色档案响应无效');
    }
  }
}

/// 短期试听/合成会话票据视图。宿主只签发短期 opaque token，不含厂商 key。
class VoiceTicketView {
  const VoiceTicketView._({
    required this.token,
    required this.aiId,
    required this.expiresAt,
  });

  final String token;
  final String aiId;
  final DateTime expiresAt;

  factory VoiceTicketView.fromJson(
    Map<String, Object?> json, {
    required String expectedAiId,
  }) {
    try {
      const fields = {'token', 'aiId', 'expiresAt'};
      final token = json['token'];
      final aiId = json['aiId'];
      final expiresAt = json['expiresAt'];
      if (json.length != fields.length ||
          json.keys.any((key) => !fields.contains(key)) ||
          !_label(token) ||
          aiId is! String ||
          aiId != expectedAiId ||
          expiresAt is! String ||
          DateTime.tryParse(expiresAt) == null) {
        throw const FormatException();
      }
      return VoiceTicketView._(
        token: token as String,
        aiId: aiId,
        expiresAt: DateTime.parse(expiresAt),
      );
    } on FormatException {
      throw const FormatException('语音票据响应无效');
    } on TypeError {
      throw const FormatException('语音票据响应无效');
    }
  }
}

/// 宿主语音只读适配器：仅读取档案与签发票据，不做 UI/模型配置/厂商调用。
class VoiceApi {
  VoiceApi(this.connection);
  final HostConnection connection;

  Future<VoiceProfileView> readProfile(
    String aiId, {
    bool retryAuthentication = true,
  }) async {
    final response = await _request(
      'GET',
      aiId,
      retryAuthentication: retryAuthentication,
    );
    return VoiceProfileView.fromJson(response, expectedAiId: aiId);
  }

  Future<VoiceTicketView> issueTicket(
    String aiId, {
    bool retryAuthentication = true,
  }) async {
    final response = await _request(
      'POST',
      aiId,
      retryAuthentication: retryAuthentication,
    );
    return VoiceTicketView.fromJson(response, expectedAiId: aiId);
  }

  Future<Map<String, Object?>> _request(
    String method,
    String aiId, {
    required bool retryAuthentication,
  }) async {
    try {
      AiId.parse(aiId);
    } on FormatException {
      throw const FormatException('语音档案参数无效');
    }
    final template = method == 'GET'
        ? Routes.aiVoiceProfile
        : Routes.aiVoiceTicket;
    final path = template.replaceFirst('{aiId}', Uri.encodeComponent(aiId));
    try {
      return await connection.request(
        method,
        path,
        retryAuthentication: retryAuthentication,
      );
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
