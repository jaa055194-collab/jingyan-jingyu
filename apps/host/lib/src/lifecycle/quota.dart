/// 纯 M12 上传配额策略；本策略不执行磁盘 I/O、上传或持久化。
///
/// 所有大小均为字节。20 GiB = 20 * 1024^3，50 MiB = 50 * 1024^2，
/// 分片为 8 MiB = 8 * 1024^2（二进制单位，避免 GB/MB 十进制歧义）。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// FR-63 明确列出的上传与消息类别。
enum UploadKind { text, image, video, voice, file, live2d }

/// 一次策略评估的可观察结果。
class QuotaDecision {
  const QuotaDecision({
    required this.quotaWarning,
    required this.diskWarning,
    required this.countedBytes,
    required this.chunkSizeBytes,
  });

  final bool quotaWarning;
  final bool diskWarning;
  final int countedBytes;
  final int chunkSizeBytes;
}

/// 纯函数式配额与磁盘上传闸门。
class QuotaPolicy {
  QuotaPolicy._();

  static const int defaultQuotaBytes = 20 * 1024 * 1024 * 1024;
  static const int maximumFileBytesAtFullQuota = 50 * 1024 * 1024;
  static const int chunkSizeBytes = 8 * 1024 * 1024;

  static Result<QuotaDecision> evaluate({
    required int usedBytes,
    int quotaBytes = defaultQuotaBytes,
    required UploadKind kind,
    required int uploadBytes,
    required int diskFreeBytes,
    required int diskTotalBytes,
  }) {
    if (usedBytes < 0 ||
        quotaBytes <= 0 ||
        uploadBytes < 0 ||
        diskFreeBytes < 0 ||
        diskTotalBytes <= 0 ||
        diskFreeBytes > diskTotalBytes) {
      return err(FailureCode.invalidArgument, '配额策略输入不合法');
    }

    // Division/remainder comparisons avoid overflowing when multiplying
    // otherwise-valid native integers by 100 or 10.
    final diskBelowTenPercent =
        diskFreeBytes < diskTotalBytes ~/ 10 ||
        (diskTotalBytes % 10 != 0 && diskFreeBytes == diskTotalBytes ~/ 10);
    // The above expression is strictly < 10%; e.g. 1/11 is below 10%.
    final diskWarning = diskBelowTenPercent;
    final quotaWarning =
        usedBytes >= quotaBytes ~/ 5 * 4 + (quotaBytes % 5 * 4 + 4) ~/ 5;
    final countedBytes = switch (kind) {
      UploadKind.text || UploadKind.image => 0,
      UploadKind.video ||
      UploadKind.voice ||
      UploadKind.file ||
      UploadKind.live2d => uploadBytes,
    };
    final decision = QuotaDecision(
      quotaWarning: quotaWarning,
      diskWarning: diskWarning,
      countedBytes: countedBytes,
      chunkSizeBytes: chunkSizeBytes,
    );

    if (diskBelowTenPercent) {
      return Err(
        Failure(
          FailureCode.budgetExhausted,
          '磁盘剩余空间低于 10%',
          details: {'reason': 'disk', 'diskWarning': true},
        ),
      );
    }

    // Compare usage to quota without multiplication overflow. Full means
    // used >= quota; small files and text/image/voice remain permitted.
    final atOrAboveQuota = usedBytes >= quotaBytes;
    if (atOrAboveQuota &&
        (kind == UploadKind.video ||
            kind == UploadKind.file ||
            kind == UploadKind.live2d) &&
        uploadBytes > maximumFileBytesAtFullQuota) {
      return Err(
        Failure(
          FailureCode.budgetExhausted,
          '配额已满，拒绝大于 50 MiB 的新文件',
          details: {'reason': 'quota', 'quotaWarning': true},
        ),
      );
    }
    return Ok(decision);
  }
}

/// 每个账号独立的进程内并发上传计数闸门。
///
/// 调用方必须在上传结束或失败时释放取得的 permit；permit 由创建它的
/// gate 校验，重复释放、跨 gate 释放均返回失败，不会增加可用名额。
class UploadGate {
  UploadGate({this.maximumConcurrentPerAccount = 3})
    : assert(maximumConcurrentPerAccount > 0);

  final int maximumConcurrentPerAccount;
  final Map<String, Set<UploadPermit>> _active = {};

  Result<UploadPermit> acquire(String accountId) {
    if (accountId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '账号标识不能为空');
    }
    final permits = _active.putIfAbsent(accountId, () => <UploadPermit>{});
    if (permits.length >= maximumConcurrentPerAccount) {
      return err(FailureCode.rateLimited, '该账号并发上传数已达上限');
    }
    final permit = UploadPermit._(this, accountId);
    permits.add(permit);
    return Ok(permit);
  }

  Result<void> release(UploadPermit permit) {
    if (!identical(permit._owner, this) || !permit._active) {
      return err(FailureCode.invalidArgument, '上传许可无效或已释放');
    }
    final permits = _active[permit.accountId];
    if (permits == null || !permits.remove(permit)) {
      return err(FailureCode.invalidArgument, '上传许可无效或已释放');
    }
    permit._active = false;
    if (permits.isEmpty) _active.remove(permit.accountId);
    return const Ok<void>(null);
  }
}

/// 一次上传闸门名额；不可自行构造。
class UploadPermit {
  UploadPermit._(this._owner, this.accountId);

  final UploadGate _owner;
  final String accountId;
  bool _active = true;
}
