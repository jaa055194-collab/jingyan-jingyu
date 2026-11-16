/// M12 用户离开与删除回执（口径 C-4 / FR-65 / AC-15 / NFR-11）。
///
/// 离开流程：清点对象 → 删除（会话/消息/记忆/附件索引/…）→ 独占附件删除、
/// 其动态匿名化 → 备份轮转后清除 → 生成删除回执。
///
/// 回执只含对象计数与备份轮转到期日，不含任何正文；措辞沿用诚实口径
/// "轮转后清除"，不宣称"瞬间不可恢复"。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../audit/audit_log.dart';

/// 其 AI 的处置方式（由 operator 决定）。
enum AiDisposition { transfer, retain, delete }

/// 离开前/后的对象清点。键为对象类别，值为数量。
class DepartureSurvey {
  const DepartureSurvey({
    required this.objectCounts,
    required this.momentsToAnonymize,
  });

  final Map<String, int> objectCounts;
  final int momentsToAnonymize;
}

/// 离开存储契约：清点、删除（幂等）、备份保留天数。
abstract class DepartureStore {
  /// 只清点，不改变数据。
  Future<DepartureSurvey> survey(String accountId);

  /// 删除并返回实际删除（匿名化）的数量；对未知账号返回空计数。
  Future<DepartureSurvey> purge(String accountId);

  /// 备份本地/远端保留天数（FR-64 默认 30 天）。
  Future<int> backupRetentionDays();
}

/// 内存实现：框架与测试使用。
class InMemoryDepartureStore implements DepartureStore {
  InMemoryDepartureStore({this.retentionDays = 30});

  final Map<String, Map<String, int>> _objects = {};
  final Map<String, int> _moments = {};
  int retentionDays;

  /// 测试/示例播种。
  void seed(String accountId, Map<String, int> counts, {int moments = 0}) {
    _objects[accountId] = Map<String, int>.of(counts);
    _moments[accountId] = moments;
  }

  @override
  Future<DepartureSurvey> survey(String accountId) async => DepartureSurvey(
    objectCounts: Map<String, int>.of(_objects[accountId] ?? const {}),
    momentsToAnonymize: _moments[accountId] ?? 0,
  );

  @override
  Future<DepartureSurvey> purge(String accountId) async => DepartureSurvey(
    objectCounts: Map<String, int>.of(_objects.remove(accountId) ?? const {}),
    momentsToAnonymize: _moments.remove(accountId) ?? 0,
  );

  @override
  Future<int> backupRetentionDays() async => retentionDays;
}

/// 删除回执。
class DepartureReceipt {
  const DepartureReceipt({
    required this.accountId,
    required this.generatedAt,
    required this.objectCounts,
    required this.momentsAnonymized,
    required this.aiDisposition,
    required this.backupRotationDueAt,
    required this.notice,
  });

  final String accountId;
  final DateTime generatedAt;
  final Map<String, int> objectCounts;
  final int momentsAnonymized;
  final AiDisposition aiDisposition;
  final DateTime backupRotationDueAt;

  /// 诚实口径说明，不含正文。
  final String notice;

  int get totalObjects =>
      objectCounts.values.fold<int>(0, (sum, count) => sum + count);

  Map<String, Object?> toJson() => {
    'accountId': accountId,
    'generatedAt': generatedAt.toUtc().toIso8601String(),
    'objectCounts': objectCounts,
    'totalObjects': totalObjects,
    'momentsAnonymized': momentsAnonymized,
    'aiDisposition': aiDisposition.name,
    'backupRotationDueAt': backupRotationDueAt.toUtc().toIso8601String(),
    'notice': notice,
  };
}

/// 离开服务。
class DepartureService {
  DepartureService({
    required DepartureStore store,
    this.clock = const SystemClock(),
    AuditLog? audit,
  }) : _store = store,
       _audit = audit;

  static const String honestNotice = '备份轮转后清除；备份窗口内技术上仍可恢复';

  final DepartureStore _store;
  final AuditLog? _audit;
  final Clock clock;

  Future<Result<DepartureReceipt>> depart({
    required String accountId,
    required AiDisposition aiDisposition,
  }) async {
    if (accountId.trim().isEmpty) {
      return err(FailureCode.invalidArgument, '账号标识不能为空');
    }
    final purged = await _store.purge(accountId);
    final now = clock.now().toUtc();
    final retentionDays = await _store.backupRetentionDays();
    final rotationDueAt = now.add(Duration(days: retentionDays));

    final receipt = DepartureReceipt(
      accountId: accountId,
      generatedAt: now,
      objectCounts: Map<String, int>.unmodifiable(purged.objectCounts),
      momentsAnonymized: purged.momentsToAnonymize,
      aiDisposition: aiDisposition,
      backupRotationDueAt: rotationDueAt,
      notice: honestNotice,
    );

    await _audit?.record(
      AuditEntry(
        at: now,
        actorId: accountId,
        action: 'account.departure',
        targetKind: 'account',
        targetId: accountId,
        meta: {
          'totalObjects': receipt.totalObjects,
          'momentsAnonymized': receipt.momentsAnonymized,
          'aiDisposition': aiDisposition.name,
          'backupRotationDueAt': rotationDueAt.toIso8601String(),
        },
      ),
    );
    return Ok(receipt);
  }
}
