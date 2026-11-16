import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';
import 'owner_ai_direct_api.dart';

/// These describe one metadata read, never model readiness or budget admission.
enum ConfigurationReadStatus {
  configurationPresent,
  unconfigured,
  personaMissing,
  ownershipUnknown,
  denied,
  unknown,
}

class ConfigurationRead<T> {
  const ConfigurationRead._(this.status, [this.value]);
  final ConfigurationReadStatus status;
  final T? value;

  // Intentionally excludes persona content, provider fields and transport errors.
  @override
  String toString() => 'ConfigurationRead(${status.name})';
}

class OwnerPersonaCard {
  OwnerPersonaCard._(
    this.aiProfileId,
    this.version,
    this.locked,
    Map<String, Map<String, String>> layers,
  ) : layers = Map.unmodifiable(layers);
  final String aiProfileId;
  final int version;
  final bool locked;
  final Map<String, Map<String, String>> layers;
}

class OwnerModelBinding {
  const OwnerModelBinding._(
    this.ownerAccountId,
    this.aiProfileId,
    this.capability,
    this.providerId,
    this.model,
  );
  final String ownerAccountId;
  final String aiProfileId;
  final String capability;
  final String providerId;
  final String model;
}

class OwnerBudgetConfiguration {
  OwnerBudgetConfiguration._(
    this.dailyTokens,
    Map<String, int> layers,
    Map<String, int> capabilities,
    this.offsetMinutes,
  ) : layerLimits = Map.unmodifiable(layers),
      capabilityLimits = Map.unmodifiable(capabilities);
  final int dailyTokens;
  final Map<String, int> layerLimits;
  final Map<String, int> capabilityLimits;
  final int offsetMinutes;
}

/// Stored owner-visible metadata only. No raw credential or gateway operation.
class OwnerProviderMetadata {
  OwnerProviderMetadata._(
    this.id,
    this.name,
    this.baseUrl,
    this.keyMask,
    this.enabled,
    Set<String> capabilities,
  ) : capabilities = Set.unmodifiable(capabilities);
  final String id;
  final String name;
  final String baseUrl;
  final String keyMask;
  final bool enabled;
  final Set<String> capabilities;
}

/// Explicit GET-only prerequisites. Every method rechecks the resolved canonical
/// identity before reading its item. The two requests are NOT an atomic snapshot:
/// ownership/configuration may change between them or immediately afterwards.
/// In particular personaMissing describes only a target 404, not proof of current
/// ownership. No result grants consent, admits a budget, or proves a worker/model
/// available. No usage, history, discovery, outbound probe or write is performed.
class OwnerAiReadinessApi {
  OwnerAiReadinessApi(this.connection);
  final HostConnection connection;

  static const _capabilities = {
    'chat',
    'chatFast',
    'vision',
    'imageGen',
    'tts',
    'asr',
    'embedding',
  };
  static final _control = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  static final _personaValueControl = RegExp(
    r'[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]',
  );

  Future<ConfigurationRead<OwnerPersonaCard>> readPersona(
    OwnedAiProfileIdentity identity, {
    bool retryAuthentication = true,
  }) => _read(
    identity,
    () async {
      final json = await connection.request(
        'GET',
        _profileRoute(Routes.aiPersona, identity),
        retryAuthentication: retryAuthentication,
      );
      _exact(json, const {'aiId', 'version', 'locked', 'layers'});
      final id = json['aiId'],
          version = json['version'],
          locked = json['locked'];
      if (id != identity.profileId ||
          version is! int ||
          version < 1 ||
          locked is! bool) {
        _bad();
      }
      final rawLayers = _object(json['layers']);
      _exact(rawLayers, const {'p0', 'p1', 'p2'});
      final layers = <String, Map<String, String>>{};
      for (final name in ['p0', 'p1', 'p2']) {
        final raw = _object(rawLayers[name]);
        if (raw.isEmpty) _bad();
        final layer = <String, String>{};
        for (final e in raw.entries) {
          final value = e.value;
          if (!_text(e.key) ||
              e.key.trim() != e.key ||
              value is! String ||
              value.trim().isEmpty ||
              _personaValueControl.hasMatch(value)) {
            _bad();
          }
          layer[e.key] = value;
        }
        layers[name] = Map.unmodifiable(layer);
      }
      return _present(
        OwnerPersonaCard._(identity.profileId, version, locked, layers),
      );
    },
    retryAuthentication: retryAuthentication,
    persona404: true,
  );

  Future<ConfigurationRead<List<OwnerModelBinding>>> readBindings(
    OwnedAiProfileIdentity identity, {
    bool retryAuthentication = true,
  }) => _read(identity, () async {
    final rows = await connection.requestList(
      'GET',
      _profileRoute(Routes.aiBindings, identity),
      retryAuthentication: retryAuthentication,
    );
    final seen = <String>{}, result = <OwnerModelBinding>[];
    for (final raw in rows) {
      final row = _object(raw);
      _exact(row, const {
        'owner_id',
        'ai_profile_id',
        'capability',
        'provider_id',
        'model',
      });
      final cap = row['capability'],
          provider = row['provider_id'],
          model = row['model'];
      if (row['owner_id'] != identity.ownerAccountId ||
          row['ai_profile_id'] != identity.profileId ||
          cap is! String ||
          !_capabilities.contains(cap) ||
          !seen.add(cap) ||
          provider is! String ||
          model is! String ||
          !_text(model) ||
          model.trim() != model) {
        _bad();
      }
      validateId(provider);
      result.add(
        OwnerModelBinding._(
          identity.ownerAccountId,
          identity.profileId,
          cap,
          provider,
          model,
        ),
      );
    }
    return result.isEmpty
        ? const ConfigurationRead._(ConfigurationReadStatus.unconfigured)
        : _present(List<OwnerModelBinding>.unmodifiable(result));
  }, retryAuthentication: retryAuthentication);

  Future<ConfigurationRead<OwnerBudgetConfiguration>> readBudget(
    OwnedAiProfileIdentity identity, {
    bool retryAuthentication = true,
  }) => _read(identity, () async {
    final json = await connection.request(
      'GET',
      _profileRoute(Routes.aiBudget, identity),
      retryAuthentication: retryAuthentication,
    );
    if (json.length == 1 && json['configurationRequired'] == true) {
      return const ConfigurationRead._(ConfigurationReadStatus.unconfigured);
    }
    _exact(json, const {
      'dailyTokens',
      'layerLimits',
      'capabilityLimits',
      'offsetMinutes',
    });
    final daily = json['dailyTokens'], offset = json['offsetMinutes'];
    if (daily is! int ||
        daily < 0 ||
        offset is! int ||
        offset < -840 ||
        offset > 840) {
      _bad();
    }
    final layers = _limits(
      json['layerLimits'],
      BudgetLayer.values.map((v) => v.name).toSet(),
      daily,
    );
    final caps = _limits(json['capabilityLimits'], _capabilities, daily);
    return _present(OwnerBudgetConfiguration._(daily, layers, caps, offset));
  }, retryAuthentication: retryAuthentication);

  Future<ConfigurationRead<OwnerProviderMetadata>> readProvider(
    OwnedAiProfileIdentity identity,
    String providerId, {
    bool retryAuthentication = true,
  }) async {
    try {
      validateId(providerId);
    } on FormatException {
      throw const FormatException('Provider identity invalid');
    }
    return _read(identity, () async {
      final json = await connection.request(
        'GET',
        Routes.modelProvider.replaceFirst(
          '{providerId}',
          Uri.encodeComponent(providerId),
        ),
        retryAuthentication: retryAuthentication,
      );
      _exact(json, const {
        'id',
        'name',
        'base_url',
        'key_mask',
        'enabled',
        'capabilities',
      });
      final name = json['name'],
          url = json['base_url'],
          mask = json['key_mask'],
          enabled = json['enabled'],
          rawCaps = json['capabilities'];
      if (json['id'] != providerId ||
          name is! String ||
          name.trim().isEmpty ||
          url is! String ||
          mask is! String ||
          enabled is! bool ||
          rawCaps is! List) {
        _bad();
      }
      // Registry masks are exactly ****, or **** plus the key's last 4 UTF-16
      // code units; do not impose an invented ASCII-only key requirement.
      if (!(mask == '****' ||
          (mask.length == 8 &&
              mask.startsWith('****') &&
              !RegExp(r'[\x00-\x20\x7f*•]').hasMatch(mask.substring(4))))) {
        _bad();
      }
      final uri = Uri.tryParse(url);
      if (uri == null ||
          !const {'http', 'https'}.contains(uri.scheme) ||
          uri.host.isEmpty ||
          url.trim() != url ||
          RegExp(r'[\x00-\x20\x7f]').hasMatch(url) ||
          uri.userInfo.isNotEmpty ||
          uri.authority.contains('@') ||
          uri.hasQuery ||
          uri.hasFragment) {
        _bad();
      }
      // Parsing stored metadata is not URL authorization. No DNS/network probe.
      final caps = <String>{};
      for (final cap in rawCaps) {
        if (cap is! String || !_capabilities.contains(cap) || !caps.add(cap)) {
          _bad();
        }
      }
      return _present(
        OwnerProviderMetadata._(providerId, name, url, mask, enabled, caps),
      );
    }, retryAuthentication: retryAuthentication);
  }

  Future<ConfigurationRead<T>> _read<T>(
    OwnedAiProfileIdentity identity,
    Future<ConfigurationRead<T>> Function() action, {
    required bool retryAuthentication,
    bool persona404 = false,
  }) async {
    try {
      final json = await connection.request(
        'GET',
        _profileRoute(Routes.aiProfile, identity),
        retryAuthentication: retryAuthentication,
      );
      _exact(json, const {'profileId', 'accountId', 'ownerAccountId'});
      if (json['profileId'] != identity.profileId ||
          json['accountId'] != identity.accountId ||
          json['ownerAccountId'] != identity.ownerAccountId) {
        return const ConfigurationRead._(
          ConfigurationReadStatus.ownershipUnknown,
        );
      }
    } on HostRequestException catch (e) {
      return ConfigurationRead._(
        e.failure.code == FailureCode.notFound
            ? ConfigurationReadStatus.ownershipUnknown
            : _failure(e),
      );
    } on FormatException {
      return const ConfigurationRead._(
        ConfigurationReadStatus.ownershipUnknown,
      );
    } on TlsException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on SocketException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on HttpException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on TimeoutException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    }
    try {
      return await action();
    } on HostRequestException catch (e) {
      return ConfigurationRead._(
        persona404 && e.failure.code == FailureCode.notFound
            ? ConfigurationReadStatus.personaMissing
            : _failure(e),
      );
    } on FormatException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on TlsException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on SocketException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on HttpException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    } on TimeoutException {
      return const ConfigurationRead._(ConfigurationReadStatus.unknown);
    }
  }

  static ConfigurationReadStatus _failure(HostRequestException e) =>
      const {
        FailureCode.unauthenticated,
        FailureCode.forbidden,
      }.contains(e.failure.code)
      ? ConfigurationReadStatus.denied
      : ConfigurationReadStatus.unknown;
  static String _profileRoute(String route, OwnedAiProfileIdentity identity) =>
      route.replaceFirst('{aiId}', Uri.encodeComponent(identity.profileId));
  static bool _text(String s) => s.trim().isNotEmpty && !_control.hasMatch(s);
  static Never _bad() =>
      throw const FormatException('Configuration metadata invalid');
  static Map<String, Object?> _object(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) _bad();
    return value.cast<String, Object?>();
  }

  static void _exact(Map<String, Object?> map, Set<String> keys) {
    if (map.length != keys.length || map.keys.any((k) => !keys.contains(k))) {
      _bad();
    }
  }

  static Map<String, int> _limits(Object? raw, Set<String> names, int daily) {
    final values = _object(raw);
    _exact(values, names);
    final result = <String, int>{};
    var total = BigInt.zero;
    for (final name in names) {
      final n = values[name];
      if (n is! int || n < 0) _bad();
      result[name] = n;
      total += BigInt.from(n);
    }
    if (total > BigInt.from(daily)) _bad();
    return result;
  }

  static ConfigurationRead<T> _present<T>(T value) =>
      ConfigurationRead._(ConfigurationReadStatus.configurationPresent, value);
}
