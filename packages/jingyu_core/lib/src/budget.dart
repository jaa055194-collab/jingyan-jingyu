/// token 预算分层（FR-48）与用量硬停（FR-58）。
///
/// 两者关系（需求方已确认可共存）：FR-48 是**分层降级**节能，
/// FR-58 是按 AI/能力/日的**硬停**熔断；叠加执行，先降级、再硬停。
library;

/// 预算层（FR-48 B0–B4）。
enum BudgetLayer {
  /// B0 生活心跳：规则引擎为主，LLM 仅晨间规划与日记。超支直接跳过。
  b0Life,

  /// B1 S1 快脑：接梗、衬垫、轻事务。超支降级纯规则回应。
  b1FastBrain,

  /// B2 S2 深聊：主对话与领域知识。超支只回主人私聊。
  b2DeepChat,

  /// B3 主动社交：主动消息、朋友圈、串门。超支全部静默。
  b3Proactive,

  /// B4 维护：人格复盘、周报、记忆整理。超支顺延到次日。
  b4Maintenance,
}

/// 降级等级：一层预算的剩余情况决定该层行为。
enum DegradeLevel {
  /// 正常。
  normal,

  /// 已用 80%：提示，仍可执行。
  warn,

  /// 已用 100%：按该层降级行为执行。
  degraded,

  /// 全局硬停（FR-58）：停主动、停通话、停自动重试；入站消息保留不自动回。
  halted,
}

/// 一层预算的配置与占用。
class LayerBudget {
  const LayerBudget({
    required this.layer,
    required this.totalTokens,
    this.usedTokens = 0,
    this.warnRatio = 0.8,
  });

  final BudgetLayer layer;
  final int totalTokens;
  final int usedTokens;
  final double warnRatio;

  /// 默认占比，用于新建 AI 时按日总额切分。
  static const Map<BudgetLayer, double> defaultShares = {
    BudgetLayer.b0Life: 0.10,
    BudgetLayer.b1FastBrain: 0.15,
    BudgetLayer.b2DeepChat: 0.60,
    BudgetLayer.b3Proactive: 0.10,
    BudgetLayer.b4Maintenance: 0.05,
  };

  int get remainingTokens => totalTokens - usedTokens;

  DegradeLevel get level {
    if (totalTokens <= 0) return DegradeLevel.degraded;
    final ratio = usedTokens / totalTokens;
    if (ratio >= 1.0) return DegradeLevel.degraded;
    if (ratio >= warnRatio) return DegradeLevel.warn;
    return DegradeLevel.normal;
  }

  /// 尝试消耗。[amount] 不得超过剩余额度时返回 true。
  ///
  /// 框架不在这里做降级决策——降级由调用方结合 [level] 与需求行为决定，
  /// 这样"哪层超支做哪件事"集中在一处可读。
  bool tryConsume(int amount) => usedTokens + amount <= totalTokens;
}

/// 按日总额与默认占比切分各层。
Map<BudgetLayer, LayerBudget> splitDailyBudget(int dailyTokens) {
  return {
    for (final entry in LayerBudget.defaultShares.entries)
      entry.key: LayerBudget(
        layer: entry.key,
        totalTokens: (dailyTokens * entry.value).floor(),
      ),
  };
}
