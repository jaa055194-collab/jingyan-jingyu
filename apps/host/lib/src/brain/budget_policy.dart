import 'package:jingyu_core/jingyu_core.dart';

import 'classifier.dart';

/// Trusted per-request budget snapshot for one AI.
class BrainBudgetSnapshot {
  const BrainBudgetSnapshot({
    this.globalHardStop = false,
    this.capabilityHardStop = false,
    this.slowLayerExhausted = false,
    this.trustedOwnerPrivate = false,
  });

  final bool globalHardStop;
  final bool capabilityHardStop;
  final bool slowLayerExhausted;
  final bool trustedOwnerPrivate;
}

/// Admission outcome for one reply attempt.
enum BrainDisposition { proceed, deferSlow, silent }

/// Trusted resolver of the current snapshot. Derived from the authenticated
/// principal and conversation, never from caller-controlled message fields.
typedef BrainBudgetResolver =
    Future<Result<BrainBudgetSnapshot>> Function(
      AiId ai,
      ConversationId? conversationId,
    );

/// Admission port consulted before any S1 padding, pacing or S2 work.
abstract class BrainAdmission {
  Future<Result<BrainDisposition>> admit(
    AiId ai, {
    required ConversationId? conversationId,
    required Complexity complexity,
  });
}

/// Snapshot-driven admission policy (FR-48 B2 degradation, FR-58 hard stop).
class BrainBudgetPolicy implements BrainAdmission {
  BrainBudgetPolicy({required BrainBudgetResolver snapshot})
    : _snapshot = snapshot;

  final BrainBudgetResolver _snapshot;

  @override
  Future<Result<BrainDisposition>> admit(
    AiId ai, {
    required ConversationId? conversationId,
    required Complexity complexity,
  }) async {
    final Result<BrainBudgetSnapshot> result = await _snapshot(
      ai,
      conversationId,
    );
    return result.map(
      (BrainBudgetSnapshot snapshot) => _decide(snapshot, complexity),
    );
  }

  BrainDisposition _decide(
    BrainBudgetSnapshot snapshot,
    Complexity complexity,
  ) {
    // FR-58 hard stop wins over every degradation rule and the owner exception.
    if (snapshot.globalHardStop || snapshot.capabilityHardStop) {
      return BrainDisposition.silent;
    }
    // S1/B1 fast replies are independent of the B2 slow layer.
    if (complexity == Complexity.simple) {
      return BrainDisposition.proceed;
    }
    // FR-48 / M07 rule 5: B2 exhausted -> only the owner's private chat.
    if (snapshot.slowLayerExhausted) {
      return snapshot.trustedOwnerPrivate
          ? BrainDisposition.proceed
          : BrainDisposition.deferSlow;
    }
    return BrainDisposition.proceed;
  }
}
