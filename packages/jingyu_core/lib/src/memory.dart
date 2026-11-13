/// 记忆分层与证据资格。
///
/// 需求依据：FR-49（分层治理）、FR-50（记忆管理器）、NFR-08（证据资格）。
///
/// 本文件只表达"分层规则本身"——把一条候选记忆归到哪一层、什么状态可以注入
/// 上下文、什么状态可以导出。分类器（规则 + LLM）在宿主的 memory 模块里实现，
/// 但分类结果必须落在这套词汇上。
library;

/// 记忆分层（FR-49）。
enum MemoryTier {
  /// T0 自动：AI 自己的活动、低风险日常偏好、公共事件、用户明确"记住这个"。
  t0,

  /// T1 需确认：健康、财务、亲密关系、涉及第三人、关于用户的事实断言、
  /// 承诺与约定、新旧矛盾。确认前不注入上下文。
  t1,

  /// T2 私密：密码、创伤、证件等。单独加密；不进导出明文、
  /// 不进朋友圈、不进别的 AI 上下文。
  t2,
}

/// 记忆条目状态机（FR-49）。
enum MemoryStatus {
  /// 待确认。只有 T1 会长期停留在此状态。
  pending,

  /// 生效，可以注入上下文。
  active,

  /// 被拒绝。可由 [MemoryStatus.pending] 重新进入待确认。
  rejected,

  /// 被新版本取代。
  superseded,

  /// 归档（用户删除、"清空某段记忆"）。留审计，不物理删除。
  archived,

  /// 逻辑删除标记。
  deleted,
}

/// 证据等级（FR-49）。
enum EvidenceLevel {
  /// 用户确认过。
  userConfirmed,

  /// 用户亲口陈述。
  userStated,

  /// 系统推断。
  inferred,

  /// 模型自述（日记、画面理解、推测）。
  modelClaim,
}

/// 采集决定。
///
/// 需求方口径（2026-11-13 答复第 7 条）：**"别记"意味着禁止采集**，
/// 不是"降级保存到 T2"。因此采集闸门必须先于分层判定运行：
/// 命中禁止采集时不产生任何记忆条目与候选。
enum CollectionDecision {
  /// 允许采集，按分层规则继续处理。
  allow,

  /// 禁止采集。不落库、不进检索日志、不进导出。
  deny,
}

/// 记忆分层策略：本文件的核心不变式集合。
class MemoryPolicy {
  const MemoryPolicy();

  /// 采集闸门：显式"别记/别外传"优先于任何分层。
  CollectionDecision collectionDecision({required bool userOptedOut}) =>
      userOptedOut ? CollectionDecision.deny : CollectionDecision.allow;

  /// 分层重叠时的优先级：**最严格者胜**（T2 > T1 > T0）。
  ///
  /// 理由：分层是对隐私与错误代价的分级，取更严格的一层不会泄露信息，
  /// 取更宽松的一层会；而"拿不准就进 T1"体现的是同一原则。
  MemoryTier resolveTier(Iterable<MemoryTier> overlapping) {
    var worst = MemoryTier.t0;
    for (final tier in overlapping) {
      if (tier.index > worst.index) worst = tier;
    }
    return worst;
  }

  /// 该证据等级能否默认为 active。
  ///
  /// 只有 `user_confirmed` 与 `user_stated` 可以；其余必须走确认流程。
  bool mayActivateByDefault(EvidenceLevel level) =>
      level == EvidenceLevel.userConfirmed || level == EvidenceLevel.userStated;

  /// 结合分层与证据等级给出初始状态。
  ///
  /// T0 且证据够格 → active；其余一律 pending（拿不准 → T1 的落地形式）。
  MemoryStatus initialStatus({
    required MemoryTier tier,
    required EvidenceLevel level,
  }) {
    if (tier == MemoryTier.t0 && mayActivateByDefault(level)) {
      return MemoryStatus.active;
    }
    return MemoryStatus.pending;
  }

  /// 该条目能否注入模型上下文。
  ///
  /// T2 永远不进"给别人看的"上下文；调用方负责传入上下文所属账号，
  /// 只有 owner 自己的 AI 才允许读取 T2（FR-49、FR-08）。
  bool mayInject({
    required MemoryStatus status,
    required MemoryTier tier,
    required bool forOwnerAi,
  }) {
    if (status != MemoryStatus.active) return false;
    if (tier == MemoryTier.t2 && !forOwnerAi) return false;
    return true;
  }

  /// 该条目能否进入导出包。
  bool mayExport({required MemoryTier tier}) => tier != MemoryTier.t2;

  /// 状态迁移是否合法（FR-49 状态机）。
  bool canTransition(MemoryStatus from, MemoryStatus to) => switch (from) {
        MemoryStatus.pending =>
          to == MemoryStatus.active || to == MemoryStatus.rejected,
        MemoryStatus.active => to == MemoryStatus.superseded ||
            to == MemoryStatus.archived ||
            to == MemoryStatus.deleted,
        MemoryStatus.rejected => to == MemoryStatus.pending,
        MemoryStatus.superseded => to == MemoryStatus.archived,
        MemoryStatus.archived => to == MemoryStatus.pending,
        MemoryStatus.deleted => false,
      };
}

/// 记忆范围。
///
/// 群记忆与私聊记忆是不同 scope，永不互相并入（FR-23、FR-49）。
sealed class MemoryScope {
  const MemoryScope();

  /// 稳定的范围键，用于索引与审计。
  String get key;
}

/// 与某个 AI 的私聊记忆。
class PrivateScope extends MemoryScope {
  const PrivateScope({required this.aiId, required this.ownerId});

  final String aiId;
  final String ownerId;

  @override
  String get key => 'private:$aiId:$ownerId';
}

/// 群记忆。
class GroupScope extends MemoryScope {
  const GroupScope({required this.aiId, required this.conversationId});

  final String aiId;
  final String conversationId;

  @override
  String get key => 'group:$aiId:$conversationId';
}

/// 话题记忆（跟随话题，不并入群记忆）。
class TopicScope extends MemoryScope {
  const TopicScope({
    required this.aiId,
    required this.conversationId,
    required this.topicId,
  });

  final String aiId;
  final String conversationId;
  final String topicId;

  @override
  String get key => 'topic:$aiId:$conversationId:$topicId';
}
