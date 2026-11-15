/// M11 客户端外壳的会话编排（纯 Dart、UI 无关）。
///
/// 依据 `docs/modules/M11-client-shell.md` 规则 2/3：业务逻辑放 `client_kit`，
/// 外壳只做 UI 绑定。本文件把「离线发件箱 [Outbox] + 差集游标 [SyncCursor] +
/// 本地消息缓存 [LocalMessageCache]」按账号编排成一个 [ClientSession]：
///
/// - 收：把服务端同步到的 [CachedMessage] 交给 [ClientSession.ingest]，按会话游标
///   合并、写本地缓存，并报告缺口（供外壳拉差集）；
/// - 发：`sendText` 入发件箱，`flush` 按序提交；
/// - 读：`messages` 从本地缓存分页读取。
///
/// 纯 Dart、不读文件、不联网；持久化与网络由 Flutter 外壳负责。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'local_message_cache.dart';
import 'outbox.dart';
import 'sync_cursor.dart';

/// 某会话出现同步缺口：需要从 [afterSeq] 之后拉差集。
class SyncGap {
  const SyncGap(this.conversationId, this.afterSeq);

  final String conversationId;
  final int afterSeq;

  @override
  String toString() => 'SyncGap($conversationId after $afterSeq)';
}

/// 一次 [ClientSession.ingest] 的结果。
class SyncIngestResult {
  const SyncIngestResult({
    required this.applied,
    required this.duplicates,
    required this.gaps,
  });

  /// 实际写入本地缓存的条数。
  final int applied;

  /// 已见过（重复下发/重连重放）而忽略的条数。
  final int duplicates;

  /// 需要拉差集的会话缺口；按会话首次出现缺口时记录一次。
  final List<SyncGap> gaps;

  bool get needsSync => gaps.isNotEmpty;

  @override
  String toString() =>
      'SyncIngestResult(applied=$applied, duplicates=$duplicates, gaps=$gaps)';
}

/// 一个账号的客户端会话：编排发件箱、差集游标与本地消息缓存。
class ClientSession {
  ClientSession({
    required this.accountId,
    Outbox? outbox,
    LocalMessageCache? cache,
  })  : _outbox = outbox ?? Outbox(),
        _cache = cache ?? LocalMessageCache();

  final String accountId;
  final Outbox _outbox;
  final LocalMessageCache _cache;
  final Map<String, SyncCursor> _cursors = {};

  /// 离线发件箱（外壳可读取 [Outbox.items] 做持久化）。
  Outbox get outbox => _outbox;

  /// 本地消息缓存（外壳可导出/导入快照做持久化）。
  LocalMessageCache get cache => _cache;

  /// 首次用到某会话时，用已缓存的最大 seq 初始化游标，避免重复下发被当新消息。
  SyncCursor _cursorFor(String conversationId) => _cursors.putIfAbsent(
        conversationId,
        () => SyncCursor(lastSeq: _cache.headSeq(accountId, conversationId)),
      );

  /// 合并一批服务端同步消息（每会话内按 seq 升序）。
  ///
  /// 缺口只报告、不写入乱序消息，并停止该会话本批后续条目；调用方据
  /// [SyncIngestResult.gaps] 拉差集补齐后再次 ingest。不同会话互不影响。
  SyncIngestResult ingest(Iterable<CachedMessage> messages) {
    final byConversation = <String, List<CachedMessage>>{};
    for (final message in messages) {
      byConversation
          .putIfAbsent(message.conversationId, () => <CachedMessage>[])
          .add(message);
    }

    var applied = 0;
    var duplicates = 0;
    final gaps = <SyncGap>[];
    for (final entry in byConversation.entries) {
      final cursor = _cursorFor(entry.key);
      for (final message in entry.value) {
        final outcome = cursor.accept(message.seq);
        if (outcome == MergeOutcome.gap) {
          gaps.add(SyncGap(entry.key, cursor.lastSeq));
          break; // 补齐差集前不写入乱序消息
        }
        if (outcome == MergeOutcome.duplicate) {
          duplicates++;
          continue;
        }
        _cache.upsert(accountId, message);
        applied++;
      }
    }
    return SyncIngestResult(
      applied: applied,
      duplicates: duplicates,
      gaps: gaps,
    );
  }

  /// 撤回：交给本地缓存（保留 seq、置撤回占位，旧页不能复活正文）。
  void applyRecall(String conversationId, String messageId) =>
      _cache.applyRecall(accountId, conversationId, messageId);

  /// 本地缓存的会话消息（`seq > afterSeq`，按 seq 升序，最多 [limit] 条）。
  List<CachedMessage> messages(
    String conversationId, {
    int afterSeq = 0,
    int limit = 200,
  }) =>
      _cache.list(
        accountId,
        conversationId,
        afterSeq: afterSeq,
        limit: limit,
      );

  /// 本地已缓存的最大 seq（非连续确认游标）。
  int headSeq(String conversationId) => _cache.headSeq(accountId, conversationId);

  /// 发文本消息：入离线发件箱，返回分配的 clientMsgId。
  String sendText(String conversationId, String text) => _outbox.enqueue(
        conversationId,
        MessageKind.text,
        <String, Object?>{'text': text},
      );

  /// 按序提交发件箱（网络类失败停止并保留队首，永久失败丢弃并回调）。
  Future<FlushReport> flush(
    Submit submit, {
    void Function(OutboxItem item, Failure failure)? onDropped,
  }) =>
      _outbox.flush(submit, onDropped: onDropped);

  /// 清除当前账号的本地缓存与游标（切换账号/退出时用）。
  void clearAccount() {
    _cache.clearAccount(accountId);
    _cursors.clear();
  }
}
