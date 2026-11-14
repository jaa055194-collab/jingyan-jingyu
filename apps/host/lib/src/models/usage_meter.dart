import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';

/// A validated civil day and explicit user-configured UTC offset. Never accept
/// this value from a request body; only the trusted gateway creates it.
final class BudgetDay {
  BudgetDay({required this.date, required this.offsetMinutes}) {
    final parsed = DateTime.tryParse('${date}T00:00:00Z');
    if (!RegExp(r'^[0-9]{4}-[0-9]{2}-[0-9]{2}$').hasMatch(date) ||
        parsed == null ||
        parsed.year < 1 ||
        dayKey(parsed) != date ||
        offsetMinutes < -840 ||
        offsetMinutes > 840) {
      throw ArgumentError('Explicit valid budget day and UTC offset required');
    }
  }

  factory BudgetDay.fromClock(Clock clock, {required int offsetMinutes}) =>
      BudgetDay(
        date: dayKey(clock.now().toUtc().add(Duration(minutes: offsetMinutes))),
        offsetMinutes: offsetMinutes,
      );

  final String date;
  final int offsetMinutes;
}

/// No inferred token budgets or shares. Validation happens at configure so
/// invalid user configuration is a Result rather than an exception.
final class UsageBudget {
  UsageBudget({
    required this.dailyTokens,
    required Map<BudgetLayer, int> layerLimits,
    required Map<ProviderCapability, int> capabilityLimits,
  }) : layerLimits = Map.unmodifiable(layerLimits),
       capabilityLimits = Map.unmodifiable(capabilityLimits);

  final int dailyTokens;
  final Map<BudgetLayer, int> layerLimits;
  final Map<ProviderCapability, int> capabilityLimits;

  /// Shared validation for trusted atomic budget configuration adapters.
  bool get isValid => _valid;

  bool get _valid {
    if (dailyTokens < 0 ||
        layerLimits.length != BudgetLayer.values.length ||
        capabilityLimits.length != ProviderCapability.values.length) {
      return false;
    }
    bool valid(Iterable<int> amounts) {
      var sum = BigInt.zero;
      for (final n in amounts) {
        if (n < 0) return false;
        sum += BigInt.from(n);
      }
      return sum <= BigInt.from(dailyTokens);
    }

    return valid(layerLimits.values) && valid(capabilityLimits.values);
  }
}

/// Layer degradation is advice for the trusted gateway's policy. In particular
/// B2 degraded still permits owner private chats; the gateway must explicitly
/// authorize this when beginning a request. Daily/capability hard stops return
/// budgetExhausted.
final class UsageGate {
  const UsageGate({
    required this.day,
    required this.degradeLevel,
    required this.dailyUsed,
    required this.layerUsed,
    required this.capabilityUsed,
    required this.sourceUsageUnknown,
  });
  final BudgetDay day;
  final DegradeLevel degradeLevel;
  final BigInt dailyUsed;
  final BigInt layerUsed;
  final BigInt capabilityUsed;
  final bool sourceUsageUnknown;
}

/// Persisted request identity. A replay returns the same day and unknown status;
/// the gateway must not send another provider call for an existing identity.
final class UsageRequest {
  const UsageRequest({
    required this.requestId,
    required this.day,
    required this.sourceUsageUnknown,
    required this.replayed,
  });
  final String requestId;
  final BudgetDay day;
  final bool sourceUsageUnknown;
  final bool replayed;
}

/// Owner scope, clock and dayForClock are trusted composition inputs, never
/// HTTP body fields. Every operation verifies the AI's *current* operator from
/// canonical account/ai_operator/ai_profile, including settlement and replay.
/// This slice meters real provider counts only; it reserves no estimated cost
/// and cannot guarantee requests already in flight stay under a token limit.
final class UsageMeter {
  UsageMeter.forOwner({
    required String ownerId,
    required Database db,
    required Clock clock,
    required BudgetDay Function(Clock) dayForClock,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db,
       _clock = clock,
       _dayForClock = dayForClock;

  final String _ownerId;
  final Database _db;
  final Clock _clock;
  final BudgetDay Function(Clock) _dayForClock;

  Future<bool> _owns(Tx tx, AiId ai) async => (await tx.query(
    '''
SELECT p.id FROM ai_profile p
JOIN account a ON a.id = p.account_id AND a.kind = 'ai' AND a.disabled = 0
JOIN ai_operator o ON o.ai_id = a.id
JOIN account owner ON owner.id = o.operator_id AND owner.disabled = 0 AND owner.kind = 'human'
WHERE p.id = ? AND o.operator_id = ?
''',
    [ai.value, _ownerId],
  )).isNotEmpty;

  Result<T> _hidden<T>() => err(FailureCode.notFound, 'AI identity not found');

  Future<Result<void>> configure(AiId ai, UsageBudget budget) =>
      _db.transaction((tx) async {
        if (!await _owns(tx, ai)) return _hidden<void>();
        if (!budget._valid) {
          return err<void>(
            FailureCode.invalidArgument,
            'Explicit nonnegative daily, layer and capability limits required',
          );
        }
        await tx.execute(
          '''
INSERT INTO usage_budget(owner_id, ai_id, daily_tokens, layer_limits, capability_limits)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(owner_id, ai_id) DO UPDATE SET daily_tokens=excluded.daily_tokens,
 layer_limits=excluded.layer_limits, capability_limits=excluded.capability_limits
''',
          [
            _ownerId,
            ai.value,
            budget.dailyTokens.toString(),
            jsonEncode({
              for (final e in budget.layerLimits.entries)
                e.key.name: e.value.toString(),
            }),
            jsonEncode({
              for (final e in budget.capabilityLimits.entries)
                e.key.name: e.value.toString(),
            }),
          ],
        );
        return const Ok(null);
      });

  Future<Result<UsageGate>> inspect(
    AiId ai, {
    required BudgetLayer layer,
    required ProviderCapability capability,
  }) => _db.transaction((tx) async {
    if (!await _owns(tx, ai)) return _hidden<UsageGate>();
    return _inspect(tx, ai, layer, capability, _dayForClock(_clock));
  });

  Future<Result<UsageGate>> _inspect(
    Tx tx,
    AiId ai,
    BudgetLayer layer,
    ProviderCapability capability,
    BudgetDay day,
  ) async {
    final config = await tx.query(
      'SELECT * FROM usage_budget WHERE owner_id=? AND ai_id=?',
      [_ownerId, ai.value],
    );
    if (config.isEmpty) {
      return err(FailureCode.budgetExhausted, 'Budget configuration required', {
        'configurationRequired': true,
      });
    }
    // Unknown usage remains blocking across midnight, until settled/reconciled.
    final unknown = await tx.query(
      '''
SELECT 1 FROM usage_ledger WHERE owner_id=? AND ai_id=? AND capability=? AND source_usage_unknown=1 LIMIT 1
''',
      [_ownerId, ai.value, capability.name],
    );
    if (unknown.isNotEmpty) {
      return err(
        FailureCode.unavailable,
        'Provider usage requires settlement or reconciliation',
        {'sourceUsageUnknown': true},
      );
    }
    final rows = await tx.query(
      'SELECT layer, capability, total_tokens FROM usage_ledger WHERE owner_id=? AND ai_id=? AND budget_day=? AND source_usage_unknown=0',
      [_ownerId, ai.value, day.date],
    );
    var dailyUsed = BigInt.zero;
    var layerUsed = BigInt.zero;
    var capabilityUsed = BigInt.zero;
    for (final row in rows) {
      final total = BigInt.parse(row['total_tokens'] as String);
      dailyUsed += total;
      if (row['layer'] == layer.name) layerUsed += total;
      if (row['capability'] == capability.name) capabilityUsed += total;
    }
    final row = config.single;
    final dailyLimit = BigInt.parse(row['daily_tokens'] as String);
    final layerLimit = BigInt.parse(
      (jsonDecode(row['layer_limits'] as String) as Map)[layer.name] as String,
    );
    final capLimit = BigInt.parse(
      (jsonDecode(row['capability_limits'] as String) as Map)[capability.name]
          as String,
    );
    if (dailyUsed >= dailyLimit || capabilityUsed >= capLimit) {
      return err(
        FailureCode.budgetExhausted,
        'Recorded daily or capability budget exhausted',
        {'scope': dailyUsed >= dailyLimit ? 'daily' : 'capability'},
      );
    }
    final level = layerUsed >= layerLimit
        ? DegradeLevel.degraded
        : layerUsed * BigInt.from(5) >= layerLimit * BigInt.from(4)
        ? DegradeLevel.warn
        : DegradeLevel.normal;
    return Ok(
      UsageGate(
        day: day,
        degradeLevel: level,
        dailyUsed: dailyUsed,
        layerUsed: layerUsed,
        capabilityUsed: capabilityUsed,
        sourceUsageUnknown: false,
      ),
    );
  }

  /// Persist the day before calling the provider and atomically recheck layer
  /// exhaustion. [allowDegradedLayer] is trusted gateway policy authorization,
  /// derived from authenticated context, never an HTTP body field. It cannot
  /// override daily/capability hard stops or unknown provider usage.
  /// Concurrent same-capability starts serialize: unknown usage fails closed.
  Future<Result<UsageRequest>> beginRequest(
    AiId ai, {
    required String requestId,
    required BudgetLayer layer,
    required ProviderCapability capability,
    bool allowDegradedLayer = false,
  }) => _db.transaction((tx) async {
    if (!await _owns(tx, ai)) return _hidden<UsageRequest>();
    if (!_validRequestId(requestId)) {
      return err<UsageRequest>(
        FailureCode.invalidArgument,
        'Invalid request ID',
      );
    }
    final previous = await _request(tx, ai, requestId);
    if (previous.isNotEmpty) {
      final row = previous.single;
      if (row['layer'] != layer.name || row['capability'] != capability.name) {
        return err<UsageRequest>(
          FailureCode.conflict,
          'Request ID payload conflict',
        );
      }
      return Ok(_requestView(row, replayed: true));
    }
    final day = _dayForClock(_clock);
    final gate = await _inspect(tx, ai, layer, capability, day);
    if (gate case Err<UsageGate>(:final failure)) {
      return Err<UsageRequest>(failure);
    }
    if (gate.value.degradeLevel == DegradeLevel.degraded &&
        !allowDegradedLayer) {
      return err<UsageRequest>(
        FailureCode.budgetExhausted,
        'Recorded layer budget exhausted; trusted gateway policy required',
        {'scope': 'layer', 'degradeLevel': DegradeLevel.degraded.name},
      );
    }
    await tx.execute(
      '''
INSERT INTO usage_ledger(owner_id,ai_id,request_id,budget_day,offset_minutes,layer,capability,source_usage_unknown)
VALUES(?,?,?,?,?,?,?,1)
''',
      [
        _ownerId,
        ai.value,
        requestId,
        day.date,
        day.offsetMinutes,
        layer.name,
        capability.name,
      ],
    );
    return Ok(
      UsageRequest(
        requestId: requestId,
        day: day,
        sourceUsageUnknown: true,
        replayed: false,
      ),
    );
  });

  bool _validRequestId(String id) =>
      id.isNotEmpty &&
      id.length <= 256 &&
      !RegExp(r'[\x00-\x20\x7f]').hasMatch(id);

  Future<List<Map<String, Object?>>> _request(
    Tx tx,
    AiId ai,
    String requestId,
  ) => tx.query(
    'SELECT * FROM usage_ledger WHERE owner_id=? AND ai_id=? AND request_id=?',
    [_ownerId, ai.value, requestId],
  );

  UsageRequest _requestView(
    Map<String, Object?> row, {
    required bool replayed,
  }) => UsageRequest(
    requestId: row['request_id'] as String,
    day: BudgetDay(
      date: row['budget_day'] as String,
      offsetMinutes: row['offset_minutes'] as int,
    ),
    sourceUsageUnknown: row['source_usage_unknown'] == 1,
    replayed: replayed,
  );

  /// Real provider usage only. No gate is reapplied when settling an in-flight
  /// request: even an overage must be durably counted. Null/missing usage stays
  /// pending; an actual provider-reported zero is a valid known count.
  Future<Result<void>> recordUsage(
    AiId ai, {
    required String requestId,
    required BudgetLayer layer,
    required ProviderCapability capability,
    required int input,
    required int output,
    required int total,
  }) => _db.transaction((tx) async {
    if (!await _owns(tx, ai)) return _hidden<void>();
    if (!_validRequestId(requestId) ||
        input < 0 ||
        output < 0 ||
        total < 0 ||
        BigInt.from(input) + BigInt.from(output) != BigInt.from(total)) {
      return err<void>(
        FailureCode.invalidArgument,
        'Provider usage must be nonnegative and total must equal input plus output',
      );
    }
    final rows = await _request(tx, ai, requestId);
    if (rows.isEmpty) {
      return err<void>(
        FailureCode.notFound,
        'Request must begin before usage settlement',
      );
    }
    final row = rows.single;
    if (row['layer'] != layer.name ||
        row['capability'] != capability.name ||
        (row['source_usage_unknown'] == 0 &&
            (row['input_tokens'] != input.toString() ||
                row['output_tokens'] != output.toString() ||
                row['total_tokens'] != total.toString()))) {
      return err<void>(FailureCode.conflict, 'Request ID payload conflict');
    }
    if (row['source_usage_unknown'] == 0) return const Ok(null);
    await tx.execute(
      '''
UPDATE usage_ledger SET input_tokens=?, output_tokens=?, total_tokens=?, source_usage_unknown=0
WHERE owner_id=? AND ai_id=? AND request_id=?
''',
      [
        input.toString(),
        output.toString(),
        total.toString(),
        _ownerId,
        ai.value,
        requestId,
      ],
    );
    return const Ok(null);
  });
}
