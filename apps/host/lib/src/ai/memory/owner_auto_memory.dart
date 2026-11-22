import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../messages/accepted_message_observer.dart';
import '../../messages/message_store.dart';
import '../../social/owner_ai_direct_consent.dart';
import '../../storage/cipher.dart';
import '../../storage/database.dart';
import 'memory_store.dart';
import 'owner_memory_authorization.dart';

/// One captured owner statement, decrypted only for the owner's own manager.
final class OwnerAutoMemoryEntry {
  const OwnerAutoMemoryEntry({
    required this.id,
    required this.text,
    required this.tier,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String text;
  final MemoryTier tier;
  final MemoryStatus status;
  final DateTime createdAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'tier': tier.name,
    'status': status.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };
}

/// Immutable snapshot carried into one accepted owner text. The live
/// `isFreshInTx` check is what authorizes the later B2 injection.
///
/// Composition root wiring (feature A): pass [kind] as the user-role segment
/// label and [entries] as its bounded contents. Never merge this segment with
/// the system prompt, persona, `untrusted_owner_memory_notes`, or another AI.
final class OwnerAutoMemoryUse {
  const OwnerAutoMemoryUse._(this._target, this._settingsRevision, this.entries);

  /// User-role memory segment kind for the owner's own B2 direct reply.
  static const kind = 'untrusted_owner_memory';

  final OwnerAutoMemoryTarget _target;
  final int _settingsRevision;
  final List<String> entries;

  /// Recommended B2 user-role segment. The composition root must emit this as
  /// its own `user` turn after the system prompt and before the live owner
  /// text, never merged with the persona or the notes segment.
  Map<String, Object?> toJson() => {
    'kind': kind,
    'entries': entries,
  };

  bool matchesRecipient(String providerId, String model, String baseUrl) =>
      providerId == _target.providerId &&
      model == _target.model &&
      baseUrl == _target.baseUrl;
}

/// Default-off, per-AI opt-in auto chat-history memory. Capture is rule-first:
/// an explicit memory instruction ("记住/记下/别忘了/以后/别忘") with bounded
/// length becomes active T0, every other owner text becomes pending T1. Never
/// T2, never group or third-party content, and entries live in the shared
/// encrypted store (`MemoryStore.capture`) with no body in audit.
///
/// Composition root: register this instance as an [AcceptedMessageObserver]
/// (post-commit capture), mount `OwnerAutoMemoryModule` for management, and
/// inject [OwnerAutoMemoryUse] via [forSourceInTx]/[isFreshInTx] in the B2
/// owner-DM reply path.
final class OwnerAutoMemory implements AcceptedMessageObserver {
  OwnerAutoMemory({
    required this.database,
    required this.cipher,
    required this.clock,
  });

  final Database database;
  final ColumnCipher cipher;
  final Clock clock;

  static const maxEntries = 50;
  static const maxEntryBytes = 512;
  static const maxInjectedEntries = 5;
  static const maxInjectedBytes = 1024;
  static const _hidden =
      r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]';
  static final _memoryInstruction = RegExp('记住|记下|别忘了|以后|别忘');

  late final MemoryStore _store = MemoryStore(
    database: database,
    cipher: cipher,
    clock: clock,
    authorizer: const OwnerPrivateMemoryAuthorization(),
  );

  Future<Result<Map<String, Object?>>> readSettings({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
  }) => _settings(owner: owner, device: device, bearer: bearer, ai: ai);

  Future<Result<Map<String, Object?>>> setEnabled({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required int expectedRevision,
    required bool enabled,
    required String? expectedTargetToken,
  }) => _settings(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      expectedRevision: expectedRevision,
      enabled: enabled,
      expectedTargetToken: expectedTargetToken,
    ),
  );

  Future<Result<Map<String, Object?>>> listEntries({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
  }) => _entries(owner: owner, device: device, bearer: bearer, ai: ai);

  Future<Result<Map<String, Object?>>> deleteEntry({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required String memoryId,
    required int expectedRevision,
  }) => _entries(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.delete,
      memoryId: memoryId,
      expectedRevision: expectedRevision,
    ),
  );

  Future<Result<Map<String, Object?>>> clearEntries({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required int expectedRevision,
  }) => _entries(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.clear,
      memoryId: null,
      expectedRevision: expectedRevision,
    ),
  );

  Future<Result<Map<String, Object?>>> _settings({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    ({
      int expectedRevision,
      bool enabled,
      String? expectedTargetToken,
    })?
    write,
  }) => database.transaction((tx) async {
    final denied = await _callerFailure(tx, owner, device, bearer);
    if (denied != null) return Err(denied);
    final account = await _ownedAi(tx, owner, ai);
    if (account == null) return _notFound();
    final grant = await _pair(tx, owner, ai, account);
    final target = grant == null
        ? null
        : await OwnerAutoMemoryTarget.targetInTx(tx, grant);
    final saved = await _settingsRow(tx, owner, ai);
    final revision = saved?['revision'] as int? ?? 0;
    if (write == null) {
      return Ok(_renderSettings(revision, saved, target));
    }
    if (write.expectedRevision < 0) {
      return err(FailureCode.invalidArgument, 'Invalid auto memory revision');
    }
    if (write.expectedRevision != revision) {
      return err(FailureCode.conflict, 'Auto memory revision changed');
    }
    final enabled = write.enabled;
    final expected = write.expectedTargetToken;
    if ((enabled &&
            (target == null || expected == null || expected != target.token)) ||
        (!enabled && expected != null)) {
      return enabled && target == null
          ? err(FailureCode.conflict, 'Auto memory target unavailable')
          : err(FailureCode.invalidArgument, 'Invalid auto memory setting');
    }
    final next = revision + 1;
    await tx.execute(
      '''
INSERT INTO owner_auto_memory_settings(owner_id,ai_profile_id,revision,enabled,target_token)
VALUES(?,?,?,?,?) ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET
revision=excluded.revision,enabled=excluded.enabled,target_token=excluded.target_token''',
      [owner, ai.value, next, enabled ? 1 : 0, enabled ? target!.token : null],
    );
    await _audit(
      tx,
      owner,
      'owner_auto_memory.settings',
      ai.value,
      {'enabled': enabled, 'revision': next},
    );
    return Ok(_renderSettings(next, await _settingsRow(tx, owner, ai), target));
  });

  Future<Result<Map<String, Object?>>> _entries({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    ({_WriteKind kind, String? memoryId, int expectedRevision})? write,
  }) => database.transaction((tx) async {
    final denied = await _callerFailure(tx, owner, device, bearer);
    if (denied != null) return Err(denied);
    if (await _ownedAi(tx, owner, ai) == null) return _notFound();
    final saved = await _settingsRow(tx, owner, ai);
    final revision = saved?['revision'] as int? ?? 0;
    if (write == null) {
      return _renderEntries(tx, owner, ai.value, revision);
    }
    if (write.expectedRevision < 0) {
      return err(FailureCode.invalidArgument, 'Invalid auto memory revision');
    }
    if (write.expectedRevision != revision) {
      return err(FailureCode.conflict, 'Auto memory revision changed');
    }
    final entries = await _listEntries(tx, owner, ai.value);
    if (entries == null) return _storageUnavailable();
    final now = clock.now().toUtc();
    if (write.kind == _WriteKind.delete) {
      final entry = entries.where((e) => e.id == write.memoryId).firstOrNull;
      if (entry == null) return _entryNotFound();
      if (!await _transitionEntry(tx, owner, ai.value, entry, now)) {
        return err(FailureCode.conflict, 'Auto memory entry changed');
      }
    } else {
      for (final entry in entries) {
        if (!await _transitionEntry(tx, owner, ai.value, entry, now)) {
          return err(FailureCode.conflict, 'Auto memory entry changed');
        }
      }
    }
    final next = revision + 1;
    await _bump(tx, owner, ai.value, next);
    await _audit(
      tx,
      owner,
      write.kind == _WriteKind.delete
          ? 'owner_auto_memory.delete'
          : 'owner_auto_memory.clear',
      ai.value,
      {
        'revision': next,
        if (write.kind == _WriteKind.delete) 'memoryId': write.memoryId,
      },
    );
    return _renderEntries(tx, owner, ai.value, next);
  });

  /// Post-commit capture. Never throws: a capture failure must not fail the
  /// accepted append or crash the host, and is never retried.
  Future<void> captureAccepted(StoredMessage incoming) async {
    try {
      final candidate = await database.transaction(
        (tx) => _prepareCandidate(tx, incoming),
      );
      if (candidate == null) return;
      await _store.capture(candidate);
    } catch (_) {
      // Ignore: capture is best-effort and the source append already committed.
    }
  }

  /// `AcceptedMessageObserver` adapter so the composition root can register the
  /// service in the existing post-commit fanout without another class.
  @override
  Future<void> onAccepted(StoredMessage message) => captureAccepted(message);

  Future<MemoryCandidate?> _prepareCandidate(
    Tx tx,
    StoredMessage incoming,
  ) async {
    final source = (await tx.query(
      '''
SELECT owner_account_id,ai_profile_id,ai_account_id,conversation_id,grant_revision
FROM owner_ai_direct_sources WHERE source_message_id=?''',
      [incoming.messageId],
    )).singleOrNull;
    if (source == null ||
        source['owner_account_id'] != incoming.senderId ||
        source['conversation_id'] != incoming.conversationId) {
      return null;
    }
    final rows = await tx.query(
      '''
SELECT m.body FROM messages m
JOIN owner_ai_direct_sources s ON s.source_message_id=m.message_id
WHERE m.message_id=? AND m.conversation_id=? AND m.sender_id=? AND m.seq=?
 AND m.kind='text' AND m.recalled_at IS NULL
 AND s.owner_account_id=? AND s.ai_profile_id=? AND s.ai_account_id=?
 AND s.conversation_id=? AND s.grant_revision=?
 AND NOT EXISTS(SELECT 1 FROM message_edits e WHERE e.message_id=m.message_id)
 AND NOT EXISTS(SELECT 1 FROM social_conversations g WHERE g.id=m.conversation_id)''',
      [
        incoming.messageId,
        incoming.conversationId,
        incoming.senderId,
        incoming.seq,
        source['owner_account_id'],
        source['ai_profile_id'],
        source['ai_account_id'],
        source['conversation_id'],
        source['grant_revision'],
      ],
    );
    if (rows.length != 1) return null;
    final plaintext = cipher.decrypt(
      rows.single['body']! as String,
      aad: 'messages:body:${incoming.messageId}',
    );
    if (plaintext.isErr) return null;
    final Object? decoded;
    try {
      decoded = jsonDecode(plaintext.value);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic> ||
        decoded.length != 1 ||
        decoded['text'] is! String) {
      return null;
    }
    final text = (decoded['text'] as String).trim();
    if (text.isEmpty ||
        utf8.encode(text).length > maxEntryBytes ||
        RegExp(_hidden).hasMatch(text)) {
      return null;
    }
    final owner = source['owner_account_id'] as String;
    final aiProfileId = source['ai_profile_id'] as String;
    // Cap active+pending per AI. Over-limit candidates are simply not written.
    final count =
        (await tx.query(
              '''
SELECT COUNT(*) AS n FROM encrypted_memory
WHERE owning_operator_id=? AND ai_profile_id=? AND scope_key=?
 AND status IN ('active','pending')''',
              [owner, aiProfileId, _scopeKey(owner, aiProfileId)],
            )).single['n']!
            as int;
    if (count >= maxEntries) return null;
    final tier = _memoryInstruction.hasMatch(text)
        ? MemoryTier.t0
        : MemoryTier.t1;
    return MemoryCandidate(
      owningOperatorId: owner,
      aiProfileId: aiProfileId,
      sourceAccountId: owner,
      aboutAccountId: owner,
      scopeKey: _scopeKey(owner, aiProfileId),
      sourceMessageIds: [incoming.messageId],
      body: text,
      overlappingTiers: [tier],
      evidence: EvidenceLevel.userStated,
      userOptedOut: false,
    );
  }

  /// Snapshot only from the accepted-at source stamp. This cannot be forged by
  /// model output or HTTP content, and a later settings/target change makes it
  /// stale. Only active T0/T1 entries are returned, bounded to five entries and
  /// 1024 total UTF-8 bytes; pending is never injected.
  Future<OwnerAutoMemoryUse?> forSourceInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
  ) async {
    final stamp = await _sourceStamp(tx, grant, sourceMessageId);
    if (stamp == null) return null;
    final target = await OwnerAutoMemoryTarget.targetInTx(tx, grant);
    if (target == null || stamp['target_token'] != target.token) return null;
    final texts = await _injectable(tx, grant.ownerAccountId, grant.aiProfileId);
    if (texts == null || texts.isEmpty) return null;
    final selected = <String>[];
    var bytes = 0;
    for (final text in texts) {
      final length = utf8.encode(text).length;
      if (selected.length >= maxInjectedEntries ||
          bytes + length > maxInjectedBytes) {
        break;
      }
      selected.add(text);
      bytes += length;
    }
    if (selected.isEmpty) return null;
    return OwnerAutoMemoryUse._(
      target,
      stamp['settings_revision']! as int,
      List.unmodifiable(selected),
    );
  }

  /// The same accepted-at grant must still hold at model handoff and reply
  /// publication.
  Future<bool> isFreshInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
    OwnerAutoMemoryUse expected,
  ) async {
    final stamp = await _sourceStamp(tx, grant, sourceMessageId);
    if (stamp == null ||
        stamp['settings_revision'] != expected._settingsRevision ||
        stamp['target_token'] != expected._target.token) {
      return false;
    }
    final target = await OwnerAutoMemoryTarget.targetInTx(tx, grant);
    return target?.token == expected._target.token &&
        target?.baseUrl == expected._target.baseUrl;
  }

  Map<String, Object?> _renderSettings(
    int revision,
    Map<String, Object?>? saved,
    OwnerAutoMemoryTarget? target,
  ) {
    final enabled =
        saved?['enabled'] == 1 &&
        target != null &&
        saved?['target_token'] == target.token;
    return {
      'revision': revision,
      'enabled': enabled,
      'target': target?.toJson(),
    };
  }

  Future<Result<Map<String, Object?>>> _renderEntries(
    Tx tx,
    String owner,
    String ai,
    int revision,
  ) async {
    final entries = await _listEntries(tx, owner, ai);
    if (entries == null) return _storageUnavailable();
    return Ok({
      'revision': revision,
      'maxEntries': maxEntries,
      'entries': entries.map((e) => e.toJson()).toList(),
    });
  }

  Future<List<OwnerAutoMemoryEntry>?> _listEntries(
    Tx tx,
    String owner,
    String ai,
  ) async {
    final rows = await tx.query(
      '''
SELECT id,scope_key,tier,status,encrypted_body,created_at FROM encrypted_memory
WHERE owning_operator_id=? AND ai_profile_id=? AND scope_key=?
 AND status IN ('active','pending') AND tier IN ('t0','t1')
ORDER BY created_at DESC,id DESC''',
      [owner, ai, _scopeKey(owner, ai)],
    );
    final result = <OwnerAutoMemoryEntry>[];
    for (final row in rows) {
      final id = row['id']! as String;
      final scopeKey = row['scope_key']! as String;
      final plain = cipher.decrypt(
        row['encrypted_body']! as String,
        aad: _aad(owner, ai, scopeKey, id),
      );
      if (plain.isErr) return null;
      result.add(
        OwnerAutoMemoryEntry(
          id: id,
          text: plain.value,
          tier: MemoryTier.values.byName(row['tier']! as String),
          status: MemoryStatus.values.byName(row['status']! as String),
          createdAt: DateTime.parse(row['created_at']! as String),
        ),
      );
    }
    return result;
  }

  Future<List<String>?> _injectable(Tx tx, String owner, String ai) async {
    final rows = await tx.query(
      '''
SELECT id,scope_key,encrypted_body FROM encrypted_memory
WHERE owning_operator_id=? AND ai_profile_id=? AND scope_key=?
 AND status='active' AND tier IN ('t0','t1')
ORDER BY created_at DESC,id DESC''',
      [owner, ai, _scopeKey(owner, ai)],
    );
    final result = <String>[];
    for (final row in rows) {
      final id = row['id']! as String;
      final plain = cipher.decrypt(
        row['encrypted_body']! as String,
        aad: _aad(owner, ai, row['scope_key']! as String, id),
      );
      if (plain.isErr) return null;
      result.add(plain.value);
    }
    return result;
  }

  /// Removes one entry from the injectable set. Returns false when the policy
  /// state machine forbids the transition (unreachable for the active/pending
  /// rows this manager lists, but never silently forced).
  Future<bool> _transitionEntry(
    Tx tx,
    String owner,
    String ai,
    OwnerAutoMemoryEntry entry,
    DateTime at,
  ) async {
    // MemoryPolicy.canTransition forbids pending -> deleted, so a pending
    // entry is rejected by the owner instead. Both leave the visible set.
    final to = entry.status == MemoryStatus.active
        ? MemoryStatus.deleted
        : MemoryStatus.rejected;
    // This path runs inside the caller's transaction (MemoryStore.transition
    // would open a nested one), so the same state machine is enforced here and
    // the store's "model cannot confirm" rule holds by construction: this
    // service only ever moves entries *out* of the injectable set.
    if (!const MemoryPolicy().canTransition(entry.status, to)) return false;
    final updated = await tx.execute(
      'UPDATE encrypted_memory SET status=? WHERE id=? AND owning_operator_id=? AND ai_profile_id=? AND scope_key=? AND status=?',
      [to.name, entry.id, owner, ai, _scopeKey(owner, ai), entry.status.name],
    );
    if (updated != 1) return false;
    await tx.execute(
      '''
INSERT INTO audit_log(at,actor_id,action,target_kind,target_id,meta)
VALUES(?,?,'memory.transition','memory',?,?)''',
      [
        at.toIso8601String(),
        owner,
        entry.id,
        jsonEncode({'from': entry.status.name, 'to': to.name}),
      ],
    );
    return true;
  }

  Future<Map<String, Object?>?> _sourceStamp(
    Tx tx,
    OwnerAiDirectGrant grant,
    String source,
  ) async => (await tx.query(
    '''
SELECT s.settings_revision,s.target_token FROM owner_auto_memory_sources s
JOIN owner_auto_memory_settings p
  ON p.owner_id=(SELECT owner_account_id FROM owner_ai_direct_sources WHERE source_message_id=?)
 AND p.ai_profile_id=(SELECT ai_profile_id FROM owner_ai_direct_sources WHERE source_message_id=?)
 AND p.revision=s.settings_revision AND p.target_token=s.target_token AND p.enabled=1
JOIN owner_ai_direct_sources src ON src.source_message_id=s.source_message_id
WHERE s.source_message_id=? AND src.owner_account_id=? AND src.ai_profile_id=?
 AND src.ai_account_id=? AND src.conversation_id=? AND src.grant_revision=?''',
    [
      source,
      source,
      source,
      grant.ownerAccountId,
      grant.aiProfileId,
      grant.aiAccountId,
      grant.conversationId,
      grant.revision,
    ],
  )).singleOrNull;

  Future<Map<String, Object?>?> _settingsRow(
    Tx tx,
    String owner,
    AiId ai,
  ) async => (await tx.query(
    'SELECT * FROM owner_auto_memory_settings WHERE owner_id=? AND ai_profile_id=?',
    [owner, ai.value],
  )).singleOrNull;

  Future<void> _bump(Tx tx, String owner, String ai, int revision) async {
    final updated = await tx.execute(
      'UPDATE owner_auto_memory_settings SET revision=? WHERE owner_id=? AND ai_profile_id=?',
      [revision, owner, ai],
    );
    if (updated == 0) {
      await tx.execute(
        '''
INSERT INTO owner_auto_memory_settings(owner_id,ai_profile_id,revision,enabled,target_token)
VALUES(?,?,?,0,NULL)''',
        [owner, ai, revision],
      );
    }
  }

  String _scopeKey(String owner, String aiProfileId) =>
      'private:$aiProfileId:$owner';

  String _aad(String owner, String ai, String scopeKey, String id) =>
      jsonEncode([owner, ai, scopeKey, id]);

  Future<Failure?> _callerFailure(
    Tx tx,
    String owner,
    String device,
    String bearer,
  ) async {
    if (bearer.length != 22) {
      return const Failure(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final rows = await tx.query(
      '''
SELECT a.kind FROM device d JOIN refresh_token r ON r.device_id=d.id
JOIN account a ON a.id=d.account_id AND a.disabled=0
WHERE d.id=? AND d.account_id=? AND d.access_hash=? AND d.access_expires>?''',
      [
        device,
        owner,
        sha256.convert(utf8.encode(bearer)).toString(),
        clock.now().toUtc().millisecondsSinceEpoch,
      ],
    );
    if (rows.length != 1) {
      return const Failure(FailureCode.unauthenticated, 'Invalid credentials');
    }
    return rows.single['kind'] == 'human'
        ? null
        : const Failure(FailureCode.notFound, 'Auto memory not found');
  }

  Future<String?> _ownedAi(Tx tx, String owner, AiId ai) async =>
      (await tx.query(
            '''
SELECT p.account_id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE p.id=?''',
            [owner, ai.value],
          )).singleOrNull?['account_id']
          as String?;

  Future<OwnerAiDirectGrant?> _pair(
    Tx tx,
    String owner,
    AiId ai,
    String account,
  ) async {
    final row = (await tx.query(
      '''
SELECT conversation_id FROM owner_ai_direct_grants g WHERE owner_account_id=? AND ai_profile_id=?
 AND NOT EXISTS(SELECT 1 FROM social_conversations s WHERE s.id=g.conversation_id)''',
      [owner, ai.value],
    )).singleOrNull;
    if (row == null) return null;
    final grant = await OwnerAiDirectConsent.resolveInTx(
      tx,
      ownerAccountId: owner,
      conversationId: row['conversation_id']! as String,
    );
    if (grant?.aiAccountId != account || grant?.aiProfileId != ai.value) {
      return null;
    }
    return grant;
  }

  Future<void> _audit(
    Tx tx,
    String actor,
    String action,
    String ai,
    Map<String, Object?> meta,
  ) async {
    await tx.execute(
      'INSERT INTO audit_log(at,actor_id,action,target_kind,target_id,meta) VALUES(?,?,?,?,?,?)',
      [
        clock.now().toUtc().toIso8601String(),
        actor,
        action,
        'ai_profile',
        ai,
        jsonEncode(meta),
      ],
    );
  }

  static Result<Map<String, Object?>> _notFound() =>
      err(FailureCode.notFound, 'AI not found');
  static Result<Map<String, Object?>> _entryNotFound() =>
      err(FailureCode.notFound, 'Auto memory entry not found');
  static Result<Map<String, Object?>> _storageUnavailable() =>
      err(FailureCode.internal, 'Auto memory storage unavailable');
}

enum _WriteKind { delete, clear }
