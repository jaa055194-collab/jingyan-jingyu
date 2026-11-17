/// M12 每日清理队列。
///
/// 规则（FR-63 / AC-14）：
/// * 视频、语音默认 90 天过期：删 blob，消息保留占位"媒体已过期清理（可重新上传）"；
/// * 到期前 7 天提醒并可一键导出（提醒只发一次）；
/// * 清理每日 03:30 单队列执行，写审计（不记正文）；
/// * 共享媒体被一方清理后，其他持有者保留占位。
///
/// 只有视频/语音会过期；图片、文字、Live2D 不进入本队列（[MediaKind] 只有这两类）。
/// 本文件不执行真实磁盘 I/O：blob 的删除由 [CleanupStore] 的持久化实现负责；
/// 内存实现与将来的 SQLite 实现共用 `test/cleanup_store_contract.dart` 契约。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../audit/audit_log.dart';

/// 会自动过期的媒体类别（仅视频、语音）。
enum MediaKind { video, voice }

/// 一条媒体 blob 及其持有者消息映射。
///
/// [holderMessageIds] 为"持有该媒体的账号 → 该账号会话里的消息 id"。共享媒体
/// 会有多个持有者；清理时每个持有者都保留占位。
class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.kind,
    required this.createdAt,
    this.holderMessageIds = const <String, String>{},
    this.blobPresent = true,
  });

  final String id;
  final MediaKind kind;
  final DateTime createdAt;
  final Map<String, String> holderMessageIds;
  final bool blobPresent;

  MediaAsset copyWith({bool? blobPresent}) => MediaAsset(
    id: id,
    kind: kind,
    createdAt: createdAt,
    holderMessageIds: holderMessageIds,
    blobPresent: blobPresent ?? this.blobPresent,
  );
}

/// 过期后回填到消息里的占位。
class MediaPlaceholder {
  const MediaPlaceholder({
    required this.assetId,
    required this.ownerAccountId,
    required this.messageId,
    required this.reason,
  });

  final String assetId;
  final String ownerAccountId;
  final String messageId;
  final String reason;
}

/// 清理存储契约：媒体 blob 状态 + 占位 + 每日运行标记。
abstract class CleanupStore {
  Future<void> addAsset(MediaAsset asset);

  Future<MediaAsset?> asset(String id);

  /// 全部可能过期的媒体（视频/语音）。服务自行按时间与 blob 状态筛选。
  Future<List<MediaAsset>> expirableAssets();

  /// 删除 blob（幂等）；仅把 [MediaAsset.blobPresent] 置 false，占位由服务写入。
  Future<void> deleteBlob(String id);

  /// 该媒体上次提醒时间；未提醒返回 null。
  Future<DateTime?> remindedAt(String id);

  Future<void> markReminded(String id, DateTime at);

  Future<void> putPlaceholder(MediaPlaceholder placeholder);

  Future<List<MediaPlaceholder>> placeholdersFor(String ownerAccountId);

  Future<bool> ranOn(String dayKey);

  Future<void> markRan(String dayKey);
}

/// 内存实现：框架与测试使用。
class InMemoryCleanupStore implements CleanupStore {
  final Map<String, MediaAsset> _assets = <String, MediaAsset>{};
  final Map<String, DateTime> _reminders = <String, DateTime>{};
  final List<MediaPlaceholder> _placeholders = <MediaPlaceholder>[];
  final Set<String> _ranDays = <String>{};

  @override
  Future<void> addAsset(MediaAsset asset) async {
    _assets[asset.id] = asset;
  }

  @override
  Future<MediaAsset?> asset(String id) async => _assets[id];

  @override
  Future<List<MediaAsset>> expirableAssets() async => _assets.values.toList();

  @override
  Future<void> deleteBlob(String id) async {
    final existing = _assets[id];
    if (existing != null) {
      _assets[id] = existing.copyWith(blobPresent: false);
    }
  }

  @override
  Future<DateTime?> remindedAt(String id) async => _reminders[id];

  @override
  Future<void> markReminded(String id, DateTime at) async {
    _reminders[id] = at;
  }

  @override
  Future<void> putPlaceholder(MediaPlaceholder placeholder) async {
    _placeholders.add(placeholder);
  }

  @override
  Future<List<MediaPlaceholder>> placeholdersFor(String ownerAccountId) async =>
      [
        for (final p in _placeholders)
          if (p.ownerAccountId == ownerAccountId) p,
      ];

  @override
  Future<bool> ranOn(String dayKey) async => _ranDays.contains(dayKey);

  @override
  Future<void> markRan(String dayKey) async {
    _ranDays.add(dayKey);
  }
}

/// 一次清理运行的可观察结果。
class CleanupRunReport {
  const CleanupRunReport({
    required this.dayKey,
    required this.alreadyRan,
    required this.remindedCount,
    required this.expiredCount,
    required this.placeholderCount,
  });

  final String dayKey;
  final bool alreadyRan;
  final int remindedCount;
  final int expiredCount;
  final int placeholderCount;

  Map<String, Object?> toJson() => {
    'dayKey': dayKey,
    'alreadyRan': alreadyRan,
    'remindedCount': remindedCount,
    'expiredCount': expiredCount,
    'placeholderCount': placeholderCount,
  };
}

/// 每日清理服务。
class CleanupService {
  CleanupService({
    required CleanupStore store,
    this.clock = const SystemClock(),
    AuditLog? audit,
    this.ttl = const Duration(days: 90),
    this.reminderLead = const Duration(days: 7),
  }) : _store = store,
       _audit = audit;

  static const String placeholderReason = '媒体已过期清理（可重新上传）';

  final CleanupStore _store;
  final AuditLog? _audit;
  final Clock clock;
  final Duration ttl;
  final Duration reminderLead;

  /// 下一个 03:30（严格晚于 [now]）；[now] 是 UTC 时返回 UTC，是本地时返回本地。
  static DateTime nextScheduledRun(DateTime now) {
    final candidate = now.isUtc
        ? DateTime.utc(now.year, now.month, now.day, 3, 30)
        : DateTime(now.year, now.month, now.day, 3, 30);
    if (candidate.isAfter(now)) return candidate;
    return now.isUtc
        ? DateTime.utc(now.year, now.month, now.day + 1, 3, 30)
        : DateTime(now.year, now.month, now.day + 1, 3, 30);
  }

  /// 单队列处理提醒与过期。每天只运行一次（按 [dayKey] 幂等）。
  Future<Result<CleanupRunReport>> run({DateTime? at}) async {
    final now = (at ?? clock.now()).toUtc();
    final day = dayKey(now);
    if (await _store.ranOn(day)) {
      return Ok(
        CleanupRunReport(
          dayKey: day,
          alreadyRan: true,
          remindedCount: 0,
          expiredCount: 0,
          placeholderCount: 0,
        ),
      );
    }

    final assets =
        (await _store.expirableAssets())
            .where((asset) => asset.blobPresent)
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

    final remindThreshold = ttl - reminderLead;
    var reminded = 0;
    var expired = 0;
    var placeholders = 0;

    for (final asset in assets) {
      final age = now.difference(asset.createdAt.toUtc());
      if (age >= ttl) {
        await _store.deleteBlob(asset.id);
        for (final holder in asset.holderMessageIds.entries) {
          await _store.putPlaceholder(
            MediaPlaceholder(
              assetId: asset.id,
              ownerAccountId: holder.key,
              messageId: holder.value,
              reason: placeholderReason,
            ),
          );
          placeholders++;
        }
        expired++;
        await _audit?.record(
          AuditEntry(
            at: now,
            actorId: 'system',
            action: 'media.cleanup.expire',
            targetKind: 'media',
            targetId: asset.id,
            meta: {
              'kind': asset.kind.name,
              'holders': asset.holderMessageIds.length,
            },
          ),
        );
      } else if (age >= remindThreshold &&
          await _store.remindedAt(asset.id) == null) {
        await _store.markReminded(asset.id, now);
        reminded++;
        await _audit?.record(
          AuditEntry(
            at: now,
            actorId: 'system',
            action: 'media.cleanup.remind',
            targetKind: 'media',
            targetId: asset.id,
            meta: {'kind': asset.kind.name},
          ),
        );
      }
    }

    await _store.markRan(day);
    return Ok(
      CleanupRunReport(
        dayKey: day,
        alreadyRan: false,
        remindedCount: reminded,
        expiredCount: expired,
        placeholderCount: placeholders,
      ),
    );
  }

  /// Owner-scoped read-only retention preview. Does NOT delete blobs, write
  /// reminders or audit; real deletion stays with [run] (daily system task).
  Future<RetentionPreview> retentionPreview({
    required String ownerAccountId,
    DateTime? at,
  }) async {
    final now = (at ?? clock.now()).toUtc();
    final remindThreshold = ttl - reminderLead;
    final remindSoon = <MediaKind, int>{};
    final expiring = <MediaKind, int>{};
    final totalHeld = <MediaKind, int>{};

    for (final asset in await _store.expirableAssets()) {
      if (!asset.blobPresent) continue;
      if (!asset.holderMessageIds.containsKey(ownerAccountId)) continue;
      totalHeld[asset.kind] = (totalHeld[asset.kind] ?? 0) + 1;
      final age = now.difference(asset.createdAt.toUtc());
      if (age >= ttl) {
        expiring[asset.kind] = (expiring[asset.kind] ?? 0) + 1;
      } else if (age >= remindThreshold &&
          await _store.remindedAt(asset.id) == null) {
        remindSoon[asset.kind] = (remindSoon[asset.kind] ?? 0) + 1;
      }
    }
    return RetentionPreview(
      dayKey: dayKey(now),
      remindSoon: remindSoon,
      expiring: expiring,
      totalHeld: totalHeld,
    );
  }
}

/// 一个 owner 视角的保留策略预览。只读；执行仍归 [CleanupService.run]。
class RetentionPreview {
  const RetentionPreview({
    required this.dayKey,
    required this.remindSoon,
    required this.expiring,
    required this.totalHeld,
  });

  final String dayKey;

  /// 将在提醒窗口内（≥ ttl-lead 且未提醒过）的资产计数，按类别。
  final Map<MediaKind, int> remindSoon;

  /// 已到期（≥ ttl）即将被删除 blob 的资产计数，按类别。
  final Map<MediaKind, int> expiring;

  /// 该 owner 仍是持有者、blob 仍在的全部资产计数，按类别。
  final Map<MediaKind, int> totalHeld;

  Map<String, Object?> toJson() => {
    'dayKey': dayKey,
    'remindSoon': {
      for (final kind in MediaKind.values) kind.name: remindSoon[kind] ?? 0,
    },
    'expiring': {
      for (final kind in MediaKind.values) kind.name: expiring[kind] ?? 0,
    },
    'totalHeld': {
      for (final kind in MediaKind.values) kind.name: totalHeld[kind] ?? 0,
    },
  };
}
