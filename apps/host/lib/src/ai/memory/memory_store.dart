import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';

import '../../storage/cipher.dart';
import '../../storage/database.dart';

/// Metadata only: never contains a decrypted body. Source IDs are immutable.
final class MemoryEntry {
  MemoryEntry({
    required this.owningOperatorId,
    required this.aiProfileId,
    required this.sourceAccountId,
    required this.aboutAccountId,
    required this.scopeKey,
    required List<String> sourceMessageIds,
  }) : sourceMessageIds = List.unmodifiable(sourceMessageIds);
  final String owningOperatorId;
  final String aiProfileId;
  final String sourceAccountId;
  final String? aboutAccountId;
  final String scopeKey;
  final List<String> sourceMessageIds;
}

/// Trusted internal classifier output. Never bind this directly from HTTP or
/// model tool arguments: opt-out and evidence require trusted provenance.
final class MemoryCandidate {
  MemoryCandidate({
    required String owningOperatorId,
    required String aiProfileId,
    required String sourceAccountId,
    required String? aboutAccountId,
    required String scopeKey,
    required List<String> sourceMessageIds,
    required this.body,
    required List<MemoryTier> overlappingTiers,
    required this.evidence,
    required this.userOptedOut,
  }) : entry = MemoryEntry(
         owningOperatorId: owningOperatorId,
         aiProfileId: aiProfileId,
         sourceAccountId: sourceAccountId,
         aboutAccountId: aboutAccountId,
         scopeKey: scopeKey,
         sourceMessageIds: sourceMessageIds,
       ),
       overlappingTiers = List.unmodifiable(overlappingTiers);
  final MemoryEntry entry;
  final String body;
  final List<MemoryTier> overlappingTiers;
  final EvidenceLevel evidence;
  final bool userOptedOut;
}

/// Construct only at a trusted service boundary, never from model assertions.
/// Actor identity and model origin must come from authenticated execution state.
final class MemoryContext {
  const MemoryContext({
    required this.owningOperatorId,
    required this.aiProfileId,
    required this.talkingWith,
    required this.actorAccountId,
    required this.isModelActor,
  });
  final String owningOperatorId;
  final String aiProfileId;
  final String talkingWith;
  final String actorAccountId;
  final bool isModelActor;
}

/// All checks use the supplied live transaction, canonical identities, real
/// source messages and scope visibility. No permissive default is provided.
/// A production implementation for private/group/topic scopes is required
/// before wiring this store into a host or claiming cross-user availability.
abstract interface class MemoryAuthorization {
  Future<bool> authorizeCapture(Tx tx, MemoryCandidate candidate);
  Future<bool> authorizeRead(Tx tx, MemoryEntry entry, MemoryContext context);
  Future<bool> authorizeTransition(
    Tx tx,
    MemoryEntry entry,
    MemoryContext context,
    MemoryStatus to,
  );
}

final class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.entry,
    required this.tier,
    required this.status,
    required this.evidence,
    required this.createdAt,
  });
  final String id;
  final MemoryEntry entry;
  final MemoryTier tier;
  final MemoryStatus status;
  final EvidenceLevel evidence;
  final DateTime createdAt;
}

/// Model-facing result; source prefix uses validated account IDs, never display
/// names supplied by a user. T2 is always excluded; no redaction is claimed.
final class MemoryHit {
  const MemoryHit({
    required this.id,
    required this.sourceAccountId,
    required this.text,
  });
  final String id;
  final String sourceAccountId;
  final String text;
}

final class MemoryStore {
  MemoryStore({
    required Database database,
    required ColumnCipher cipher,
    required Clock clock,
    required MemoryAuthorization authorizer,
  }) : _db = database,
       _cipher = cipher,
       _clock = clock,
       _authorizer = authorizer;
  final Database _db;
  final ColumnCipher _cipher;
  final Clock _clock;
  final MemoryAuthorization _authorizer;
  final _policy = const MemoryPolicy();
  final _random = Random.secure();

  bool _validEntry(MemoryEntry e) {
    final id = RegExp(r'^[A-Za-z0-9_-]{1,128}$');
    if (![
          e.owningOperatorId,
          e.aiProfileId,
          e.sourceAccountId,
          if (e.aboutAccountId != null) e.aboutAccountId!,
          ...e.sourceMessageIds,
        ].every(id.hasMatch) ||
        e.sourceMessageIds.isEmpty) {
      return false;
    }
    final parts = e.scopeKey.split(':');
    return parts.length >= 3 &&
        parts[1] == e.aiProfileId &&
        parts.skip(2).every(id.hasMatch) &&
        ((parts[0] == 'private' && parts.length == 3) ||
            (parts[0] == 'group' && parts.length == 3) ||
            (parts[0] == 'topic' && parts.length == 4));
  }

  String _aad(MemoryEntry entry, String id) => jsonEncode([
    entry.owningOperatorId,
    entry.aiProfileId,
    entry.scopeKey,
    id,
  ]);

  Future<Result<MemoryRecord?>> capture(MemoryCandidate candidate) async {
    // This must precede even validation, authorization and transaction creation.
    if (_policy.collectionDecision(userOptedOut: candidate.userOptedOut) ==
        CollectionDecision.deny) {
      return const Ok(null);
    }
    if (!_validEntry(candidate.entry) || candidate.body.trim().isEmpty) {
      return err(FailureCode.invalidArgument, 'Invalid memory candidate');
    }
    return _db.transaction((tx) async {
      if (!await _authorizer.authorizeCapture(tx, candidate)) {
        return err(FailureCode.forbidden, 'Memory source not authorized');
      }
      final tier = _policy.resolveTier(
        candidate.overlappingTiers.isEmpty
            ? const [MemoryTier.t1]
            : candidate.overlappingTiers,
      );
      final status = _policy.initialStatus(
        tier: tier,
        level: candidate.evidence,
      );
      final id = List.generate(
        24,
        (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      final entry = candidate.entry;
      final now = _clock.now();
      final sealed = _cipher.encrypt(candidate.body, aad: _aad(entry, id));
      await tx.execute(
        '''INSERT INTO encrypted_memory
(id,owning_operator_id,ai_profile_id,source_account_id,about_account_id,
scope_key,tier,status,evidence,encrypted_body,created_at)
VALUES (?,?,?,?,?,?,?,?,?,?,?)''',
        [
          id,
          entry.owningOperatorId,
          entry.aiProfileId,
          entry.sourceAccountId,
          entry.aboutAccountId,
          entry.scopeKey,
          tier.name,
          status.name,
          candidate.evidence.name,
          sealed,
          now.toUtc().toIso8601String(),
        ],
      );
      for (final source in entry.sourceMessageIds.toSet()) {
        await tx.execute('INSERT INTO memory_source_messages VALUES (?,?)', [
          id,
          source,
        ]);
      }
      return Ok(
        MemoryRecord(
          id: id,
          entry: entry,
          tier: tier,
          status: status,
          evidence: candidate.evidence,
          createdAt: now,
        ),
      );
    });
  }

  Future<MemoryRecord> _record(Tx tx, Map<String, Object?> row) async {
    final links = await tx.query(
      'SELECT source_message_id FROM memory_source_messages WHERE memory_id=? ORDER BY source_message_id',
      [row['id']],
    );
    return MemoryRecord(
      id: row['id'] as String,
      entry: MemoryEntry(
        owningOperatorId: row['owning_operator_id'] as String,
        aiProfileId: row['ai_profile_id'] as String,
        sourceAccountId: row['source_account_id'] as String,
        aboutAccountId: row['about_account_id'] as String?,
        scopeKey: row['scope_key'] as String,
        sourceMessageIds: links
            .map((r) => r['source_message_id'] as String)
            .toList(),
      ),
      tier: MemoryTier.values.byName(row['tier'] as String),
      status: MemoryStatus.values.byName(row['status'] as String),
      evidence: EvidenceLevel.values.byName(row['evidence'] as String),
      createdAt: DateTime.parse(row['created_at'] as String),
    );
  }

  /// SQL narrows owner/AI/status/tier BEFORE any authorization or decryption.
  /// Query is literal substring matching over authorized entries only. This
  /// minimal repository provides no embeddings, manager API or redaction.
  Future<Result<List<MemoryHit>>> retrieve(
    MemoryContext context, {
    String query = '',
    int topK = 8,
  }) async {
    if (topK < 1 || topK > 100) {
      return err(FailureCode.invalidArgument, 'Invalid memory result limit');
    }
    return _db.transaction((tx) async {
      final rows = await tx.query(
        '''SELECT * FROM encrypted_memory
WHERE owning_operator_id=? AND ai_profile_id=? AND status='active'
AND tier IN ('t0','t1') ORDER BY created_at DESC,id''',
        [context.owningOperatorId, context.aiProfileId],
      );
      final hits = <MemoryHit>[];
      for (final row in rows) {
        final record = await _record(tx, row);
        if (!_validEntry(record.entry) ||
            !await _authorizer.authorizeRead(tx, record.entry, context) ||
            !_policy.mayInject(
              status: record.status,
              tier: record.tier,
              forOwnerAi: context.talkingWith == record.entry.owningOperatorId,
            )) {
          continue;
        }
        final body = _cipher.decrypt(
          row['encrypted_body'] as String,
          aad: _aad(record.entry, record.id),
        );
        if (body.isErr) {
          return err(FailureCode.internal, 'Memory authentication failed');
        }
        if (!body.value.toLowerCase().contains(query.toLowerCase())) {
          continue;
        }
        final source = record.entry.sourceAccountId;
        hits.add(
          MemoryHit(
            id: record.id,
            sourceAccountId: source,
            text: '$source 跟我说过：${body.value}',
          ),
        );
        if (hits.length == topK) break;
      }
      return Ok(List.unmodifiable(hits));
    });
  }

  Future<Result<void>> transition(
    MemoryContext context,
    String id,
    MemoryStatus to,
  ) async {
    // Even an incorrectly implemented authorizer cannot let a model confirm.
    if (context.isModelActor && to == MemoryStatus.active) {
      return err(FailureCode.forbidden, 'Model cannot confirm memory');
    }
    return _db.transaction((tx) async {
      final rows = await tx.query(
        '''SELECT * FROM encrypted_memory
WHERE id=? AND owning_operator_id=? AND ai_profile_id=?''',
        [id, context.owningOperatorId, context.aiProfileId],
      );
      if (rows.isEmpty) return err(FailureCode.notFound, 'Memory not found');
      final record = await _record(tx, rows.single);
      if (!_validEntry(record.entry) ||
          !await _authorizer.authorizeTransition(
            tx,
            record.entry,
            context,
            to,
          )) {
        return err(FailureCode.forbidden, 'Memory transition not authorized');
      }
      if (!_policy.canTransition(record.status, to)) {
        return err(FailureCode.conflict, 'Invalid memory transition');
      }
      await tx.execute('UPDATE encrypted_memory SET status=? WHERE id=?', [
        to.name,
        id,
      ]);
      await tx.execute(
        '''INSERT INTO audit_log
(at,actor_id,action,target_kind,target_id,meta) VALUES (?,?,?,?,?,?)''',
        [
          _clock.now().toUtc().toIso8601String(),
          context.actorAccountId,
          'memory.transition',
          'memory',
          id,
          jsonEncode({'from': record.status.name, 'to': to.name}),
        ],
      );
      return const Ok(null);
    });
  }
}
