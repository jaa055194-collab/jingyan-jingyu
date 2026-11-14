import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';
import 'usage_meter.dart';

/// Seven recorded civil-day buckets, not a calendar-week or billing projection.
final class UsageTrend {
  UsageTrend.forOwner({
    required String ownerId,
    required Database db,
    required Clock clock,
  }) : _owner = validateId(ownerId, kind: 'owner'),
       _db = db,
       _clock = clock;

  final String _owner;
  final Database _db;
  final Clock _clock;
  static final _decimal = RegExp(r'^(0|[1-9][0-9]*)$');

  BigInt _counter(Object? value) {
    if (value is! String || !_decimal.hasMatch(value)) {
      throw const FormatException('Invalid recorded counter');
    }
    return BigInt.parse(value);
  }

  Future<Result<Map<String, Object?>>> rolling7(AiId ai) => _db.transaction((
    tx,
  ) async {
    final owned = await tx.query(
      '''
SELECT p.id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id
  AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?
''',
      [ai.value, _owner],
    );
    if (owned.isEmpty) {
      return err(FailureCode.notFound, 'AI identity not found');
    }
    final config = await tx.query(
      'SELECT offset_minutes FROM usage_budget WHERE owner_id=? AND ai_id=?',
      [_owner, ai.value],
    );
    final offset = config.isEmpty ? null : config.single['offset_minutes'];
    if (offset is! int || offset < -840 || offset > 840) {
      return err(FailureCode.budgetExhausted, 'Explicit timezone required', {
        'configurationRequired': true,
      });
    }
    final today = BudgetDay.fromClock(_clock, offsetMinutes: offset);
    // Use a UTC civil-date surrogate for date arithmetic, not the host zone.
    final end = DateTime.parse('${today.date}T00:00:00Z');
    final dates = [
      for (var i = 6; i >= 0; i--) dayKey(end.subtract(Duration(days: i))),
    ];
    final buckets = <String, _Bucket>{
      for (final date in dates) date: _Bucket(),
    };
    final placeholders = List.filled(dates.length, '?').join(',');
    final rows = await tx.query(
      '''
SELECT budget_day, layer, capability, input_tokens, output_tokens, total_tokens,
       source_usage_unknown FROM usage_ledger
WHERE owner_id=? AND ai_id=?
  AND (budget_day IN ($placeholders) OR source_usage_unknown=1)
''',
      [_owner, ai.value, ...dates],
    );
    var anyUnknown = false;
    try {
      for (final row in rows) {
        final layer = row['layer'];
        final capability = row['capability'];
        if (!BudgetLayer.values.any((v) => v.name == layer) ||
            !ProviderCapability.values.any((v) => v.name == capability)) {
          throw const FormatException('Invalid recorded category');
        }
        final bucket = buckets[row['budget_day']];
        final pending = row['source_usage_unknown'];
        if (pending == 1) {
          if (row['input_tokens'] != null ||
              row['output_tokens'] != null ||
              row['total_tokens'] != null) {
            throw const FormatException('Invalid unresolved usage');
          }
          anyUnknown = true;
          if (bucket != null) bucket.unknown = true;
          continue;
        }
        if (pending != 0 || bucket == null) {
          throw const FormatException('Invalid recorded status');
        }
        final input = _counter(row['input_tokens']);
        final output = _counter(row['output_tokens']);
        final total = _counter(row['total_tokens']);
        if (input + output != total) {
          throw const FormatException('Inconsistent recorded usage');
        }
        bucket.total += total;
        bucket.layers[layer as String] = bucket.layers[layer]! + total;
      }
    } on FormatException {
      return err(FailureCode.internal, 'Stored usage cannot be decoded');
    }
    return Ok<Map<String, Object?>>({
      'window': 'rolling7',
      'basis': 'recordedBudgetDay',
      'offsetMinutes': offset,
      'startDay': dates.first,
      'endDay': dates.last,
      'days': [
        for (final date in dates)
          {
            'day': date,
            'recordedTokens': buckets[date]!.total.toString(),
            'byLayer': {
              for (final entry in buckets[date]!.layers.entries)
                entry.key: entry.value.toString(),
            },
            'sourceUsageUnknown': buckets[date]!.unknown,
          },
      ],
      'sourceUsageUnknown': anyUnknown,
    });
  });
}

final class _Bucket {
  BigInt total = BigInt.zero;
  final layers = {
    for (final layer in BudgetLayer.values) layer.name: BigInt.zero,
  };
  bool unknown = false;
}
