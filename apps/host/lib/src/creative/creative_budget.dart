/// 创意功能的生成额度闸门。
///
/// 周报、年报、深夜电台的生成都计入额度（CR-03 / CR-07「生成计入额度」）。
/// 这里只暴露一个最小接口，真实实现接 M05/models 的用量计量；宿主切片用内存假实现
/// 与契约测试验证边界。周报属 B4 维护层：超支时按 B4 顺延到次日而非丢弃。
library;

/// 生成额度闸门。返回 true 表示本次生成已获额度，false 表示额度不足。
abstract class CreativeBudgetGate {
  Future<bool> tryReserve({
    required String ownerAccountId,
    required String aiId,
    required int tokens,
  });
}

/// 永远放行（未接入计量时的降级）。
class AlwaysGrantBudgetGate implements CreativeBudgetGate {
  const AlwaysGrantBudgetGate();

  @override
  Future<bool> tryReserve({
    required String ownerAccountId,
    required String aiId,
    required int tokens,
  }) async => true;
}

/// 内存假实现：按 (owner, ai) 记录剩余额度，便于测试预算边界。
class InMemoryBudgetGate implements CreativeBudgetGate {
  InMemoryBudgetGate({this.tokensPerOwner = 0});

  /// 每个 (owner, ai) 的可用额度；0 表示一律拒绝（用于模拟耗尽）。
  final int tokensPerOwner;
  final Map<String, int> _used = <String, int>{};

  String _key(String owner, String ai) => '$owner\u0000$ai';

  @override
  Future<bool> tryReserve({
    required String ownerAccountId,
    required String aiId,
    required int tokens,
  }) async {
    final key = _key(ownerAccountId, aiId);
    final used = _used[key] ?? 0;
    if (used + tokens > tokensPerOwner) return false;
    _used[key] = used + tokens;
    return true;
  }
}
