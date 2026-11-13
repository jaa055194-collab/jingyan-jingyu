import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';
import 'usage_meter.dart';

/// Safe owner-visible limits and the explicitly configured civil-day offset.
final class BudgetConfigurationView {
  const BudgetConfigurationView({
    required this.budget,
    required this.offsetMinutes,
  });
  final UsageBudget budget;
  final int offsetMinutes;

  Map<String, Object?> toJson() => {
    'dailyTokens': budget.dailyTokens,
    'layerLimits': {
      for (final e in budget.layerLimits.entries) e.key.name: e.value,
    },
    'capabilityLimits': {
      for (final e in budget.capabilityLimits.entries) e.key.name: e.value,
    },
    'offsetMinutes': offsetMinutes,
  };
}

/// Trusted owner scope. Authorization and the complete upsert share one Tx.
/// Changing the offset never clears usage: subsequent gates use the new civil
/// day, while outstanding unknown usage continues to fail closed across days.
final class BudgetConfiguration {
  BudgetConfiguration.forOwner({
    required String ownerId,
    required Database db,
    required Clock clock,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db;

  final String _ownerId;
  final Database _db;

  Future<bool> _owns(Tx tx, AiId ai) async => (await tx.query(
    '''
SELECT p.id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=? AND o.operator_id=?
''',
    [ai.value, _ownerId],
  )).isNotEmpty;

  Result<T> _hidden<T>() => err(FailureCode.notFound, 'AI identity not found');
  Result<BudgetConfigurationView> _required() => err(
    FailureCode.budgetExhausted,
    'Budget configuration required',
    {'configurationRequired': true},
  );

  Future<Result<void>> configure(
    AiId ai,
    UsageBudget budget, {
    required int offsetMinutes,
  }) => _db.transaction((tx) async {
    if (!await _owns(tx, ai)) return _hidden<void>();
    if (!budget.isValid || offsetMinutes < -840 || offsetMinutes > 840) {
      return err<void>(
        FailureCode.invalidArgument,
        'Complete valid budget and explicit timezone required',
      );
    }
    await tx.execute(
      '''
INSERT INTO usage_budget(owner_id,ai_id,daily_tokens,layer_limits,capability_limits,offset_minutes)
VALUES(?,?,?,?,?,?)
ON CONFLICT(owner_id,ai_id) DO UPDATE SET daily_tokens=excluded.daily_tokens,
 layer_limits=excluded.layer_limits,capability_limits=excluded.capability_limits,
 offset_minutes=excluded.offset_minutes
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
        offsetMinutes,
      ],
    );
    return const Ok(null);
  });

  Future<Result<BudgetConfigurationView>> get(AiId ai) => _db.transaction((
    tx,
  ) async {
    if (!await _owns(tx, ai)) return _hidden<BudgetConfigurationView>();
    final rows = await tx.query(
      'SELECT * FROM usage_budget WHERE owner_id=? AND ai_id=?',
      [_ownerId, ai.value],
    );
    if (rows.isEmpty || rows.single['offset_minutes'] == null) {
      return _required();
    }
    final row = rows.single;
    try {
      final layers = jsonDecode(row['layer_limits'] as String) as Map;
      final capabilities =
          jsonDecode(row['capability_limits'] as String) as Map;
      if (layers.length != BudgetLayer.values.length ||
          capabilities.length != ProviderCapability.values.length) {
        return _required();
      }
      final budget = UsageBudget(
        dailyTokens: int.parse(row['daily_tokens'] as String),
        layerLimits: {
          for (final l in BudgetLayer.values)
            l: int.parse(layers[l.name] as String),
        },
        capabilityLimits: {
          for (final c in ProviderCapability.values)
            c: int.parse(capabilities[c.name] as String),
        },
      );
      final offset = row['offset_minutes'];
      if (!budget.isValid || offset is! int || offset < -840 || offset > 840) {
        return _required();
      }
      return Ok(BudgetConfigurationView(budget: budget, offsetMinutes: offset));
    } on FormatException {
      return _required();
    } on TypeError {
      return _required();
    }
  });
}
