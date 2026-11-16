/// [CleanupStore] 的 SQLite 持久化实现。
///
/// schema 见 `lifecycle_migrations.dart`（1205 media/renew/placeholder/runs）。
/// 通过 `test/cleanup_store_contract.dart` 同一契约测试。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'cleanup.dart';

class SqliteCleanupStore implements CleanupStore {
  SqliteCleanupStore({
    required Database database,
    Clock clock = const SystemClock(),
  }) : _database = database,
       _clock = clock;

  final Database _database;
  final Clock _clock;

  @override
  Future<void> addAsset(MediaAsset asset) async {
    await _database.transaction((tx) async {
      await tx.execute(
        '''
INSERT INTO media_assets(id, kind, created_at, blob_present) VALUES (?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  kind = excluded.kind,
  created_at = excluded.created_at,
  blob_present = excluded.blob_present
''',
        [
          asset.id,
          asset.kind.name,
          asset.createdAt.toUtc().toIso8601String(),
          asset.blobPresent ? 1 : 0,
        ],
      );
      await tx.execute(
        'DELETE FROM media_asset_holders WHERE asset_id = ?',
        [asset.id],
      );
      for (final holder in asset.holderMessageIds.entries) {
        await tx.execute(
          'INSERT INTO media_asset_holders(asset_id, account_id, message_id) VALUES (?, ?, ?)',
          [asset.id, holder.key, holder.value],
        );
      }
    });
  }

  MediaAsset _toAsset(
    Map<String, Object?> row,
    List<Map<String, Object?>> holders,
  ) => MediaAsset(
    id: row['id']! as String,
    kind: row['kind'] == 'voice' ? MediaKind.voice : MediaKind.video,
    createdAt: DateTime.parse(row['created_at']! as String),
    holderMessageIds: {
      for (final holder in holders)
        holder['account_id']! as String: holder['message_id']! as String,
    },
    blobPresent: (row['blob_present']! as int) != 0,
  );

  Future<List<Map<String, Object?>>> _holders(String assetId) =>
      _database.query(
        'SELECT account_id, message_id FROM media_asset_holders WHERE asset_id = ?',
        [assetId],
      );

  @override
  Future<MediaAsset?> asset(String id) async {
    final rows = await _database.query(
      'SELECT id, kind, created_at, blob_present FROM media_assets WHERE id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return _toAsset(rows.single, await _holders(id));
  }

  @override
  Future<List<MediaAsset>> expirableAssets() async {
    final rows = await _database.query(
      'SELECT id, kind, created_at, blob_present FROM media_assets',
    );
    final assets = <MediaAsset>[];
    for (final row in rows) {
      assets.add(_toAsset(row, await _holders(row['id']! as String)));
    }
    return assets;
  }

  @override
  Future<void> deleteBlob(String id) async {
    await _database.execute(
      'UPDATE media_assets SET blob_present = 0 WHERE id = ?',
      [id],
    );
  }

  @override
  Future<DateTime?> remindedAt(String id) async {
    final rows = await _database.query(
      'SELECT reminded_at FROM media_reminders WHERE asset_id = ?',
      [id],
    );
    if (rows.isEmpty) return null;
    return DateTime.parse(rows.single['reminded_at']! as String);
  }

  @override
  Future<void> markReminded(String id, DateTime at) async {
    await _database.execute(
      '''
INSERT INTO media_reminders(asset_id, reminded_at) VALUES (?, ?)
ON CONFLICT(asset_id) DO UPDATE SET reminded_at = excluded.reminded_at
''',
      [id, at.toUtc().toIso8601String()],
    );
  }

  @override
  Future<void> putPlaceholder(MediaPlaceholder placeholder) async {
    await _database.execute(
      '''
INSERT INTO media_placeholders(asset_id, owner_account_id, message_id, reason)
VALUES (?, ?, ?, ?)
ON CONFLICT(asset_id, owner_account_id, message_id) DO UPDATE SET
  reason = excluded.reason
''',
      [
        placeholder.assetId,
        placeholder.ownerAccountId,
        placeholder.messageId,
        placeholder.reason,
      ],
    );
  }

  @override
  Future<List<MediaPlaceholder>> placeholdersFor(String ownerAccountId) async {
    final rows = await _database.query(
      '''
SELECT asset_id, owner_account_id, message_id, reason FROM media_placeholders
WHERE owner_account_id = ?
ORDER BY rowid
''',
      [ownerAccountId],
    );
    return [
      for (final row in rows)
        MediaPlaceholder(
          assetId: row['asset_id']! as String,
          ownerAccountId: row['owner_account_id']! as String,
          messageId: row['message_id']! as String,
          reason: row['reason']! as String,
        ),
    ];
  }

  @override
  Future<bool> ranOn(String dayKey) async {
    final rows = await _database.query(
      'SELECT 1 FROM cleanup_runs WHERE day_key = ?',
      [dayKey],
    );
    return rows.isNotEmpty;
  }

  @override
  Future<void> markRan(String dayKey) async {
    await _database.execute(
      '''
INSERT INTO cleanup_runs(day_key, ran_at) VALUES (?, ?)
ON CONFLICT(day_key) DO UPDATE SET ran_at = excluded.ran_at
''',
      [dayKey, _clock.now().toUtc().toIso8601String()],
    );
  }
}
