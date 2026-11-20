import 'dart:async';
import 'dart:io';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// One read-only diagnostics read. Every read reports its own honest state; a
/// value is present only for [DiagnosticsReadStatus.loaded].
enum DiagnosticsReadStatus {
  /// The host returned a complete, valid payload.
  loaded,

  /// The host explicitly says this profile has no budget/timezone configured
  /// (`{configurationRequired: true}`). This is a configuration gap, not zero.
  unconfigured,

  /// The host hid the target (unknown provider, foreign or missing AI profile).
  notFound,

  /// The current session may not read this target.
  denied,

  /// The host or transport could not serve the read right now.
  unavailable,

  /// The response was malformed or the read outcome is otherwise unknown.
  unknown,
}

class DiagnosticsRead<T> {
  const DiagnosticsRead._(this.status, [this.value]);

  const DiagnosticsRead.unconfigured()
    : status = DiagnosticsReadStatus.unconfigured,
      value = null;
  const DiagnosticsRead.notFound()
    : status = DiagnosticsReadStatus.notFound,
      value = null;
  const DiagnosticsRead.denied()
    : status = DiagnosticsReadStatus.denied,
      value = null;
  const DiagnosticsRead.unavailable()
    : status = DiagnosticsReadStatus.unavailable,
      value = null;
  const DiagnosticsRead.unknown()
    : status = DiagnosticsReadStatus.unknown,
      value = null;

  factory DiagnosticsRead.loaded(T value) =>
      DiagnosticsRead<T>._(DiagnosticsReadStatus.loaded, value);

  final DiagnosticsReadStatus status;
  final T? value;

  // Intentionally excludes every recorded number, model id and transport error.
  @override
  String toString() => 'DiagnosticsRead(${status.name})';
}

/// Saved-provider model catalog: the ids the host actually returned, nothing
/// else. An empty list is a real answer, not an unconfigured state.
class ModelCatalog {
  ModelCatalog(List<String> models) : models = List.unmodifiable(models);
  final List<String> models;
}

/// Today's recorded tokens per layer and capability, as exact integers.
///
/// A capability listed in [unknownCapabilities] has at least one unresolved
/// ledger row: its recorded count is not the truth and must not be shown as 0.
class TodayUsage {
  TodayUsage({
    required this.budgetDay,
    required this.offsetMinutes,
    required this.recordedTokens,
    required Map<String, BigInt> byLayer,
    required Map<String, BigInt> byCapability,
    required Map<String, bool> sourceUsageUnknown,
  }) : byLayer = Map.unmodifiable(byLayer),
       byCapability = Map.unmodifiable(byCapability),
       sourceUsageUnknown = Map.unmodifiable(sourceUsageUnknown);

  final String budgetDay;
  final int offsetMinutes;
  final BigInt recordedTokens;
  final Map<String, BigInt> byLayer;
  final Map<String, BigInt> byCapability;
  final Map<String, bool> sourceUsageUnknown;

  Set<String> get unknownCapabilities => {
    for (final entry in sourceUsageUnknown.entries)
      if (entry.value) entry.key,
  };
  bool get hasUnknown => sourceUsageUnknown.values.any((value) => value);
}

/// One recorded civil-day bucket inside the rolling seven day window.
class TrendDay {
  TrendDay({
    required this.day,
    required this.recordedTokens,
    required Map<String, BigInt> byLayer,
    required this.sourceUsageUnknown,
  }) : byLayer = Map.unmodifiable(byLayer);

  final String day;
  final BigInt recordedTokens;
  final Map<String, BigInt> byLayer;
  final bool sourceUsageUnknown;
}

/// Seven recorded budget days ending today. Not a calendar or ISO week.
class Rolling7Trend {
  Rolling7Trend({
    required this.window,
    required this.basis,
    required this.offsetMinutes,
    required this.startDay,
    required this.endDay,
    required List<TrendDay> days,
    required this.hasUnknown,
  }) : days = List.unmodifiable(days);

  final String window;
  final String basis;
  final int offsetMinutes;
  final String startDay;
  final String endDay;
  final List<TrendDay> days;

  /// True when any historical pending ledger row exists, including rows whose
  /// recorded day falls outside [days]; those are still unresolved usage.
  final bool hasUnknown;
}

/// The explicitly configured limits. Reading them is not budget admission.
class BudgetLimits {
  BudgetLimits({
    required this.dailyTokens,
    required Map<String, int> layerLimits,
    required Map<String, int> capabilityLimits,
    required this.offsetMinutes,
  }) : layerLimits = Map.unmodifiable(layerLimits),
       capabilityLimits = Map.unmodifiable(capabilityLimits);

  final int dailyTokens;
  final Map<String, int> layerLimits;
  final Map<String, int> capabilityLimits;
  final int offsetMinutes;
}

/// Typed, GET-only adapters over the already-merged host diagnostics routes:
/// saved-provider model discovery, today's recorded usage, the rolling seven
/// recorded-day trend and the configured budget.
///
/// Strict parsing: unknown keys, non-string ids, non-decimal counters, wrong
/// shapes and internally inconsistent totals are rejected rather than repaired.
/// No value is invented, no credential or key mask is read or exposed, and no
/// request is retried beyond [HostConnection]'s existing bounded 401 renewal.
/// Nothing here writes configuration, admits a budget, or calls a model.
class ModelDiagnosticsApi {
  ModelDiagnosticsApi(this.connection);

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
  static final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');
  static final _day = RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$');
  static final _idControl = RegExp(r'[\x00-\x1f\x7f-\x9f]');
  static const _maxModels = 1000;
  static const _maxModelIdLength = 256;

  Set<String> get _layers => {for (final layer in BudgetLayer.values) layer.name};

  /// `GET /model-providers/{providerId}/models` → `{models:[{id}]}`.
  ///
  /// The host performs the single upstream catalog lookup; this client only
  /// projects the validated ids and never sees the provider credential.
  Future<DiagnosticsRead<ModelCatalog>> readModelCatalog(
    String providerId, {
    bool retryAuthentication = true,
  }) async {
    // Caller-supplied identity is validated before the honest-state boundary so
    // a bad argument is a programming error, not a host read outcome.
    final route = _providerModelsRoute(providerId);
    return _read(() async {
      final json = await connection.request(
        'GET',
        route,
        retryAuthentication: retryAuthentication,
      );
      _exact(json, const {'models'});
      final raw = json['models'];
      if (raw is! List || raw.length > _maxModels) _bad();
      final ids = <String>[], seen = <String>{};
      for (final entry in raw) {
        final row = _object(entry);
        _exact(row, const {'id'});
        final id = row['id'];
        if (id is! String ||
            id.isEmpty ||
            id.trim() != id ||
            id.length > _maxModelIdLength ||
            _idControl.hasMatch(id) ||
            !seen.add(id)) {
          _bad();
        }
        ids.add(id);
      }
      return DiagnosticsRead.loaded(ModelCatalog(ids));
    });
  }

  /// `GET /ai-profiles/{aiId}/usage` → today's recorded usage by layer and
  /// capability, with per-capability unresolved flags.
  Future<DiagnosticsRead<TodayUsage>> readTodayUsage(
    String profileId, {
    bool retryAuthentication = true,
  }) async {
    final route = _profileRoute(Routes.aiUsage, profileId);
    return _read(() async {
      final json = await connection.request(
        'GET',
        route,
        retryAuthentication: retryAuthentication,
      );
      if (_configurationRequired(json)) {
        return const DiagnosticsRead.unconfigured();
      }
      _exact(json, const {
        'budgetDay',
        'offsetMinutes',
        'recordedTokens',
        'byLayer',
        'byCapability',
        'sourceUsageUnknown',
      });
      final day = _dayKey(json['budgetDay']);
      final offset = _offset(json['offsetMinutes']);
      final total = _counter(json['recordedTokens']);
      final layers = _counters(json['byLayer'], _layers);
      final capabilities = _counters(json['byCapability'], _capabilities);
      final unknown = _flags(json['sourceUsageUnknown'], _capabilities);
      // The host derives all three from the same rows; a mismatch is corrupt.
      if (_sum(layers) != total || _sum(capabilities) != total) _bad();
      return DiagnosticsRead.loaded(
        TodayUsage(
          budgetDay: day,
          offsetMinutes: offset,
          recordedTokens: total,
          byLayer: layers,
          byCapability: capabilities,
          sourceUsageUnknown: unknown,
        ),
      );
    });
  }

  /// `GET /ai-profiles/{aiId}/usage/trend` → seven ascending recorded days.
  Future<DiagnosticsRead<Rolling7Trend>> readRolling7Trend(
    String profileId, {
    bool retryAuthentication = true,
  }) async {
    final route = _profileRoute(Routes.aiUsageTrend, profileId);
    return _read(() async {
      final json = await connection.request(
        'GET',
        route,
        retryAuthentication: retryAuthentication,
      );
      if (_configurationRequired(json)) {
        return const DiagnosticsRead.unconfigured();
      }
      _exact(json, const {
        'window',
        'basis',
        'offsetMinutes',
        'startDay',
        'endDay',
        'days',
        'sourceUsageUnknown',
      });
      // Reject any other window or basis: this client must not relabel a host
      // answer as a calendar week it never claimed.
      if (json['window'] != 'rolling7' ||
          json['basis'] != 'recordedBudgetDay') {
        _bad();
      }
      final offset = _offset(json['offsetMinutes']);
      final start = _dayKey(json['startDay']);
      final end = _dayKey(json['endDay']);
      final globalUnknown = json['sourceUsageUnknown'];
      if (globalUnknown is! bool) _bad();
      final raw = json['days'];
      if (raw is! List || raw.length != 7) _bad();
      final days = <TrendDay>[];
      String? previous;
      for (final entry in raw) {
        final row = _object(entry);
        _exact(row, const {
          'day',
          'recordedTokens',
          'byLayer',
          'sourceUsageUnknown',
        });
        final day = _dayKey(row['day']);
        final unknown = row['sourceUsageUnknown'];
        if (unknown is! bool) _bad();
        if (previous != null && !_isNextDay(previous, day)) _bad();
        previous = day;
        final total = _counter(row['recordedTokens']);
        final layers = _counters(row['byLayer'], _layers);
        if (_sum(layers) != total) _bad();
        days.add(
          TrendDay(
            day: day,
            recordedTokens: total,
            byLayer: layers,
            sourceUsageUnknown: unknown,
          ),
        );
      }
      // The declared window must be exactly the days returned, not a superset.
      if (days.first.day != start || days.last.day != end) _bad();
      return DiagnosticsRead.loaded(
        Rolling7Trend(
          window: 'rolling7',
          basis: 'recordedBudgetDay',
          offsetMinutes: offset,
          startDay: start,
          endDay: end,
          days: days,
          hasUnknown: globalUnknown,
        ),
      );
    });
  }

  /// `GET /ai-profiles/{aiId}/budget` → the explicitly configured limits.
  Future<DiagnosticsRead<BudgetLimits>> readBudget(
    String profileId, {
    bool retryAuthentication = true,
  }) async {
    final route = _profileRoute(Routes.aiBudget, profileId);
    return _read(() async {
      final json = await connection.request(
        'GET',
        route,
        retryAuthentication: retryAuthentication,
      );
      if (_configurationRequired(json)) {
        return const DiagnosticsRead.unconfigured();
      }
      _exact(json, const {
        'dailyTokens',
        'layerLimits',
        'capabilityLimits',
        'offsetMinutes',
      });
      final daily = json['dailyTokens'];
      if (daily is! int || daily < 0) _bad();
      final offset = _offset(json['offsetMinutes']);
      final layers = _limits(json['layerLimits'], _layers, daily);
      final capabilities = _limits(
        json['capabilityLimits'],
        _capabilities,
        daily,
      );
      return DiagnosticsRead.loaded(
        BudgetLimits(
          dailyTokens: daily,
          layerLimits: layers,
          capabilityLimits: capabilities,
          offsetMinutes: offset,
        ),
      );
    });
  }

  /// Shared honest-state boundary. Ownership/authorization decisions belong to
  /// the host; this only classifies the failure and never surfaces its detail.
  Future<DiagnosticsRead<T>> _read<T>(
    Future<DiagnosticsRead<T>> Function() action,
  ) async {
    try {
      return await action();
    } on FormatException {
      return const DiagnosticsRead.unknown();
    } on HostRequestException catch (e) {
      return switch (e.failure.code) {
        FailureCode.notFound => const DiagnosticsRead.notFound(),
        FailureCode.unauthenticated ||
        FailureCode.forbidden => const DiagnosticsRead.denied(),
        FailureCode.unavailable ||
        FailureCode.modelUnavailable ||
        FailureCode.rateLimited ||
        FailureCode.budgetExhausted => const DiagnosticsRead.unavailable(),
        _ => const DiagnosticsRead.unknown(),
      };
    } on TlsException {
      return const DiagnosticsRead.unavailable();
    } on SocketException {
      return const DiagnosticsRead.unavailable();
    } on HttpException {
      return const DiagnosticsRead.unavailable();
    } on TimeoutException {
      return const DiagnosticsRead.unavailable();
    }
  }

  static Never _bad() =>
      throw const FormatException('Diagnostics response invalid');

  static String _providerModelsRoute(String providerId) =>
      Routes.modelProviderModels.replaceFirst(
        '{providerId}',
        Uri.encodeComponent(_checkedId(providerId)),
      );

  static String _profileRoute(String route, String profileId) =>
      route.replaceFirst('{aiId}', Uri.encodeComponent(_checkedId(profileId)));

  /// Core ID errors carry the offending source; rethrow a source-free message so
  /// a caller can never log the rejected value.
  static String _checkedId(String raw) {
    try {
      return validateId(raw, kind: 'id');
    } on FormatException {
      throw const FormatException('Diagnostics identity invalid');
    }
  }

  static bool _configurationRequired(Map<String, Object?> json) =>
      json.length == 1 && json['configurationRequired'] == true;

  static Map<String, Object?> _object(Object? value) {
    if (value is! Map || value.keys.any((key) => key is! String)) _bad();
    return value.cast<String, Object?>();
  }

  static void _exact(Map<String, Object?> map, Set<String> keys) {
    if (map.length != keys.length || map.keys.any((k) => !keys.contains(k))) {
      _bad();
    }
  }

  static int _offset(Object? raw) {
    if (raw is! int || raw < -840 || raw > 840) _bad();
    return raw;
  }

  static String _dayKey(Object? raw) {
    if (raw is! String || !_day.hasMatch(raw)) _bad();
    final parsed = DateTime.tryParse('${raw}T00:00:00Z');
    if (parsed == null || parsed.year < 1) _bad();
    final padded =
        '${parsed.year.toString().padLeft(4, '0')}-'
        '${parsed.month.toString().padLeft(2, '0')}-'
        '${parsed.day.toString().padLeft(2, '0')}';
    // Reject rollovers such as 2026-02-31 rather than silently normalising.
    if (padded != raw) _bad();
    return raw;
  }

  static bool _isNextDay(String previous, String next) {
    final start = DateTime.parse('${previous}T00:00:00Z');
    return DateTime.parse('${next}T00:00:00Z') ==
        start.add(const Duration(days: 1));
  }

  static BigInt _counter(Object? raw) {
    if (raw is! String || !_decimal.hasMatch(raw)) _bad();
    return BigInt.parse(raw);
  }

  static Map<String, BigInt> _counters(Object? raw, Set<String> names) {
    final values = _object(raw);
    _exact(values, names);
    return {for (final name in names) name: _counter(values[name])};
  }

  static Map<String, bool> _flags(Object? raw, Set<String> names) {
    final values = _object(raw);
    _exact(values, names);
    final result = <String, bool>{};
    for (final name in names) {
      final value = values[name];
      if (value is! bool) _bad();
      result[name] = value;
    }
    return result;
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

  static BigInt _sum(Map<String, BigInt> values) =>
      values.values.fold(BigInt.zero, (total, value) => total + value);
}
