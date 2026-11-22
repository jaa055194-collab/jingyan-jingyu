import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../social/owner_ai_direct_consent.dart';
import '../../storage/database.dart';
import 'memory_store.dart';

/// Opaque recipient incarnation for the owner's own private chat. The token is
/// derived only from the independent random epoch and canonical grant identity,
/// never from a credential or private URL path.
final class OwnerAutoMemoryTarget {
  const OwnerAutoMemoryTarget(
    this.providerId,
    this.model,
    this.baseUrl,
    this.origin,
    this.token,
  );

  final String providerId;
  final String model;
  final String baseUrl;
  final String origin;
  final String token;

  Map<String, Object?> toJson() => {
    'providerId': providerId,
    'model': model,
    'origin': origin,
    'token': token,
  };

  static final _hidden = RegExp(
    r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
  );

  /// Computes the current recipient for a live grant, or null when no enabled
  /// chat binding/provider incarnation exists for this owner's own AI.
  static Future<OwnerAutoMemoryTarget?> targetInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
  ) async {
    final row = (await tx.query(
      '''
SELECT p.id,p.base_url,b.model,e.epoch FROM model_bindings b
JOIN providers p ON p.owner_id=b.owner_id AND p.id=b.provider_id AND p.enabled=1
JOIN owner_auto_memory_target_epochs e ON e.owner_id=b.owner_id AND e.ai_profile_id=b.ai_profile_id
WHERE b.owner_id=? AND b.ai_profile_id=? AND b.capability='chat'
 AND EXISTS(SELECT 1 FROM json_each(p.capabilities) WHERE value='chat')
 AND NOT EXISTS(SELECT 1 FROM social_conversations WHERE id=?)''',
      [grant.ownerAccountId, grant.aiProfileId, grant.conversationId],
    )).singleOrNull;
    if (row == null) return null;
    final id = row['id']! as String;
    final model = row['model']! as String;
    final raw = row['base_url']! as String;
    if (raw.length > 2048 ||
        !RegExp(r'^[A-Za-z0-9_-]{1,128}$').hasMatch(id) ||
        model.length > 256 ||
        model.trim().isEmpty ||
        model != model.trim() ||
        _hidden.hasMatch(model)) {
      return null;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null ||
        !const {'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.origin.length > 512 ||
        uri.port < 1 ||
        uri.port > 65535 ||
        uri.userInfo.isNotEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    final token = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'owner-auto-memory:v1',
              row['epoch'],
              grant.ownerAccountId,
              grant.aiProfileId,
              grant.aiAccountId,
              grant.conversationId,
              grant.revision,
            ]),
          ),
        )
        .toString();
    return OwnerAutoMemoryTarget(id, model, raw, uri.origin, token);
  }
}

/// Production owner-private capture/read/transition authorization.
///
/// Capture is allowed only for the owner's own authorized private chat scope,
/// with a still-enabled grant whose target token is unchanged since the source
/// was accepted. Reads and transitions are owner-private only: `talkingWith`
/// must equal the owning operator, so group and third-party contexts are never
/// visible through this authorizer.
final class OwnerPrivateMemoryAuthorization implements MemoryAuthorization {
  const OwnerPrivateMemoryAuthorization();

  @override
  Future<bool> authorizeCapture(Tx tx, MemoryCandidate candidate) async {
    final entry = candidate.entry;
    if (entry.scopeKey !=
        'private:${entry.aiProfileId}:${entry.owningOperatorId}') {
      return false;
    }
    if (entry.sourceAccountId != entry.owningOperatorId) return false;

    final owned = await tx.query(
      '''
SELECT p.account_id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE p.id=?''',
      [entry.owningOperatorId, entry.aiProfileId],
    );
    if (owned.length != 1) return false;

    final settings = (await tx.query(
      '''
SELECT revision,enabled,target_token FROM owner_auto_memory_settings
WHERE owner_id=? AND ai_profile_id=?''',
      [entry.owningOperatorId, entry.aiProfileId],
    )).singleOrNull;
    if (settings == null ||
        settings['enabled'] != 1 ||
        settings['target_token'] == null) {
      return false;
    }
    final targetToken = settings['target_token'] as String;

    for (final sourceId in entry.sourceMessageIds) {
      final source = (await tx.query(
        '''
SELECT owner_account_id,ai_profile_id,ai_account_id,conversation_id,grant_revision
FROM owner_ai_direct_sources WHERE source_message_id=?''',
        [sourceId],
      )).singleOrNull;
      if (source == null ||
          source['owner_account_id'] != entry.owningOperatorId ||
          source['ai_profile_id'] != entry.aiProfileId) {
        return false;
      }
      final stamp = (await tx.query(
        '''
SELECT settings_revision,target_token FROM owner_auto_memory_sources
WHERE source_message_id=?''',
        [sourceId],
      )).singleOrNull;
      if (stamp == null ||
          stamp['settings_revision'] != settings['revision'] ||
          stamp['target_token'] != targetToken) {
        return false;
      }
      final grant = await OwnerAiDirectConsent.resolveInTx(
        tx,
        ownerAccountId: entry.owningOperatorId,
        conversationId: source['conversation_id'] as String,
      );
      if (grant == null ||
          grant.aiProfileId != entry.aiProfileId ||
          grant.aiAccountId != source['ai_account_id'] ||
          grant.revision != source['grant_revision']) {
        return false;
      }
      final target = await OwnerAutoMemoryTarget.targetInTx(tx, grant);
      if (target == null || target.token != targetToken) return false;
    }
    return true;
  }

  @override
  Future<bool> authorizeRead(
    Tx tx,
    MemoryEntry entry,
    MemoryContext context,
  ) async {
    if (context.talkingWith != entry.owningOperatorId ||
        context.owningOperatorId != entry.owningOperatorId ||
        context.aiProfileId != entry.aiProfileId) {
      return false;
    }
    return entry.scopeKey ==
        'private:${entry.aiProfileId}:${entry.owningOperatorId}';
  }

  @override
  Future<bool> authorizeTransition(
    Tx tx,
    MemoryEntry entry,
    MemoryContext context,
    MemoryStatus to,
  ) async {
    if (context.isModelActor ||
        context.actorAccountId != entry.owningOperatorId) {
      return false;
    }
    return authorizeRead(tx, entry, context);
  }
}
