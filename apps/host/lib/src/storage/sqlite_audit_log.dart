import 'dart:convert';

import '../audit/audit_log.dart';
import 'database.dart';

/// SQLite-backed implementation of the system AuditLog contract.
final class SqliteAuditLog implements AuditLog {
  SqliteAuditLog(this.database);
  final Database database;

  @override
  Future<void> record(AuditEntry entry) async {
    await database.execute(
      'INSERT INTO audit_log (at, actor_id, action, target_kind, target_id, meta) VALUES (?, ?, ?, ?, ?, ?)',
      [
        entry.at.toUtc().toIso8601String(),
        entry.actorId,
        entry.action,
        entry.targetKind,
        entry.targetId,
        jsonEncode(entry.meta),
      ],
    );
  }

  @override
  Future<List<AuditEntry>> forTarget(String targetKind, String targetId) async {
    final rows = await database.query(
      'SELECT at, actor_id, action, target_kind, target_id, meta FROM audit_log WHERE target_kind = ? AND target_id = ? ORDER BY id',
      [targetKind, targetId],
    );
    return [
      for (final row in rows)
        AuditEntry(
          at: DateTime.parse(row['at'] as String),
          actorId: row['actor_id'] as String,
          action: row['action'] as String,
          targetKind: row['target_kind'] as String,
          targetId: row['target_id'] as String,
          meta: (jsonDecode(row['meta'] as String) as Map)
              .cast<String, Object?>(),
        ),
    ];
  }
}
