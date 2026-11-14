import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';

/// Bounded audit envelopes. Authorization and projection share a transaction;
/// no metadata/content hydration or audit-source changes are performed.
final class AdminAuditReader {
  AdminAuditReader({required this.database, required this.clock});
  final Database database;
  final Clock clock;

  Future<Result<Map<String, Object?>>> page({
    required String bearer,
    required String accountId,
    required String deviceId,
    required int afterId,
    required int limit,
  }) async {
    if (afterId < 0 || limit < 1 || limit > 100) {
      return err(FailureCode.invalidArgument, 'Invalid audit page');
    }
    if (bearer.length != 22) {
      return err(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final digest = sha256.convert(utf8.encode(bearer)).toString();
    return database.transaction((tx) async {
      // Match AccountsDomain access semantics: a device must still have a
      // refresh row, but that refresh token need not be unexpired for access.
      final credentials = await tx.query(
        '''
SELECT a.kind, a.is_admin, a.disabled
FROM device d JOIN account a ON a.id=d.account_id
JOIN refresh_token r ON r.device_id=d.id
WHERE d.access_hash=? AND d.id=? AND d.account_id=? AND d.access_expires>?
''',
        [digest, deviceId, accountId, clock.now().millisecondsSinceEpoch],
      );
      if (credentials.isEmpty || credentials.single['disabled'] != 0) {
        return err(FailureCode.unauthenticated, 'Invalid credentials');
      }
      final account = credentials.single;
      if (account['kind'] != 'human' || account['is_admin'] != 1) {
        return err(FailureCode.forbidden, 'Administrator required');
      }
      final rows = await tx.query(
        '''
SELECT id, at, actor_id, action, target_kind, target_id
FROM audit_log WHERE id>? ORDER BY id ASC LIMIT ?
''',
        [afterId, limit + 1],
      );
      final returned = rows.take(limit).toList();
      return Ok<Map<String, Object?>>({
        'entries': [
          for (final row in returned)
            {
              'id': (row['id'] as int).toString(),
              'at': row['at'],
              'actorId': row['actor_id'],
              'action': row['action'],
              'targetKind': row['target_kind'],
              'targetId': row['target_id'],
            },
        ],
        'nextAfterId': returned.isEmpty
            ? afterId.toString()
            : (returned.last['id'] as int).toString(),
        'hasMore': rows.length > limit,
      });
    });
  }
}
