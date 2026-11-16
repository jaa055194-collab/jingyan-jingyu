/// [QuotaStore] 的 SQLite 持久化实现。
///
/// 通过 `test/quota_store_contract.dart` 同一契约测试；schema 见
/// `lifecycle_migrations.dart`（1200 quota 账本、1204 磁盘状态）。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'quota_service.dart';

class SqliteQuotaStore implements QuotaStore {
  SqliteQuotaStore({
    required Database database,
    Clock clock = const SystemClock(),
  }) : _database = database,
       _clock = clock;

  final Database _database;
  final Clock _clock;

  @override
  Future<int> usedBytes(String accountId) async {
    final rows = await _database.query(
      'SELECT used_bytes FROM quota WHERE account_id = ?',
      [accountId],
    );
    return rows.isEmpty ? 0 : rows.single['used_bytes']! as int;
  }

  @override
  Future<void> addUsage(String accountId, int bytes) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', '用量增量不能为负');
    }
    await _database.transaction((tx) async {
      final rows = await tx.query(
        'SELECT used_bytes FROM quota WHERE account_id = ?',
        [accountId],
      );
      final current = rows.isEmpty ? 0 : rows.single['used_bytes']! as int;
      await _write(tx, accountId, current + bytes);
    });
  }

  @override
  Future<void> setUsedBytes(String accountId, int bytes) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', '用量不能为负');
    }
    await _database.transaction((tx) async {
      await _write(tx, accountId, bytes);
    });
  }

  Future<void> _write(Tx tx, String accountId, int bytes) async {
    await tx.execute(
      '''
INSERT INTO quota(account_id, used_bytes, updated_at) VALUES (?, ?, ?)
ON CONFLICT(account_id) DO UPDATE SET
  used_bytes = excluded.used_bytes,
  updated_at = excluded.updated_at
''',
      [accountId, bytes, _clock.now().toUtc().toIso8601String()],
    );
  }

  @override
  Future<DiskSpace> diskSpace() async {
    final rows = await _database.query(
      'SELECT free_bytes, total_bytes FROM quota_disk_state WHERE id = ?',
      ['default'],
    );
    if (rows.isEmpty) return DiskSpace.unknown;
    return DiskSpace(
      freeBytes: rows.single['free_bytes']! as int,
      totalBytes: rows.single['total_bytes']! as int,
    );
  }

  @override
  Future<void> setDiskSpace({
    required int freeBytes,
    required int totalBytes,
  }) async {
    if (freeBytes < 0 || totalBytes <= 0 || freeBytes > totalBytes) {
      throw ArgumentError('非法磁盘空间：free=$freeBytes total=$totalBytes');
    }
    await _database.execute(
      '''
INSERT INTO quota_disk_state(id, free_bytes, total_bytes) VALUES (?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  free_bytes = excluded.free_bytes,
  total_bytes = excluded.total_bytes
''',
      ['default', freeBytes, totalBytes],
    );
  }
}
