/// [DepartureStore] 的 SQLite 持久化实现。
///
/// schema 见 `lifecycle_migrations.dart`（1206 departure_ledger，object_counts 存 JSON）。
/// 通过 `test/departure_store_contract.dart` 同一契约测试。
library;

import 'dart:convert';

import '../storage/database.dart';
import 'departure.dart';

class SqliteDepartureStore implements DepartureStore {
  SqliteDepartureStore({required Database database, this.retentionDays = 30})
    : _database = database;

  final Database _database;
  final int retentionDays;

  DepartureSurvey _toSurvey(Map<String, Object?> row) {
    final decoded = jsonDecode(row['object_counts']! as String) as Map;
    return DepartureSurvey(
      objectCounts: {
        for (final entry in decoded.entries)
          entry.key as String: (entry.value as num).toInt(),
      },
      momentsToAnonymize: (row['moments_to_anonymize']! as num).toInt(),
    );
  }

  static const DepartureSurvey _empty = DepartureSurvey(
    objectCounts: <String, int>{},
    momentsToAnonymize: 0,
  );

  @override
  Future<DepartureSurvey> survey(String accountId) async {
    final rows = await _database.query(
      'SELECT object_counts, moments_to_anonymize FROM departure_ledger WHERE account_id = ?',
      [accountId],
    );
    if (rows.isEmpty) return _empty;
    return _toSurvey(rows.single);
  }

  @override
  Future<DepartureSurvey> purge(String accountId) async =>
      _database.transaction((tx) async {
        final rows = await tx.query(
          'SELECT object_counts, moments_to_anonymize FROM departure_ledger WHERE account_id = ?',
          [accountId],
        );
        if (rows.isEmpty) return _empty;
        await tx.execute(
          'DELETE FROM departure_ledger WHERE account_id = ?',
          [accountId],
        );
        return _toSurvey(rows.single);
      });

  @override
  Future<int> backupRetentionDays() async => retentionDays;
}
