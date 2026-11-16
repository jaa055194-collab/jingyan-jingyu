/// CR-03 报告的存储接口与内存实现。
///
/// 私有数据：记录带 [ReportRecord.ownerAccountId]，读取必须带调用者，
/// 仓储层强制按 owner 过滤（FR-67 / NFR-09，串数据不可见）。
library;

import 'reports_models.dart';

/// 报告记录状态。
enum ReportStatus {
  /// 已生成。
  generated,

  /// 已错过（B-4：不补）。
  missed,

  /// 预算不足，按 B4 顺延到次日再试。
  deferred,
}

/// 一次周期报告的处理记录。
class ReportRecord {
  const ReportRecord({
    required this.ownerAccountId,
    required this.aiId,
    required this.kind,
    required this.periodKey,
    required this.status,
    required this.updatedAt,
    this.deferredTo,
    this.report,
  });

  final String ownerAccountId;
  final String aiId;
  final ReportKind kind;
  final String periodKey;
  final ReportStatus status;

  /// 最近一次状态更新时间（绝对时刻）。
  final DateTime updatedAt;

  /// 仅 [ReportStatus.deferred] 有值：绝对时刻，到此时间后重试生成。
  final DateTime? deferredTo;

  /// 仅 [ReportStatus.generated] 有值。
  final RelationshipReport? report;

  ReportRecord copyWith({
    ReportStatus? status,
    DateTime? updatedAt,
    DateTime? deferredTo,
    RelationshipReport? report,
  }) => ReportRecord(
    ownerAccountId: ownerAccountId,
    aiId: aiId,
    kind: kind,
    periodKey: periodKey,
    status: status ?? this.status,
    updatedAt: updatedAt ?? this.updatedAt,
    deferredTo: deferredTo ?? this.deferredTo,
    report: report ?? this.report,
  );

  Map<String, Object?> toPayload() => {
    'kind': kind.name,
    'periodKey': periodKey,
    'status': status.name,
    'updatedAt': updatedAt.toIso8601String(),
    if (deferredTo != null) 'deferredTo': deferredTo!.toIso8601String(),
    if (report != null) 'report': report!.toPayload(),
  };
}

/// 报告仓储。
abstract class ReportsStore {
  /// 按 (owner, ai, kind, periodKey) 查记录；均必须显式传入，禁止跨用户查询。
  Future<ReportRecord?> find({
    required String ownerAccountId,
    required String aiId,
    required ReportKind kind,
    required String periodKey,
  });

  /// 插入或覆盖记录（同 (owner, ai, kind, periodKey) 唯一）。
  Future<void> upsert(ReportRecord record);

  /// 某用户的全部记录（跨用户不可见）。
  Future<List<ReportRecord>> listByOwner(String ownerAccountId);
}

/// 内存实现。SQLite 实现由 M01 完成后补，并通过同一契约测试。
class InMemoryReportsStore implements ReportsStore {
  final Map<String, ReportRecord> _records = <String, ReportRecord>{};

  String _key(String owner, String ai, ReportKind kind, String periodKey) =>
      '$owner\u0000$ai\u0000${kind.name}\u0000$periodKey';

  @override
  Future<ReportRecord?> find({
    required String ownerAccountId,
    required String aiId,
    required ReportKind kind,
    required String periodKey,
  }) async => _records[_key(ownerAccountId, aiId, kind, periodKey)];

  @override
  Future<void> upsert(ReportRecord record) async {
    _records[_key(
          record.ownerAccountId,
          record.aiId,
          record.kind,
          record.periodKey,
        )] =
        record;
  }

  @override
  Future<List<ReportRecord>> listByOwner(String ownerAccountId) async => [
    for (final record in _records.values)
      if (record.ownerAccountId == ownerAccountId) record,
  ];
}
