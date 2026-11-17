library;

import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Saveable provider view. Deliberately has **no** `api_key` field: the host
/// only ever returns a masked `key_mask`, and this client never stores the key.
class ProviderConfigView {
  const ProviderConfigView({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.keyMask,
    required this.enabled,
    required this.capabilities,
  });

  final String id;
  final String name;
  final String baseUrl;
  final String keyMask;
  final bool enabled;
  final List<String> capabilities;

  static const Set<String> knownCapabilities = {
    'chat',
    'chatFast',
    'vision',
    'imageGen',
    'tts',
    'asr',
    'embedding',
  };

  factory ProviderConfigView.fromJson(Object? value) {
    if (value is! Map) throw const FormatException();
    const fields = {
      'id',
      'name',
      'base_url',
      'key_mask',
      'enabled',
      'capabilities',
    };
    if (value.length != fields.length ||
        value.keys.any((key) => !fields.contains(key))) {
      throw const FormatException();
    }
    final id = value['id'];
    final name = value['name'];
    final baseUrl = value['base_url'];
    final keyMask = value['key_mask'];
    final enabled = value['enabled'];
    final capabilities = value['capabilities'];
    if (id is! String ||
        name is! String ||
        baseUrl is! String ||
        keyMask is! String ||
        enabled is! bool ||
        capabilities is! List ||
        capabilities.any(
          (cap) => cap is! String || !knownCapabilities.contains(cap),
        )) {
      throw const FormatException();
    }
    validateId(id, kind: 'provider');
    return ProviderConfigView(
      id: id,
      name: name,
      baseUrl: baseUrl,
      keyMask: keyMask,
      enabled: enabled,
      capabilities: List<String>.unmodifiable(capabilities.cast<String>()),
    );
  }
}

/// Write-side contract for the AI run-config hub. Read-only readiness metadata
/// is separate ([OwnerAiReadinessApi]); this interface only performs the four
/// explicit configuration writes and never surfaces secrets.
abstract interface class AiConfigWriter {
  Future<ProviderConfigView> createProvider({
    required String name,
    required String baseUrl,
    required String apiKey,
    required Set<String> capabilities,
    bool enabled = true,
  });

  Future<ProviderConfigView> updateProvider(
    String providerId, {
    String? name,
    String? baseUrl,
    String? apiKey,
    Set<String>? capabilities,
    bool? enabled,
  });

  Future<void> initializePersona(
    String aiProfileId, {
    required Map<String, String> p0,
    required Map<String, String> p1,
    required Map<String, String> p2,
  });

  Future<void> editPersona(
    String aiProfileId, {
    required int expectedVersion,
    required String reason,
    required Map<String, String?> p0,
    required Map<String, String?> p1,
    required Map<String, String?> p2,
  });

  Future<void> setChatBinding(
    String aiProfileId, {
    required String providerId,
    required String model,
  });

  Future<void> configureBudget(
    String aiProfileId, {
    required int dailyTokens,
    required Map<String, int> layerLimits,
    required Map<String, int> capabilityLimits,
    required int offsetMinutes,
  });
}

/// Bound (authenticated) implementation over [HostConnection].
class AiConfigWriteApi implements AiConfigWriter {
  AiConfigWriteApi(this.connection);

  final HostConnection connection;

  static const Set<String> _layers = {
    'b0Life',
    'b1FastBrain',
    'b2DeepChat',
    'b3Proactive',
    'b4Maintenance',
  };
  static final RegExp _control = RegExp(r'[\x00-\x1f\x7f]');

  String _label(String value, String field) {
    if (value.trim().isEmpty ||
        value.trim() != value ||
        _control.hasMatch(value)) {
      throw FormatException('$field 无效');
    }
    return value;
  }

  Uri _url(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('base_url 无效');
    }
    return uri;
  }

  Set<String> _capabilities(Set<String> raw) {
    if (raw.any((cap) => !ProviderConfigView.knownCapabilities.contains(cap))) {
      throw const FormatException('capabilities 无效');
    }
    return raw;
  }

  Map<String, Object?> _personaLayer(Map<String, String> layer) {
    if (layer.isEmpty) throw const FormatException('人格层不能为空');
    return {
      for (final entry in layer.entries)
        _label(entry.key, '人格键'): _label(entry.value, '人格值'),
    };
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action();
    } on HostRequestException {
      rethrow;
    } on FormatException {
      rethrow;
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

  @override
  Future<ProviderConfigView> createProvider({
    required String name,
    required String baseUrl,
    required String apiKey,
    required Set<String> capabilities,
    bool enabled = true,
  }) => _guard(() async {
    _label(name, 'name');
    _url(baseUrl);
    if (apiKey.isEmpty) throw const FormatException('api_key 不能为空');
    final caps = _capabilities(capabilities);
    final json = await connection.request(
      'POST',
      Routes.modelProviders,
      body: {
        'name': name,
        'base_url': baseUrl,
        'api_key': apiKey,
        'capabilities': caps.toList(),
        'enabled': enabled,
      },
    );
    return ProviderConfigView.fromJson(json);
  });

  @override
  Future<ProviderConfigView> updateProvider(
    String providerId, {
    String? name,
    String? baseUrl,
    String? apiKey,
    Set<String>? capabilities,
    bool? enabled,
  }) => _guard(() async {
    validateId(providerId, kind: 'provider');
    final body = <String, Object?>{};
    if (name != null) body['name'] = _label(name, 'name');
    if (baseUrl != null) {
      _url(baseUrl);
      body['base_url'] = baseUrl;
    }
    if (apiKey != null) {
      if (apiKey.isEmpty) throw const FormatException('api_key 不能为空');
      body['api_key'] = apiKey;
    }
    if (capabilities != null) {
      body['capabilities'] = _capabilities(capabilities).toList();
    }
    if (enabled != null) body['enabled'] = enabled;
    if (body.isEmpty) throw const FormatException('没有要更新的字段');
    final json = await connection.request(
      'PUT',
      Routes.modelProvider.replaceFirst(
        '{providerId}',
        Uri.encodeComponent(providerId),
      ),
      body: body,
    );
    return ProviderConfigView.fromJson(json);
  });

  @override
  Future<void> initializePersona(
    String aiProfileId, {
    required Map<String, String> p0,
    required Map<String, String> p1,
    required Map<String, String> p2,
  }) => _guard(() async {
    AiId.parse(aiProfileId);
    final json = await connection.request(
      'POST',
      Routes.aiPersonaInitialize.replaceFirst(
        '{aiId}',
        Uri.encodeComponent(aiProfileId),
      ),
      body: {
        'p0': _personaLayer(p0),
        'p1': _personaLayer(p1),
        'p2': _personaLayer(p2),
      },
    );
    _validateCard(json, aiProfileId);
  });

  @override
  Future<void> editPersona(
    String aiProfileId, {
    required int expectedVersion,
    required String reason,
    required Map<String, String?> p0,
    required Map<String, String?> p1,
    required Map<String, String?> p2,
  }) => _guard(() async {
    AiId.parse(aiProfileId);
    if (expectedVersion < 1) throw const FormatException('expectedVersion 无效');
    if (reason.trim().isEmpty) throw const FormatException('reason 不能为空');
    if (p0.isEmpty && p1.isEmpty && p2.isEmpty) {
      throw const FormatException('至少要修改一个字段');
    }
    Map<String, Object?> diff(Map<String, String?> layer) => {
      for (final entry in layer.entries)
        _label(entry.key, '人格键'): entry.value == null
            ? null
            : _label(entry.value!, '人格值'),
    };
    final json = await connection.request(
      'PATCH',
      Routes.aiPersona.replaceFirst('{aiId}', Uri.encodeComponent(aiProfileId)),
      body: {
        'expectedVersion': expectedVersion,
        'reason': reason,
        'diff': {'p0': diff(p0), 'p1': diff(p1), 'p2': diff(p2)},
      },
    );
    _validateCard(json, aiProfileId);
  });

  void _validateCard(Map<String, Object?> json, String aiProfileId) {
    const fields = {'aiId', 'version', 'locked', 'layers'};
    final version = json['version'];
    final locked = json['locked'];
    if (json.keys.any((key) => !fields.contains(key)) ||
        json['aiId'] != aiProfileId ||
        version is! int ||
        version < 1 ||
        locked is! bool) {
      throw const FormatException('人格响应无效');
    }
  }

  @override
  Future<void> setChatBinding(
    String aiProfileId, {
    required String providerId,
    required String model,
  }) => _guard(() async {
    AiId.parse(aiProfileId);
    validateId(providerId, kind: 'provider');
    _label(model, 'model');
    final json = await connection.request(
      'PUT',
      Routes.aiBinding
          .replaceFirst('{aiId}', Uri.encodeComponent(aiProfileId))
          .replaceFirst('{capability}', 'chat'),
      body: {'providerId': providerId, 'model': model},
    );
    const fields = {
      'owner_id',
      'ai_profile_id',
      'capability',
      'provider_id',
      'model',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key)) ||
        json['capability'] != 'chat' ||
        json['ai_profile_id'] != aiProfileId ||
        json['provider_id'] != providerId ||
        json['model'] != model) {
      throw const FormatException('绑定响应无效');
    }
  });

  @override
  Future<void> configureBudget(
    String aiProfileId, {
    required int dailyTokens,
    required Map<String, int> layerLimits,
    required Map<String, int> capabilityLimits,
    required int offsetMinutes,
  }) => _guard(() async {
    AiId.parse(aiProfileId);
    bool complete(Map<String, int> map, Set<String> names) =>
        map.length == names.length &&
        names.every((name) => (map[name] ?? -1) >= 0);
    if (dailyTokens < 0 ||
        offsetMinutes < -840 ||
        offsetMinutes > 840 ||
        !complete(layerLimits, _layers) ||
        !complete(capabilityLimits, ProviderConfigView.knownCapabilities)) {
      throw const FormatException('预算参数不完整或越界');
    }
    final json = await connection.request(
      'PUT',
      Routes.aiBudget.replaceFirst('{aiId}', Uri.encodeComponent(aiProfileId)),
      body: {
        'dailyTokens': dailyTokens,
        'layerLimits': layerLimits,
        'capabilityLimits': capabilityLimits,
        'offsetMinutes': offsetMinutes,
      },
    );
    const fields = {
      'dailyTokens',
      'layerLimits',
      'capabilityLimits',
      'offsetMinutes',
    };
    if (json.keys.any((key) => !fields.contains(key)) ||
        json['dailyTokens'] != dailyTokens ||
        json['offsetMinutes'] != offsetMinutes) {
      throw const FormatException('预算响应无效');
    }
  });
}
