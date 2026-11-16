/// M12 quota 接入层：把纯 [QuotaPolicy] 与账号用量账本、磁盘状态、并发闸门接在一起。
///
/// 本文件不执行磁盘 I/O 或网络；[QuotaStore] 的持久化实现（SQLite）必须通过
/// `test/quota_store_contract.dart` 的同一组契约测试，见 docs/modules/M12-lifecycle.md。
library;

import 'package:jingyu_core/jingyu_core.dart';

import 'quota.dart';

/// 磁盘剩余/总量（字节）。
class DiskSpace {
  const DiskSpace({required this.freeBytes, required this.totalBytes});

  final int freeBytes;
  final int totalBytes;

  /// 未知磁盘信息时的保守默认：100% 空闲，不触发磁盘告警。
  static const DiskSpace unknown = DiskSpace(freeBytes: 1, totalBytes: 1);
}

/// 每账号配额用量账本 + 全局磁盘状态。
///
/// 实现只做计数，不做策略判断；非法输入（负字节、free > total）抛
/// [ArgumentError]，属于调用方编程缺陷，不是可预期业务失败。
abstract class QuotaStore {
  Future<int> usedBytes(String accountId);

  Future<void> addUsage(String accountId, int bytes);

  Future<void> setUsedBytes(String accountId, int bytes);

  Future<DiskSpace> diskSpace();

  Future<void> setDiskSpace({required int freeBytes, required int totalBytes});
}

/// 内存实现：框架与测试使用。
class InMemoryQuotaStore implements QuotaStore {
  final Map<String, int> _used = <String, int>{};
  DiskSpace _disk = DiskSpace.unknown;

  @override
  Future<int> usedBytes(String accountId) async => _used[accountId] ?? 0;

  @override
  Future<void> addUsage(String accountId, int bytes) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', '用量增量不能为负');
    }
    _used[accountId] = (_used[accountId] ?? 0) + bytes;
  }

  @override
  Future<void> setUsedBytes(String accountId, int bytes) async {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', '用量不能为负');
    }
    _used[accountId] = bytes;
  }

  @override
  Future<DiskSpace> diskSpace() async => _disk;

  @override
  Future<void> setDiskSpace({
    required int freeBytes,
    required int totalBytes,
  }) async {
    if (freeBytes < 0 || totalBytes <= 0 || freeBytes > totalBytes) {
      throw ArgumentError('非法磁盘空间：free=$freeBytes total=$totalBytes');
    }
    _disk = DiskSpace(freeBytes: freeBytes, totalBytes: totalBytes);
  }
}

/// 面向路由/上传流程的 quota 门面。
class QuotaService {
  QuotaService({
    required QuotaStore store,
    this.quotaBytes = QuotaPolicy.defaultQuotaBytes,
    UploadGate? gate,
  }) : _store = store,
       gate = gate ?? UploadGate();

  final QuotaStore _store;
  final int quotaBytes;

  /// 单账号并发上传 ≤3（B-6）。
  final UploadGate gate;

  /// 结合账本用量与磁盘状态评估一次上传；不写账。
  Future<Result<QuotaDecision>> evaluate({
    required String accountId,
    required UploadKind kind,
    required int uploadBytes,
  }) async {
    if (accountId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '账号标识不能为空');
    }
    final used = await _store.usedBytes(accountId);
    final disk = await _store.diskSpace();
    return QuotaPolicy.evaluate(
      usedBytes: used,
      quotaBytes: quotaBytes,
      kind: kind,
      uploadBytes: uploadBytes,
      diskFreeBytes: disk.freeBytes,
      diskTotalBytes: disk.totalBytes,
    );
  }

  /// 上传成功后按 [QuotaDecision.countedBytes] 记账（文字/图片为 0，不累加）。
  Future<Result<void>> commit({
    required String accountId,
    required QuotaDecision decision,
  }) async {
    if (decision.countedBytes > 0) {
      await _store.addUsage(accountId, decision.countedBytes);
    }
    return const Ok<void>(null);
  }

  /// 当前已用配额字节（只读）。
  Future<int> usedBytes(String accountId) => _store.usedBytes(accountId);

  /// 当前磁盘状态（只读）。
  Future<DiskSpace> diskSpace() => _store.diskSpace();

  Result<UploadPermit> acquireUploadSlot(String accountId) =>
      gate.acquire(accountId);

  Result<void> releaseUploadSlot(UploadPermit permit) => gate.release(permit);
}
