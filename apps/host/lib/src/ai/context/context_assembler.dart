import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../../models/openai_chat_adapter.dart';

/// Counts the complete provider/model input, including roles and framing.
/// There is intentionally no approximate or default tokenizer.
typedef TokenCounter = int Function(List<ChatTurn> messages);

final class ContextScope {
  const ContextScope({required this.aiProfileId, required this.scopeKey});

  final String aiProfileId;
  final String scopeKey;
}

final class ContextProvenance {
  ContextProvenance({
    required this.scope,
    required this.sourceAccountId,
    required List<String> sourceMessageIds,
  }) : sourceMessageIds = List.unmodifiable(sourceMessageIds);

  final ContextScope scope;
  final String sourceAccountId;
  final List<String> sourceMessageIds;
}

final class ContextHistoryTurn {
  const ContextHistoryTurn({
    required this.id,
    required this.scope,
    required this.user,
    required this.assistant,
  });

  final String id;
  final ContextScope scope;
  final ChatTurn user;
  final ChatTurn assistant;
}

final class ContextSummary {
  const ContextSummary({
    required this.id,
    required this.text,
    required this.provenance,
    required this.authorized,
  });

  final String id;
  final String text;
  final ContextProvenance provenance;
  final bool authorized;
}

final class ContextMemoryHit {
  const ContextMemoryHit({
    required this.id,
    required this.text,
    required this.score,
    required this.provenance,
    required this.authorized,
  });

  final String id;
  final String text;
  final double score;
  final ContextProvenance provenance;
  final bool authorized;
}

final class AssembledContext {
  AssembledContext({
    required List<ChatTurn> messages,
    required this.totalTokens,
    required this.inputBudget,
    required List<String> omittedHistoryIds,
    required List<String> omittedSummaryIds,
    required List<String> omittedMemoryIds,
  }) : messages = List.unmodifiable(messages),
       omittedHistoryIds = List.unmodifiable(omittedHistoryIds),
       omittedSummaryIds = List.unmodifiable(omittedSummaryIds),
       omittedMemoryIds = List.unmodifiable(omittedMemoryIds);

  final List<ChatTurn> messages;
  final int totalTokens;
  final int inputBudget;
  final List<String> omittedHistoryIds;
  final List<String> omittedSummaryIds;
  final List<String> omittedMemoryIds;
}

/// Stateless, synchronous context packing. No retrieval, storage, summarization,
/// model call, or provider budget policy is performed here.
///
/// Only caller-trusted [system] and [persona] become system messages. Summaries
/// and memories are JSON-encoded user messages with explicit provenance. This
/// preserves role isolation; it does not guarantee prompt injection is
/// impossible or make recalled text trustworthy.
///
/// Scope identities, history, fixed instructions, and authorization decisions
/// must come from an authenticated service boundary, never model/tool arguments.
/// An `authorized: true` assertion is not an authorization implementation: the
/// caller must check live source visibility and memory status/tier before use.
final class ContextAssembler {
  const ContextAssembler({required TokenCounter tokenCounter})
    : _tokenCounter = tokenCounter;

  final TokenCounter _tokenCounter;

  /// Packs fixed instructions and the required user turn first, then the newest
  /// whole history exchanges, newest summaries, and score-ranked memory hits.
  /// History and summaries are supplied oldest first. Omitted IDs retain input
  /// order within each category, including denied, foreign-scope, limit-excluded
  /// and budget-excluded entries; these diagnostics are for trusted callers.
  ///
  /// All limits and token reserves are explicit. Zero optional limits disable
  /// that category. Threshold comparison is inclusive and ties retain input
  /// order. The selected memory top-K is not backfilled after budget rejection.
  /// Text is never truncated. Fixed instructions or the current turn exceeding
  /// the input budget return [FailureCode.budgetExhausted].
  ///
  /// Tokenization covers only fixed content and bounded candidate sequences,
  /// never an all-history prompt. Validating inputs and reporting all omitted
  /// IDs still require linear input work; callers should page retrieval too.
  Result<AssembledContext> assemble({
    required int modelWindow,
    required int outputReserve,
    required int safetyReserve,
    required ContextScope scope,
    required String system,
    required String persona,
    required ChatTurn currentTurn,
    required List<ContextHistoryTurn> history,
    required int maxHistoryTurns,
    required List<ContextSummary> summaries,
    required int maxSummaries,
    required List<ContextMemoryHit> memoryHits,
    required int memoryTopK,
    required double memoryScoreThreshold,
  }) {
    final window = BigInt.from(modelWindow);
    final reserved = BigInt.from(outputReserve) + BigInt.from(safetyReserve);
    if (modelWindow <= 0 ||
        outputReserve < 0 ||
        safetyReserve < 0 ||
        reserved > window ||
        maxHistoryTurns < 0 ||
        maxSummaries < 0 ||
        memoryTopK < 0 ||
        !memoryScoreThreshold.isFinite ||
        !_validScope(scope) ||
        system.trim().isEmpty ||
        persona.trim().isEmpty ||
        !_validTurn(currentTurn, 'user') ||
        !_uniqueIds(history.map((turn) => turn.id)) ||
        !_uniqueIds(summaries.map((summary) => summary.id)) ||
        !_uniqueIds(memoryHits.map((hit) => hit.id))) {
      return _invalid();
    }

    // Check metadata without sending denied or foreign text to the tokenizer.
    // Reject role escalation attempts even when they would fall outside limits.
    for (final turn in history) {
      if (!_validScope(turn.scope) ||
          !_validTurn(turn.user, 'user') ||
          !_validTurn(turn.assistant, 'assistant')) {
        return _invalid();
      }
    }
    for (final summary in summaries) {
      if (!_validProvenance(summary.provenance) ||
          summary.text.trim().isEmpty) {
        return _invalid();
      }
    }
    for (final hit in memoryHits) {
      if (!_validProvenance(hit.provenance) ||
          hit.text.trim().isEmpty ||
          !hit.score.isFinite) {
        return _invalid();
      }
    }

    final inputBudget = (window - reserved).toInt();
    final fixed = [
      ChatTurn(role: 'system', content: system),
      ChatTurn(role: 'system', content: persona),
    ];
    final selectedHistory = <ContextHistoryTurn>[];
    final selectedSummaries = <ContextSummary>[];
    final selectedMemory = <ChatTurn>[];
    final historyIds = <String>{};
    final summaryIds = <String>{};
    final memoryIds = <String>{};

    List<ChatTurn> messages() => [
      ...fixed,
      for (final summary in selectedSummaries)
        _recall('summary', summary.id, summary.text, summary.provenance),
      ...selectedMemory,
      for (final turn in selectedHistory) ...[turn.user, turn.assistant],
      currentTurn,
    ];

    try {
      int count(List<ChatTurn> candidate) {
        // A dependency cannot mutate our candidate or retain a mutable list.
        final total = _tokenCounter(List.unmodifiable(candidate));
        if (total < 0) throw const _InvalidTokenCount();
        return total;
      }

      if (count(fixed) > inputBudget) return _overflow();
      var totalTokens = count(messages());
      if (totalTokens > inputBudget) return _overflow();

      var attemptedHistory = 0;
      for (var i = history.length - 1; i >= 0; i--) {
        final turn = history[i];
        if (!_sameScope(turn.scope, scope)) continue;
        if (attemptedHistory >= maxHistoryTurns) break;
        attemptedHistory++;
        selectedHistory.insert(0, turn);
        final candidateTokens = count(messages());
        if (candidateTokens > inputBudget) {
          selectedHistory.removeAt(0);
          // A recent suffix cannot skip a large new turn to backfill old turns.
          break;
        }
        totalTokens = candidateTokens;
        historyIds.add(turn.id);
      }

      var attemptedSummaries = 0;
      for (var i = summaries.length - 1; i >= 0; i--) {
        final summary = summaries[i];
        if (!summary.authorized ||
            !_sameScope(summary.provenance.scope, scope)) {
          continue;
        }
        if (attemptedSummaries >= maxSummaries) break;
        attemptedSummaries++;
        selectedSummaries.insert(0, summary);
        final candidateTokens = count(messages());
        if (candidateTokens > inputBudget) {
          selectedSummaries.removeAt(0);
          continue;
        }
        totalTokens = candidateTokens;
        summaryIds.add(summary.id);
      }

      // Keep at most K candidates while scanning. There is no unbounded sorted
      // copy of the hit set; scores are caller-supplied, not invented here.
      final rankedMemory = <ContextMemoryHit>[];
      if (memoryTopK > 0) {
        for (final hit in memoryHits) {
          if (!hit.authorized ||
              !_sameScope(hit.provenance.scope, scope) ||
              hit.score < memoryScoreThreshold) {
            continue;
          }
          var position = 0;
          while (position < rankedMemory.length &&
              rankedMemory[position].score >= hit.score) {
            position++;
          }
          if (position >= memoryTopK) continue;
          rankedMemory.insert(position, hit);
          if (rankedMemory.length > memoryTopK) rankedMemory.removeLast();
        }
      }
      for (final hit in rankedMemory) {
        selectedMemory.add(_recall('memory', hit.id, hit.text, hit.provenance));
        final candidateTokens = count(messages());
        if (candidateTokens > inputBudget) {
          selectedMemory.removeLast();
          continue;
        }
        totalTokens = candidateTokens;
        memoryIds.add(hit.id);
      }

      return Ok(
        AssembledContext(
          messages: messages(),
          totalTokens: totalTokens,
          inputBudget: inputBudget,
          omittedHistoryIds: [
            for (final turn in history)
              if (!historyIds.contains(turn.id)) turn.id,
          ],
          omittedSummaryIds: [
            for (final summary in summaries)
              if (!summaryIds.contains(summary.id)) summary.id,
          ],
          omittedMemoryIds: [
            for (final hit in memoryHits)
              if (!memoryIds.contains(hit.id)) hit.id,
          ],
        ),
      );
    } catch (_) {
      // Tokenizers can throw errors containing prompt text; never expose them.
      return err(FailureCode.invalidArgument, 'Context token counting failed');
    }
  }
}

bool _validScope(ContextScope scope) =>
    scope.aiProfileId.trim().isNotEmpty && scope.scopeKey.trim().isNotEmpty;

bool _sameScope(ContextScope a, ContextScope b) =>
    a.aiProfileId == b.aiProfileId && a.scopeKey == b.scopeKey;

bool _validTurn(ChatTurn turn, String role) =>
    turn.role == role && turn.content.trim().isNotEmpty;

bool _uniqueIds(Iterable<String> ids) {
  final seen = <String>{};
  for (final id in ids) {
    if (id.trim().isEmpty || !seen.add(id)) return false;
  }
  return true;
}

bool _validProvenance(ContextProvenance provenance) =>
    _validScope(provenance.scope) &&
    provenance.sourceAccountId.trim().isNotEmpty &&
    provenance.sourceMessageIds.isNotEmpty &&
    _uniqueIds(provenance.sourceMessageIds);

ChatTurn _recall(
  String kind,
  String id,
  String text,
  ContextProvenance provenance,
) => ChatTurn(
  role: 'user',
  content: jsonEncode({
    'kind': 'untrusted_$kind',
    'id': id,
    'provenance': {
      'aiProfileId': provenance.scope.aiProfileId,
      'scopeKey': provenance.scope.scopeKey,
      'sourceAccountId': provenance.sourceAccountId,
      'sourceMessageIds': provenance.sourceMessageIds,
    },
    'text': text,
  }),
);

Result<AssembledContext> _invalid() =>
    err(FailureCode.invalidArgument, 'Invalid context assembly request');

Result<AssembledContext> _overflow() =>
    err(FailureCode.budgetExhausted, 'Required context exceeds input budget');

final class _InvalidTokenCount implements Exception {
  const _InvalidTokenCount();
}
