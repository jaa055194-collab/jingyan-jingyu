import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'creative_adapters.dart';
import 'reports/reports_models.dart';

class CreativeAuthorizationOwnershipException implements Exception {
  const CreativeAuthorizationOwnershipException();
}

class SqliteCreativeAuthorizationStore implements CreativeAuthorizationPolicy {
  SqliteCreativeAuthorizationStore({required this.database, Clock? clock})
    : _clock = clock ?? const SystemClock();

  final Database database;
  final Clock _clock;

  Future<void> setAuthorization({
    required String ownerAccountId,
    required String aiProfileId,
    required Set<CreativeScope> scopes,
    required bool radioEnabled,
  }) async {
    // Capture mutable caller input before the transaction is queued or awaits.
    final scopeSnapshot = Set<CreativeScope>.of(scopes);
    await database.transaction((tx) async {
      final owned = await tx.query(
        '''
SELECT 1
FROM ai_profile p
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=?
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=?
''',
        [ownerAccountId, aiProfileId],
      );
      if (owned.isEmpty) throw const CreativeAuthorizationOwnershipException();
      await tx.execute(
        'DELETE FROM creative_authorizations WHERE owner_account_id=? AND ai_profile_id=?',
        [ownerAccountId, aiProfileId],
      );
      final grantedAt = _clock.now().toUtc().toIso8601String();
      for (final scope in scopeSnapshot) {
        await tx.execute(
          'INSERT INTO creative_authorizations(owner_account_id, ai_profile_id, scope, granted_at) VALUES(?,?,?,?)',
          [ownerAccountId, aiProfileId, scope.name, grantedAt],
        );
      }
      await tx.execute(
        '''
INSERT INTO creative_radio_authorizations(owner_account_id, ai_profile_id, enabled, updated_at)
VALUES(?,?,?,?)
ON CONFLICT(owner_account_id, ai_profile_id) DO UPDATE SET
 enabled=excluded.enabled, updated_at=excluded.updated_at
''',
        [ownerAccountId, aiProfileId, radioEnabled ? 1 : 0, grantedAt],
      );
    });
  }

  @override
  Future<Set<CreativeScope>> scopesFor({
    required String ownerAccountId,
    required String aiProfileId,
  }) async {
    final rows = await database.query(
      '''
SELECT g.scope
FROM creative_authorizations g
JOIN ai_profile p ON p.id=g.ai_profile_id
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=g.owner_account_id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE g.owner_account_id=? AND g.ai_profile_id=?
''',
      [ownerAccountId, aiProfileId],
    );
    final scopes = <CreativeScope>{};
    for (final row in rows) {
      final name = row['scope'] as String;
      for (final scope in CreativeScope.values) {
        if (scope.name == name) scopes.add(scope);
      }
    }
    return scopes;
  }

  @override
  Future<bool> radioEnabledFor({
    required String ownerAccountId,
    required String aiProfileId,
  }) async {
    final rows = await database.query(
      '''
SELECT g.enabled
FROM creative_radio_authorizations g
JOIN ai_profile p ON p.id=g.ai_profile_id
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=g.owner_account_id
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE g.owner_account_id=? AND g.ai_profile_id=?
''',
      [ownerAccountId, aiProfileId],
    );
    return rows.isNotEmpty && rows.single['enabled'] == 1;
  }
}
