import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../ai/memory/owner_auto_memory.dart';
import '../ai/memory/owner_memory_notes.dart';
import '../ai/memory/owner_reply_preferences.dart';
import '../messages/accepted_message_observer.dart';
import '../messages/message_store.dart';
import '../messages/sqlite_message_store.dart';
import '../models/binding_matrix.dart';
import '../models/provider_registry.dart';
import '../models/stateless_owner_chat.dart';
import '../social/owner_ai_direct_consent.dart';
import '../storage/cipher.dart';
import '../storage/database.dart';
import 'classifier.dart';
import 'owner_reply_attempts.dart';
import 's1_responder.dart';

/// At-most-once ownerTextOnly replies. No history, retry, provider fallback or
/// observer registration. Trusted root supplies budget admission and model pinning.
final class OwnerAiDirectReplyObserver implements AcceptedMessageObserver {
  OwnerAiDirectReplyObserver({
    required this.database,
    required this.cipher,
    required this.messages,
    required this.system,
    required this.maxTokens,
    required this.admitS1,
    required this.resolveBinding,
    this.chat,
    this.preferences,
    this.memoryNotes,
    this.autoMemory,
    this.attempts = const OwnerReplyAttempts(),
  });

  final Database database;
  final ColumnCipher cipher;
  final SqliteMessageStore messages;
  final String system;
  final int maxTokens;
  final Future<bool> Function(OwnerAiDirectGrant grant) admitS1;
  final Future<Result<ResolvedBinding>> Function(OwnerAiDirectGrant grant)
  resolveBinding;
  final StatelessOwnerChat? chat;

  /// Optional independent grant. Null keeps the ordinary reply path unchanged.
  final OwnerReplyPreferences? preferences;

  /// Optional independently authorized, explicitly saved notes.
  final OwnerMemoryNotes? memoryNotes;

  /// Optional independently authorized auto chat-history memory. Default off and
  /// owner-private only; null keeps the ordinary reply path unchanged.
  final OwnerAutoMemory? autoMemory;
  final OwnerReplyAttempts attempts;
  static const _rules = RulesS1Responder();

  @override
  Future<void> onAccepted(StoredMessage incoming) async {
    OwnerReplyAttemptClaim? claim;
    try {
      final source = await database.transaction((tx) async {
        final loaded = await _load(tx, incoming);
        if (loaded == null) return null;
        final (grant, text) = loaded;
        final simple =
            const RuleClassifier().classify(text).complexity ==
            Complexity.simple;
        if (simple && !_rules.supports(text)) return null;
        final request =
            'od_${sha256.convert(utf8.encode(jsonEncode([incoming.messageId, grant.aiProfileId]))).toString().substring(0, 56)}';
        final candidate = OwnerReplyAttemptClaim(
          sourceMessageId: incoming.messageId,
          aiProfileId: grant.aiProfileId,
          ownerAccountId: grant.ownerAccountId,
          aiAccountId: grant.aiAccountId,
          conversationId: grant.conversationId,
          grantRevision: grant.revision,
          requestId: request,
        );
        if (!await attempts.claimInTx(tx, claim: candidate)) return null;
        claim = candidate;
        return (grant, text, simple);
      });
      if (source == null) return;
      final (grant, text, simple) = source;
      ResolvedBinding? binding;
      OwnerReplyPreferenceUse? preferenceUse;
      OwnerMemoryNoteUse? memoryUse;
      OwnerAutoMemoryUse? autoMemoryUse;
      String output;
      if (simple) {
        // Admission owns the real B1 hard-stop check. Never invent token usage.
        if (!await admitS1(grant)) {
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.failed,
            FailureCode.budgetExhausted,
          );
          return;
        }
        output = _rules.curatedReply(text)!.text;
      } else {
        if (chat == null || system.trim().isEmpty || maxTokens <= 0) {
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.failed,
            FailureCode.modelUnavailable,
          );
          return;
        }
        final resolved = await resolveBinding(grant); // Outside Tx.
        if (resolved.isErr) {
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.failed,
            resolved.failureOrNull!.code,
          );
          return;
        }
        binding = resolved.value;
        final prepared = await database.transaction((tx) async {
          if (!await _fresh(tx, incoming, grant, text, binding)) return null;
          final use = preferences == null
              ? null
              : await preferences!.forSourceInTx(tx, grant, incoming.messageId);
          final memory = memoryNotes == null
              ? null
              : await memoryNotes!.forSourceInTx(tx, grant, incoming.messageId);
          final auto = autoMemory == null
              ? null
              : await autoMemory!.forSourceInTx(tx, grant, incoming.messageId);
          return _PreparedPreference(use, memory, auto);
        });
        if (prepared == null) {
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.discarded,
            FailureCode.conflict,
          );
          return;
        }
        final use = prepared.preferences;
        final notes = prepared.memory;
        final auto = prepared.autoMemory;
        preferenceUse = use;
        memoryUse = notes;
        autoMemoryUse = auto;
        final needsAdmission = use != null || notes != null || auto != null;
        Future<bool> admission(
          Tx tx, {
          required AiId ai,
          required String requestId,
          required String providerId,
          required String model,
          required String baseUrl,
        }) async =>
            ai.value == grant.aiProfileId &&
            requestId == claim!.requestId &&
            (use == null || use.matchesRecipient(providerId, model, baseUrl)) &&
            (notes == null ||
                notes.matchesRecipient(providerId, model, baseUrl)) &&
            (auto == null || auto.matchesRecipient(providerId, model, baseUrl)) &&
            await _fresh(tx, incoming, grant, text, binding) &&
            (use == null ||
                await preferences!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  use,
                )) &&
            (notes == null ||
                await memoryNotes!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  notes,
                )) &&
            (auto == null ||
                await autoMemory!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  auto,
                ));

        final result = await chat!.chat(
          ownerId: grant.ownerAccountId,
          ai: AiId.parse(grant.aiProfileId),
          conversationId: grant.conversationId,
          requestId: claim!.requestId,
          system: system,
          input: text,
          expectedProviderId: binding.providerId,
          expectedModel: binding.model,
          maxTokens: maxTokens,
          preferenceChoices: use?.choices,
          memoryNotes: notes?.notes,
          autoMemoryEntries: auto?.entries,
          dispatchAdmission: needsAdmission ? admission : null,
        );
        if (result.isErr) {
          // Runtime owns settlement/unknown usage; do not modify its ledger.
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.failed,
            result.failureOrNull!.code,
          );
          return;
        }
        output = result.value.text;
      }
      await database.transaction((tx) async {
        if (!await _fresh(tx, incoming, grant, text, binding) ||
            (preferenceUse != null &&
                !await preferences!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  preferenceUse,
                )) ||
            (memoryUse != null &&
                !await memoryNotes!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  memoryUse,
                )) ||
            (autoMemoryUse != null &&
                !await autoMemory!.isFreshInTx(
                  tx,
                  grant,
                  incoming.messageId,
                  autoMemoryUse,
                ))) {
          await _finish(
            tx,
            claim!,
            OwnerReplyAttemptStatus.discarded,
            failure: FailureCode.conflict,
          );
          return;
        }
        final appended = await messages.appendInTransaction(
          tx,
          conversationId: grant.conversationId,
          senderId: grant.aiAccountId,
          clientMsgId: claim!.requestId,
          kind: MessageKind.text,
          body: {
            'text': output,
            'source': simple ? 's1' : 's2',
            'activityRefs': <String>[],
          },
        );
        // Returning Err would commit preceding writes/sequence allocation.
        if (appended.isErr) throw const _Rollback();
        await _finish(
          tx,
          claim!,
          OwnerReplyAttemptStatus.completed,
          reply: appended.value.message.messageId,
        );
      });
    } catch (_) {
      // No source/provider-error prose is logged or stored in safe status.
      if (claim != null) {
        try {
          await _terminal(
            claim!,
            OwnerReplyAttemptStatus.failed,
            FailureCode.internal,
          );
        } catch (_) {
          // Leave pending/unknown on storage failure. Never retry the source.
        }
      }
    }
  }

  Future<(OwnerAiDirectGrant, String)?> _load(
    Tx tx,
    StoredMessage incoming,
  ) async {
    final grant = await OwnerAiDirectConsent.resolveInTx(
      tx,
      ownerAccountId: incoming.senderId,
      conversationId: incoming.conversationId,
    );
    if (grant == null) return null;
    final rows = await tx.query(
      '''
SELECT m.body FROM messages m
JOIN owner_ai_direct_sources s ON s.source_message_id=m.message_id
WHERE m.message_id=? AND m.conversation_id=? AND m.sender_id=? AND m.seq=?
 AND m.kind='text' AND m.recalled_at IS NULL
 AND s.owner_account_id=? AND s.ai_profile_id=? AND s.ai_account_id=?
 AND s.conversation_id=? AND s.grant_revision=?
 AND NOT EXISTS(SELECT 1 FROM message_edits e WHERE e.message_id=m.message_id)
 AND NOT EXISTS(SELECT 1 FROM social_conversations g WHERE g.id=m.conversation_id)
''',
      [
        incoming.messageId,
        grant.conversationId,
        grant.ownerAccountId,
        incoming.seq,
        grant.ownerAccountId,
        grant.aiProfileId,
        grant.aiAccountId,
        grant.conversationId,
        grant.revision,
      ],
    );
    if (rows.length != 1) return null;
    final plaintext = cipher.decrypt(
      rows.single['body'] as String,
      aad: 'messages:body:${incoming.messageId}',
    );
    if (plaintext.isErr) return null;
    final body = jsonDecode(plaintext.value);
    if (body is! Map<String, dynamic> ||
        body.length != 1 ||
        body['text'] is! String ||
        (body['text'] as String).trim().isEmpty) {
      return null;
    }
    return (grant, body['text'] as String);
  }

  Future<bool> _fresh(
    Tx tx,
    StoredMessage incoming,
    OwnerAiDirectGrant expected,
    String text,
    ResolvedBinding? binding,
  ) async {
    final current = await _load(tx, incoming);
    if (current == null) return false;
    final (grant, canonical) = current;
    if (canonical != text ||
        grant.ownerAccountId != expected.ownerAccountId ||
        grant.aiProfileId != expected.aiProfileId ||
        grant.aiAccountId != expected.aiAccountId ||
        grant.conversationId != expected.conversationId ||
        grant.revision != expected.revision) {
      return false;
    }
    if (binding == null) return true; // S1 needs no main chat binding.
    if (binding.ownerId != grant.ownerAccountId ||
        binding.aiProfileId.value != grant.aiProfileId ||
        binding.aiAccountId.value != grant.aiAccountId ||
        binding.capability != ProviderCapability.chat) {
      return false;
    }
    // Only safe configuration columns; credentials never enter this component.
    final matches = await tx.query(
      '''
SELECT 1 FROM model_bindings b JOIN providers p
 ON p.owner_id=b.owner_id AND p.id=b.provider_id
WHERE b.owner_id=? AND b.ai_profile_id=? AND b.capability='chat'
 AND b.provider_id=? AND b.model=? AND p.enabled=1
 AND EXISTS(SELECT 1 FROM json_each(p.capabilities) WHERE value='chat')
''',
      [
        grant.ownerAccountId,
        grant.aiProfileId,
        binding.providerId,
        binding.model,
      ],
    );
    return matches.length == 1;
  }

  Future<void> _finish(
    Tx tx,
    OwnerReplyAttemptClaim claim,
    OwnerReplyAttemptStatus status, {
    String? reply,
    FailureCode? failure,
  }) async {
    if (!await attempts.finishInTx(
      tx,
      ownerAccountId: claim.ownerAccountId,
      sourceMessageId: claim.sourceMessageId,
      aiProfileId: claim.aiProfileId,
      requestId: claim.requestId,
      status: status,
      replyId: reply,
      failureCode: failure,
    )) {
      throw const _Rollback();
    }
  }

  Future<void> _terminal(
    OwnerReplyAttemptClaim claim,
    OwnerReplyAttemptStatus status,
    FailureCode failure,
  ) => database.transaction(
    (tx) => _finish(tx, claim, status, failure: failure),
  );
}

final class _Rollback implements Exception {
  const _Rollback();
}

final class _PreparedPreference {
  const _PreparedPreference(this.preferences, this.memory, this.autoMemory);
  final OwnerReplyPreferenceUse? preferences;
  final OwnerMemoryNoteUse? memory;
  final OwnerAutoMemoryUse? autoMemory;
}
