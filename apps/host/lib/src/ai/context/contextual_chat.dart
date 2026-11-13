import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';

import '../../models/model_gateway.dart';
import '../../models/model_runtime.dart';
import '../../models/openai_chat_adapter.dart';
import '../../security/url_guard.dart';
import '../../storage/cipher.dart';
import '../../storage/database.dart';
import '../persona/persona_service.dart';
import 'context_assembler.dart';

/// Exact context-window policy supplied by trusted model-profile configuration.
/// No tokenizer or window defaults are inferred by [ContextualChat].
final class ContextualChatProfile {
  const ContextualChatProfile({
    required this.providerId,
    required this.model,
    required this.system,
    required this.modelWindow,
    required this.outputReserve,
    required this.safetyReserve,
    required this.tokenCounter,
  });

  final String providerId;
  final String model;
  final String system;
  final int modelWindow;
  final int outputReserve;
  final int safetyReserve;
  final TokenCounter tokenCounter;
}

/// Completion plus private assembly diagnostics and normalized provider usage.
final class ContextualChatCompletion {
  const ContextualChatCompletion({
    required this.completion,
    required this.assembled,
  });

  final ChatCompletion completion;
  final AssembledContext assembled;

  String get text => completion.text;
  int get inputTokens => completion.inputTokens;
  int get outputTokens => completion.outputTokens;
  int get totalTokens => completion.totalTokens;
}

/// Trusted internal composition of stored persona, caller-authorized context,
/// deterministic packing, and the owner-scoped model runtime. This class has no
/// HTTP entry point and never mutates persona state from model output.
///
/// The trusted caller must authorize every history turn and verify source
/// visibility plus pending/T2 memory status before supplying summaries or hits.
/// [ContextualChat] only enforces the supplied authorization flags and provenance;
/// it does not implement those live policy checks.
final class ContextualChat {
  ContextualChat({
    required Database db,
    required ColumnCipher cipher,
    required Clock clock,
    required UrlGuard urlGuard,
    required OpenAiCompatibleChatAdapter adapter,
    required ContextualChatProfile profile,
  }) : _db = db,
       _cipher = cipher,
       _clock = clock,
       _urlGuard = urlGuard,
       _adapter = adapter,
       _profile = profile;

  final Database _db;
  final ColumnCipher _cipher;
  final Clock _clock;
  final UrlGuard _urlGuard;
  final OpenAiCompatibleChatAdapter _adapter;
  final ContextualChatProfile _profile;

  Future<Result<ContextualChatCompletion>> chat({
    required String ownerId,
    required AiId ai,
    required ContextScope scope,
    required TrustedChatContext context,
    required String requestId,
    required BudgetLayer layer,
    required ChatTurn currentTurn,
    required List<ContextHistoryTurn> history,
    required int maxHistoryTurns,
    required List<ContextSummary> summaries,
    required int maxSummaries,
    required List<ContextMemoryHit> memoryHits,
    required int memoryTopK,
    required double memoryScoreThreshold,
  }) async {
    if (!_validProfile(_profile) ||
        context.scopeKey == null ||
        context.scopeKey!.trim().isEmpty ||
        scope.aiProfileId != ai.value ||
        scope.scopeKey != context.scopeKey) {
      return err(
        FailureCode.invalidArgument,
        'Invalid contextual chat configuration or scope',
      );
    }

    final persona = await SqlitePersonaService.forOwner(
      ownerId: ownerId,
      actorAccountId: ownerId,
      database: _db,
      cipher: _cipher,
      clock: _clock,
    ).current(ai);
    if (persona case Err<PersonaCard>(:final failure)) return Err(failure);

    final assembled = ContextAssembler(tokenCounter: _profile.tokenCounter)
        .assemble(
          modelWindow: _profile.modelWindow,
          outputReserve: _profile.outputReserve,
          safetyReserve: _profile.safetyReserve,
          scope: scope,
          system: _profile.system,
          persona: jsonEncode(persona.value.layers.toJson()),
          currentTurn: currentTurn,
          history: history,
          maxHistoryTurns: maxHistoryTurns,
          summaries: summaries,
          maxSummaries: maxSummaries,
          memoryHits: memoryHits,
          memoryTopK: memoryTopK,
          memoryScoreThreshold: memoryScoreThreshold,
        );
    if (assembled case Err<AssembledContext>(:final failure)) {
      return Err(failure);
    }

    final result =
        await ModelRuntime(
          db: _db,
          cipher: _cipher,
          clock: _clock,
          urlGuard: _urlGuard,
          adapter: _adapter,
        ).chat(
          ownerId: ownerId,
          ai: ai,
          turns: assembled.value.messages,
          requestId: requestId,
          layer: layer,
          context: context,
          expectedProviderId: _profile.providerId,
          expectedModel: _profile.model,
          maxTokens: _profile.outputReserve,
        );
    return result.map(
      (completion) => ContextualChatCompletion(
        completion: completion,
        assembled: assembled.value,
      ),
    );
  }
}

bool _validProfile(ContextualChatProfile profile) =>
    profile.providerId.trim().isNotEmpty &&
    profile.providerId.trim() == profile.providerId &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(profile.providerId) &&
    profile.model.trim().isNotEmpty &&
    profile.model.trim() == profile.model &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(profile.model) &&
    profile.system.trim().isNotEmpty &&
    profile.modelWindow > 0 &&
    profile.outputReserve > 0 &&
    profile.safetyReserve >= 0 &&
    BigInt.from(profile.outputReserve) + BigInt.from(profile.safetyReserve) <=
        BigInt.from(profile.modelWindow);
