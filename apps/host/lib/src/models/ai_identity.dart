import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import '../storage/migrations.dart';

/// Minimal persistent identity bridge for M05/M06. No personality data or roles.
/// The coordinator adds this migration to its migration list separately.
const Migration aiIdentityMigration = Migration(501, 'AI identity mapping', '''
CREATE TABLE ai_profile (
  id TEXT PRIMARY KEY NOT NULL,
  account_id TEXT NOT NULL UNIQUE REFERENCES account(id) ON DELETE CASCADE
);
''');

/// A profile identity and its currently authorized AI principal and operator.
final class AiIdentity {
  const AiIdentity({
    required this.profileId,
    required this.aiAccountId,
    required this.ownerAccountId,
  });

  final AiId profileId;
  final AccountId aiAccountId;
  final AccountId ownerAccountId;
}

/// Construct only from the trusted authenticated principal's owner scope.
/// Admin status grants no additional access. Ownership and account validity are
/// read from the canonical account/ai_operator tables on every operation.
final class AiIdentityResolver {
  AiIdentityResolver.forOwner({required String ownerId, required Database db})
    : _ownerId = validateId(ownerId, kind: 'owner'),
      _db = db;

  final String _ownerId;
  final Database _db;
  final Random _random = Random.secure();

  static const _visibleProfile = '''
SELECT p.id, p.account_id, o.operator_id
FROM ai_profile p
JOIN account a ON a.id = p.account_id AND a.kind = 'ai' AND a.disabled = 0
JOIN ai_operator o ON o.ai_id = a.id
WHERE o.operator_id = ?
''';

  Result<AiIdentity> _result(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) {
      return err(FailureCode.notFound, 'AI identity not found');
    }
    final row = rows.single;
    return Ok(
      AiIdentity(
        profileId: AiId.parse(row['id'] as String),
        aiAccountId: AccountId.parse(row['account_id'] as String),
        ownerAccountId: AccountId.parse(row['operator_id'] as String),
      ),
    );
  }

  /// Explicitly register a valid AI currently operated by this owner.
  /// Repeated registrations retain the same persisted profile identity.
  Future<Result<AiIdentity>> register(AccountId aiAccount) => _db.transaction((
    tx,
  ) async {
    final accounts = await tx.query(
      '''
SELECT a.id
FROM account a
JOIN ai_operator o ON o.ai_id = a.id
WHERE a.id = ? AND a.kind = 'ai' AND a.disabled = 0 AND o.operator_id = ?
''',
      [aiAccount.value, _ownerId],
    );
    if (accounts.isEmpty) {
      return err<AiIdentity>(FailureCode.notFound, 'AI identity not found');
    }
    final existing = await tx.query('$_visibleProfile AND p.account_id = ?', [
      _ownerId,
      aiAccount.value,
    ]);
    if (existing.isNotEmpty) return _result(existing);

    // Profile IDs use independent cryptographically random bytes. Reject an
    // accidental equality with the principal ID or an existing profile ID.
    late String id;
    do {
      id =
          'ai_${List.generate(24, (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
    } while (id == aiAccount.value ||
        (await tx.query('SELECT id FROM ai_profile WHERE id = ?', [
          id,
        ])).isNotEmpty);
    await tx.execute('INSERT INTO ai_profile (id, account_id) VALUES (?, ?)', [
      id,
      aiAccount.value,
    ]);
    return _result(
      await tx.query('$_visibleProfile AND p.id = ?', [_ownerId, id]),
    );
  });

  /// Resolve an existing mapping without implicitly registering any account.
  Future<Result<AiIdentity>> resolve(AiId profileId) async => _result(
    await _db.query('$_visibleProfile AND p.id = ?', [
      _ownerId,
      profileId.value,
    ]),
  );
}
