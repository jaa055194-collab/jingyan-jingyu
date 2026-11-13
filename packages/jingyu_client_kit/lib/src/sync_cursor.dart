/// 差集同步游标（FR-14、AC-18）。
///
/// 客户端为每个会话记住 `last_ack`；收到消息时按 seq 合并，
/// 发现缺口（收到 seq=5 但本地只到 3）就请求差集补齐，不盲目追加。
library;

/// 一次合并的结论。
enum MergeOutcome {
  /// 正好是下一条，已前进。
  applied,

  /// 已见过（重复下发或重连重放），忽略。
  duplicate,

  /// 有缺口，需要从 [SyncCursor.lastSeq] 之后拉差集。
  gap,
}

/// 单会话游标。
class SyncCursor {
  SyncCursor({this.lastSeq = 0});

  /// 本地已连续收到的最大 seq。
  int lastSeq;

  /// 合并一条服务端消息的 seq。
  MergeOutcome accept(int seq) {
    if (seq <= lastSeq) return MergeOutcome.duplicate;
    if (seq == lastSeq + 1) {
      lastSeq = seq;
      return MergeOutcome.applied;
    }
    return MergeOutcome.gap;
  }

  /// 合并一页差集（必须按 seq 升序）。返回实际前进到的 seq。
  ///
  /// 页内出现缺口时停在缺口前，调用方应继续拉取。
  int acceptPage(Iterable<int> seqs) {
    for (final seq in seqs) {
      if (accept(seq) == MergeOutcome.gap) break;
    }
    return lastSeq;
  }
}
