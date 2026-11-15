import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'provider_registry.dart';

/// Safe persistent configuration; contains no provider credentials.
final class BindingView {
  const BindingView({
    required this.ownerId,
    required this.aiProfileId,
    required this.capability,
    required this.providerId,
    required this.model,
  });
  final String ownerId;
  final AiId aiProfileId;
  final ProviderCapability capability;
  final String providerId;
  final String model;

  Map<String, Object?> toJson() => {
    'owner_id': ownerId,
    'ai_profile_id': aiProfileId.value,
    'capability': capability.name,
    'provider_id': providerId,
    'model': model,
  };
}

/// Gateway routing input only; credentials must be obtained separately through
/// the owner-scoped registry at invocation time.
final class ResolvedBinding {
  const ResolvedBinding({
    required this.ownerId,
    required this.aiProfileId,
    required this.aiAccountId,
    required this.capability,
    required this.providerId,
    required this.model,
  });
  final String ownerId;
  final AiId aiProfileId;
  final AccountId aiAccountId;
  final ProviderCapability capability;
  final String providerId;
  final String model;

  Map<String, Object?> toJson() => {
    'owner_id': ownerId,
    'ai_profile_id': aiProfileId.value,
    'ai_account_id': aiAccountId.value,
    'capability': capability.name,
    'provider_id': providerId,
    'model': model,
  };
}

/// Owner scope comes from the authenticated principal. Admin has no bypass.
/// This slice stores one binding per capability. Ordered main-chat fallback
/// chains remain unimplemented; chatFast and voice never fall back.
final class BindingMatrix {
  BindingMatrix.forOwner(String ownerId, Database db)
    : _ownerId = validateId(ownerId, kind: 'owner'),
      _db = db;
  final String _ownerId;
  final Database _db;

  Future<Result<T>> _withAi<T>(
    AiId ai,
    Future<Result<T>> Function(Tx tx, AccountId account) operation,
  ) => _db.transaction((tx) async {
    final rows = await tx.query(
      '''
SELECT a.id
FROM ai_profile p
JOIN account a ON a.id = p.account_id AND a.kind = 'ai' AND a.disabled = 0
JOIN ai_operator o ON o.ai_id = a.id
JOIN account owner ON owner.id = o.operator_id AND owner.kind = 'human' AND owner.disabled = 0
WHERE p.id = ? AND o.operator_id = ?
''',
      [ai.value, _ownerId],
    );
    if (rows.isEmpty) {
      return err<T>(FailureCode.notFound, 'AI identity not found');
    }
    return operation(tx, AccountId.parse(rows.single['id'] as String));
  });

  BindingView _view(Map<String, Object?> row) => BindingView(
    ownerId: row['owner_id'] as String,
    aiProfileId: AiId.parse(row['ai_profile_id'] as String),
    capability: ProviderCapability.values.byName(row['capability'] as String),
    providerId: row['provider_id'] as String,
    model: row['model'] as String,
  );

  Future<Result<BindingView>> _get(
    Tx tx,
    AiId ai,
    ProviderCapability capability,
  ) async {
    final rows = await tx.query(
      '''
SELECT owner_id, ai_profile_id, capability, provider_id, model
FROM model_bindings WHERE owner_id = ? AND ai_profile_id = ? AND capability = ?
''',
      [_ownerId, ai.value, capability.name],
    );
    return rows.isEmpty
        ? err(FailureCode.notFound, 'Binding not found')
        : Ok(_view(rows.single));
  }

  Future<Result<void>> _providerAvailable(
    Tx tx,
    String providerId,
    ProviderCapability capability,
  ) async {
    // json_each checks exact array members, never substrings (chat != chatFast).
    final rows = await tx.query(
      '''
SELECT enabled, EXISTS (
  SELECT 1 FROM json_each(providers.capabilities) WHERE value = ?
) AS capable
FROM providers WHERE owner_id = ? AND id = ?
''',
      [capability.name, _ownerId, providerId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'Provider not found');
    if (rows.single['enabled'] != 1 || rows.single['capable'] != 1) {
      return err(
        FailureCode.modelUnavailable,
        'Provider capability unavailable',
      );
    }
    return const Ok(null);
  }

  Future<Result<BindingView>> set(
    AiId ai,
    ProviderCapability capability, {
    required String providerId,
    required String model,
  }) => _withAi(ai, (tx, _) async {
    if (model.trim().isEmpty ||
        model.trim() != model ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(model)) {
      return err(FailureCode.invalidArgument, 'Invalid model');
    }
    final available = await _providerAvailable(tx, providerId, capability);
    if (available case Err<void>(:final failure)) return Err(failure);
    await tx.execute(
      '''
INSERT INTO model_bindings (owner_id, ai_profile_id, capability, provider_id, model)
VALUES (?, ?, ?, ?, ?)
ON CONFLICT(owner_id, ai_profile_id, capability)
DO UPDATE SET provider_id = excluded.provider_id, model = excluded.model
''',
      [_ownerId, ai.value, capability.name, providerId, model],
    );
    return _get(tx, ai, capability);
  });

  Future<Result<BindingView>> get(AiId ai, ProviderCapability capability) =>
      _withAi(ai, (tx, _) => _get(tx, ai, capability));

  Future<Result<ResolvedBinding>> resolve(
    AiId ai,
    ProviderCapability capability,
  ) => _withAi(ai, (tx, account) async {
    final binding = await _get(tx, ai, capability);
    if (binding case Err<BindingView>(:final failure)) return Err(failure);
    final view = binding.value;
    final available = await _providerAvailable(tx, view.providerId, capability);
    if (available case Err<void>(:final failure)) {
      // A missing referenced provider also means unavailable; never mutate the
      // configuration to recover from provider state changes.
      return err(FailureCode.modelUnavailable, failure.message);
    }
    return Ok(
      ResolvedBinding(
        ownerId: _ownerId,
        aiProfileId: ai,
        aiAccountId: account,
        capability: capability,
        providerId: view.providerId,
        model: view.model,
      ),
    );
  });

  /// Idempotent within a currently authorized AI scope.
  Future<Result<void>> clear(
    AiId ai,
    ProviderCapability capability,
  ) => _withAi(ai, (tx, _) async {
    await tx.execute(
      'DELETE FROM model_bindings WHERE owner_id = ? AND ai_profile_id = ? AND capability = ?',
      [_ownerId, ai.value, capability.name],
    );
    return const Ok(null);
  });

  Future<Result<List<BindingView>>> list(AiId ai) => _withAi(
    ai,
    (tx, _) async => Ok([
      for (final row in await tx.query(
        '''
SELECT owner_id, ai_profile_id, capability, provider_id, model
FROM model_bindings WHERE owner_id = ? AND ai_profile_id = ? ORDER BY capability
''',
        [_ownerId, ai.value],
      ))
        _view(row),
    ]),
  );
}
