import '../storage/database.dart';
import 'reports/reports_models.dart';

class CreativeActivityWriteDenied implements Exception {
  const CreativeActivityWriteDenied();
}

abstract interface class CreativeActivityWriter {
  Future<void> record({
    required String ownerAccountId,
    required String aiProfileId,
    required CreativeScope scope,
    required CreativeActivityKind kind,
    required String dayKey,
    String label = '',
    int value = 0,
  });
}

/// Trusted module-only writer for sanitized aggregates. It accepts no message body.
class SqliteCreativeActivityWriter implements CreativeActivityWriter {
  SqliteCreativeActivityWriter({required this.database});

  final Database database;

  @override
  Future<void> record({
    required String ownerAccountId,
    required String aiProfileId,
    required CreativeScope scope,
    required CreativeActivityKind kind,
    required String dayKey,
    String label = '',
    int value = 0,
  }) async {
    if (!_validId(ownerAccountId) || !_validId(aiProfileId)) {
      throw const FormatException('invalid creative activity identity');
    }
    if (!_validDayKey(dayKey)) {
      throw const FormatException('invalid creative activity day');
    }
    if (label.length > 64 || label.contains(RegExp(r'[\r\n\x00-\x1f]'))) {
      throw const FormatException('invalid creative activity label');
    }
    if (value < 0 || value > 1000000) {
      throw const FormatException('invalid creative activity value');
    }
    await database.transaction((tx) async {
      final ownership = await tx.query(
        '''
SELECT 1 FROM ai_profile p
JOIN account ai ON ai.id=p.account_id AND ai.kind='ai' AND ai.disabled=0
JOIN ai_operator o ON o.ai_id=ai.id AND o.operator_id=?
JOIN account owner ON owner.id=o.operator_id AND owner.kind='human' AND owner.disabled=0
WHERE p.id=?
''',
        [ownerAccountId, aiProfileId],
      );
      if (ownership.isEmpty) throw const CreativeActivityWriteDenied();
      final grants = await tx.query(
        'SELECT 1 FROM creative_authorizations WHERE owner_account_id=? AND ai_profile_id=? AND scope=?',
        [ownerAccountId, aiProfileId, scope.name],
      );
      if (grants.isEmpty) throw const CreativeActivityWriteDenied();
      await tx.execute(
        'INSERT INTO creative_activity(owner_account_id, ai_id, scope, kind, day_key, label, value) VALUES(?,?,?,?,?,?,?)',
        [
          ownerAccountId,
          aiProfileId,
          scope.name,
          kind.name,
          dayKey,
          label,
          value,
        ],
      );
    });
  }

  bool _validId(String value) =>
      value.isNotEmpty &&
      value.length <= 128 &&
      !value.contains(RegExp(r'[\r\n\x00-\x20]'));

  bool _validDayKey(String value) {
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value);
    if (match == null) return false;
    final year = int.parse(match[1]!);
    final month = int.parse(match[2]!);
    final day = int.parse(match[3]!);
    final date = DateTime.utc(year, month, day);
    return date.year == year && date.month == month && date.day == day;
  }
}
