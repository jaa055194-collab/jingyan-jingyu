import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';
import 'usage_meter.dart';

/// Owner-visible recorded tokens, not model-admission policy or billing.
/// Ownership, configured day and selected ledger rows share one transaction.
final class UsageSummary {
  UsageSummary.forOwner({
    required String ownerId,
    required Database db,
    required Clock clock,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db,
       _clock = clock;

  final String _ownerId;
  final Database _db;
  final Clock _clock;
  static final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');

  Result<Map<String, Object?>> _configurationRequired() => err(
    FailureCode.budgetExhausted,
    'Explicit budget timezone required',
    {'configurationRequired': true},
  );

  BigInt _counter(Object? raw) {
    if (raw is! String || !_decimal.hasMatch(raw)) {
      throw const FormatException('Invalid stored usage counter');
    }
    return BigInt.parse(raw);
  }

  Future<Result<Map<String, Object?>>> today(AiId ai) => _db.transaction((
    tx,
  ) async {
    final ownership = await tx.query(
      '''
SELECT p.id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id
  AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?
''',
      [ai.value, _ownerId],
    );
    if (ownership.isEmpty) {
      return err(FailureCode.notFound, 'AI identity not found');
    }
    final configuration = await tx.query(
      'SELECT offset_minutes FROM usage_budget WHERE owner_id=? AND ai_id=?',
      [_ownerId, ai.value],
    );
    if (configuration.isEmpty) return _configurationRequired();
    final offset = configuration.single['offset_minutes'];
    if (offset is! int || offset < -840 || offset > 840) {
      return _configurationRequired();
    }
    final day = BudgetDay.fromClock(_clock, offsetMinutes: offset);
    // Unknown requests must remain visible across midnight. Settled records
    // use the persisted start-day key, exactly like the existing gate.
    final rows = await tx.query(
      '''
SELECT layer, capability, input_tokens, output_tokens, total_tokens,
       source_usage_unknown
FROM usage_ledger WHERE owner_id=? AND ai_id=?
  AND (budget_day=? OR source_usage_unknown=1)
''',
      [_ownerId, ai.value, day.date],
    );
    final layers = {
      for (final layer in BudgetLayer.values) layer.name: BigInt.zero,
    };
    final capabilities = {
      for (final capability in ProviderCapability.values)
        capability.name: BigInt.zero,
    };
    final unknown = {
      for (final capability in ProviderCapability.values)
        capability.name: false,
    };
    var total = BigInt.zero;
    try {
      for (final row in rows) {
        final layer = row['layer'];
        final capability = row['capability'];
        if (!layers.containsKey(layer) ||
            !capabilities.containsKey(capability)) {
          throw const FormatException('Invalid stored usage category');
        }
        final pending = row['source_usage_unknown'];
        if (pending == 1) {
          if (row['input_tokens'] != null ||
              row['output_tokens'] != null ||
              row['total_tokens'] != null) {
            throw const FormatException('Invalid pending usage');
          }
          unknown[capability as String] = true;
          continue;
        }
        if (pending != 0) {
          throw const FormatException('Invalid usage status');
        }
        final input = _counter(row['input_tokens']);
        final output = _counter(row['output_tokens']);
        final used = _counter(row['total_tokens']);
        if (input + output != used) {
          throw const FormatException('Inconsistent usage counters');
        }
        total += used;
        layers[layer as String] = layers[layer]! + used;
        capabilities[capability as String] = capabilities[capability]! + used;
      }
    } on FormatException {
      return err(FailureCode.internal, 'Stored usage cannot be decoded');
    }
    return Ok<Map<String, Object?>>({
      'budgetDay': day.date,
      'offsetMinutes': day.offsetMinutes,
      'recordedTokens': total.toString(),
      'byLayer': {
        for (final entry in layers.entries) entry.key: entry.value.toString(),
      },
      'byCapability': {
        for (final entry in capabilities.entries)
          entry.key: entry.value.toString(),
      },
      'sourceUsageUnknown': unknown,
    });
  });
}
