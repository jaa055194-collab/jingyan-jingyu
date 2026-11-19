import 'package:jingyu_core/jingyu_core.dart';

import '../security/url_guard.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'binding_matrix.dart';
import 'openai_chat_adapter.dart';
import 'provider_registry.dart';
import 'usage_meter.dart';

/// Conversation facts resolved by the trusted host caller.
enum ChatConversationKind { private, group }

/// Trusted host API only: derive initiator from the authenticated caller and
/// kind from canonical conversation state. Never construct this from arbitrary
/// HTTP body fields or expose an ownerPrivate override. This manual gateway
/// slice has no HTTP entry point.
final class TrustedChatContext {
  const TrustedChatContext({
    required this.initiator,
    required this.conversationKind,
    this.scopeKey,
  });

  final AccountId initiator;
  final ChatConversationKind conversationKind;

  /// Trusted canonical conversation identity, never sourced from request bodies.
  final String? scopeKey;
}

/// Owner-configured, single-call chat pipeline for B1 and B2 only.
///
/// The host owns message persistence and upstream B1 rule responses. This class
/// neither stores inbound messages nor implements other budget layers. No retry,
/// fallback or completion cache is provided. Unknown provider usage stays pending
/// until a trusted reconciliation process settles it through UsageMeter.
/// Database exceptions deliberately propagate to the host's internal-error
/// boundary; provider errors are normalized by the adapter and below.
final class ModelGateway {
  ModelGateway.forOwner({
    required String ownerId,
    required Database db,
    required ColumnCipher cipher,
    required UrlGuard urlGuard,
    required Clock clock,
    required BudgetDay Function(Clock) dayForClock,
    required OpenAiCompatibleChatAdapter adapter,
  }) : _ownerId = validateId(ownerId, kind: 'owner'),
       _db = db,
       _guard = urlGuard,
       _adapter = adapter,
       _bindings = BindingMatrix.forOwner(ownerId, db),
       _providers = ProviderRegistry.forOwner(
         ownerId: ownerId,
         db: db,
         cipher: cipher,
         urlGuard: urlGuard,
         clock: clock,
       ),
       _usage = UsageMeter.forOwner(
         ownerId: ownerId,
         db: db,
         clock: clock,
         dayForClock: dayForClock,
       );

  final String _ownerId;
  final Database _db;
  final UrlGuard _guard;
  final OpenAiCompatibleChatAdapter _adapter;
  final BindingMatrix _bindings;
  final ProviderRegistry _providers;
  final UsageMeter _usage;

  Future<bool> _exists(AiId ai, String requestId) async => (await _db.query(
    'SELECT 1 FROM usage_ledger WHERE owner_id=? AND ai_id=? AND request_id=?',
    [_ownerId, ai.value, requestId],
  )).isNotEmpty;

  Result<ChatCompletion> _replay() => err(
    FailureCode.conflict,
    'Request already began; completion replay is unavailable',
  );

  Future<Result<ChatCompletion>> chat(
    AiId ai,
    List<ChatTurn> turns, {
    required String requestId,
    required BudgetLayer layer,
    required TrustedChatContext context,
    int? maxTokens,
    String? expectedProviderId,
    String? expectedModel,
  }) async {
    if (maxTokens != null && maxTokens <= 0 ||
        (expectedProviderId == null) != (expectedModel == null) ||
        expectedProviderId != null &&
            (expectedProviderId.trim().isEmpty ||
                expectedProviderId.trim() != expectedProviderId ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(expectedProviderId) ||
                expectedModel!.trim().isEmpty ||
                expectedModel.trim() != expectedModel ||
                RegExp(r'[\x00-\x1f\x7f]').hasMatch(expectedModel))) {
      return err(FailureCode.invalidArgument, 'Invalid chat request');
    }
    if (layer != BudgetLayer.b1FastBrain && layer != BudgetLayer.b2DeepChat) {
      return err(FailureCode.invalidArgument, 'Unsupported chat budget layer');
    }
    final capability = layer == BudgetLayer.b1FastBrain
        ? ProviderCapability.chatFast
        : ProviderCapability.chat;
    final binding = await _bindings.resolve(ai, capability);
    if (binding case Err<ResolvedBinding>(:final failure)) return Err(failure);
    if (expectedProviderId != null &&
        (binding.value.providerId != expectedProviderId ||
            binding.value.model != expectedModel)) {
      return err(FailureCode.conflict, 'Model binding changed');
    }
    // Resolve first so replay lookup cannot reveal another operator's requests.
    // inspect intentionally blocks unknown usage, including a pending replay.
    if (await _exists(ai, requestId)) return _replay();
    final inspected = await _usage.inspect(
      ai,
      layer: layer,
      capability: capability,
    );
    if (inspected case Err<UsageGate>(:final failure)) {
      // A concurrent call may have begun between the lookup and inspection.
      if (await _exists(ai, requestId)) return _replay();
      return Err(failure);
    }
    final allowDegradedLayer =
        layer == BudgetLayer.b2DeepChat &&
        context.initiator.value == _ownerId &&
        context.conversationKind == ChatConversationKind.private;
    if (inspected.value.degradeLevel == DegradeLevel.degraded &&
        !allowDegradedLayer) {
      return err(
        FailureCode.budgetExhausted,
        layer == BudgetLayer.b1FastBrain
            ? 'B1 degraded; upstream rule response required'
            : 'B2 degraded; only owner private chat permitted',
      );
    }
    // Reject locally detectable invalid input before creating unknown usage.
    final model = binding.value.model;
    if (model.trim().isEmpty ||
        model.trim() != model ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model) ||
        turns.isEmpty ||
        turns.any(
          (turn) =>
              !const {'system', 'user', 'assistant'}.contains(turn.role) ||
              turn.content.trim().isEmpty,
        )) {
      return err(FailureCode.invalidArgument, 'Invalid chat request');
    }
    final credential = await _providers.credentialForGateway(
      binding.value.providerId,
    );
    if (credential case Err<ProviderGatewayConfig>(:final failure)) {
      return Err(failure);
    }
    final endpoint = await _guard.check(credential.value.baseUrl);
    if (endpoint case Err<Uri>(:final failure)) return Err(failure);
    // The injected adapter must use guarded transport for DNS pinning and every
    // redirect. This preflight prevents known blocked URLs from creating pending.
    final begun = await _usage.beginRequest(
      ai,
      requestId: requestId,
      layer: layer,
      capability: capability,
      allowDegradedLayer: allowDegradedLayer,
    );
    if (begun case Err<UsageRequest>(:final failure)) return Err(failure);
    if (begun.value.replayed) return _replay();
    final response = await _adapter.chatWithUsage(
      baseUrl: endpoint.value,
      apiKey: credential.value.apiKey,
      model: binding.value.model,
      messages: List.unmodifiable(turns),
      maxTokens: maxTokens,
    );
    if (response case Err<MeteredChatResponse>(:final failure)) {
      return err(
        failure.code,
        'Provider chat failed; usage requires reconciliation',
        {'sourceUsageUnknown': true, 'reconciliationRequired': true},
      );
    }
    final value = response.value;
    final recorded = await _usage.recordUsage(
      ai,
      requestId: requestId,
      layer: layer,
      capability: capability,
      input: value.inputTokens,
      output: value.outputTokens,
      total: value.totalTokens,
    );
    if (recorded case Err<void>(:final failure)) return Err(failure);
    return switch (value) {
      ChatCompletion completion => Ok(completion),
      BlankChatReply() => err(
        FailureCode.modelUnavailable,
        'Provider chat unavailable',
      ),
    };
  }
}
