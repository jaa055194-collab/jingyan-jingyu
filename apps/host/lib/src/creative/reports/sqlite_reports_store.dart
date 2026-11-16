/// [ReportsStore] 的 SQLite 实现。
///
/// 与 [InMemoryReportsStore] 共用 `test/creative_reports_store_contract.dart` 契约测试。
/// 私有数据按 owner_account_id 过滤（FR-67 / NFR-09），查询一律带调用者。
/// 报告正文（letter 等）存于 report_json 列；接入 M01 列加密时可改为 `cipher` 包装，
/// 契约不变。
library;

import 'dart:convert';

import '../../storage/database.dart';
import 'reports_models.dart';
import 'reports_store.dart';

final class SqliteReportsStore implements ReportsStore {
  SqliteReportsStore({required this.database});

  final Database database;

  static const String _columns =
      'owner_account_id, ai_id, kind, period_key, status, updated_at, deferred_to, report_json';

  @override
  Future<ReportRecord?> find({
    required String ownerAccountId,
    required String aiId,
    required ReportKind kind,
    required String periodKey,
  }) async {
    final rows = await database.query(
      'SELECT $_columns FROM creative_reports '
      'WHERE owner_account_id = ? AND ai_id = ? AND kind = ? AND period_key = ?',
      [ownerAccountId, aiId, kind.name, periodKey],
    );
    return rows.isEmpty ? null : _fromRow(rows.single);
  }

  @override
  Future<void> upsert(ReportRecord record) async {
    await database.execute(
      '''
INSERT INTO creative_reports(
  owner_account_id, ai_id, kind, period_key, status, updated_at, deferred_to, report_json
) VALUES(?,?,?,?,?,?,?,?)
ON CONFLICT(owner_account_id, ai_id, kind, period_key) DO UPDATE SET
  status = excluded.status,
  updated_at = excluded.updated_at,
  deferred_to = excluded.deferred_to,
  report_json = excluded.report_json
''',
      [
        record.ownerAccountId,
        record.aiId,
        record.kind.name,
        record.periodKey,
        record.status.name,
        record.updatedAt.toUtc().toIso8601String(),
        record.deferredTo?.toUtc().toIso8601String(),
        record.report == null ? null : jsonEncode(record.report!.toJson()),
      ],
    );
  }

  @override
  Future<List<ReportRecord>> listByOwner(String ownerAccountId) async {
    final rows = await database.query(
      'SELECT $_columns FROM creative_reports WHERE owner_account_id = ? '
      'ORDER BY updated_at, ai_id, kind, period_key',
      [ownerAccountId],
    );
    return [for (final row in rows) _fromRow(row)];
  }

  ReportRecord _fromRow(Map<String, Object?> row) {
    final rawReport = row['report_json'];
    final rawDeferred = row['deferred_to'];
    return ReportRecord(
      ownerAccountId: row['owner_account_id'] as String,
      aiId: row['ai_id'] as String,
      kind: ReportKind.values.byName(row['kind'] as String),
      periodKey: row['period_key'] as String,
      status: ReportStatus.values.byName(row['status'] as String),
      updatedAt: DateTime.parse(row['updated_at'] as String),
      deferredTo: rawDeferred is String && rawDeferred.isNotEmpty
          ? DateTime.parse(rawDeferred)
          : null,
      report: rawReport is String && rawReport.isNotEmpty
          ? RelationshipReport.fromJson(
              (jsonDecode(rawReport) as Map).cast<String, Object?>(),
            )
          : null,
    );
  }
}
