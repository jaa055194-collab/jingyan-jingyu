import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../social/owner_ai_direct_consent.dart';
import '../../storage/cipher.dart';
import '../../storage/database.dart';

/// Owner-facing note. The plaintext exists only in this process's memory for
/// the duration of the request; it is never accepted from any other source.
final class OwnerMemoryNote {
  const OwnerMemoryNote({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
  });
  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'id': id,
    'text': text,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// Immutable snapshot carried into one accepted owner text. The live
/// `isFreshInTx` check is what authorizes the later model call.
final class OwnerMemoryNoteUse {
  const OwnerMemoryNoteUse._(this._target, this._settingsRevision, this.notes);
  final _MemoryTarget _target;
  final int _settingsRevision;
  final List<String> notes;

  bool matchesRecipient(String providerId, String model, String baseUrl) =>
      providerId == _target.providerId &&
      model == _target.model &&
      baseUrl == _target.baseUrl;
}

final class _MemoryTarget {
  const _MemoryTarget(
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
}

/// Explicit owner notes plus a separate, default-off grant to include them in
/// the owner's own B2 direct reply. No automatic capture, model confirmation,
/// history read, group scope, third-party data or proactive send exists.
final class OwnerMemoryNotes {
  OwnerMemoryNotes({
    required this.database,
    required this.cipher,
    required this.clock,
  });

  final Database database;
  final ColumnCipher cipher;
  final Clock clock;
  final Random _random = Random.secure();
  static const maxNotes = 20;
  static const maxNoteBytes = 512;
  static const maxInjectedNotes = 5;
  static const maxInjectedBytes = 1024;
  static const _hidden =
      r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]';

  Future<Result<Map<String, Object?>>> read({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
  }) => _access(owner: owner, device: device, bearer: bearer, ai: ai);

  Future<Result<Map<String, Object?>>> add({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required String text,
    required int expectedRevision,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.add,
      text: text,
      noteId: null,
      expectedRevision: expectedRevision,
      enabled: null,
      targetToken: null,
    ),
  );

  Future<Result<Map<String, Object?>>> edit({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required String noteId,
    required String text,
    required int expectedRevision,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.edit,
      text: text,
      noteId: noteId,
      expectedRevision: expectedRevision,
      enabled: null,
      targetToken: null,
    ),
  );

  Future<Result<Map<String, Object?>>> delete({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required String noteId,
    required int expectedRevision,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.delete,
      text: null,
      noteId: noteId,
      expectedRevision: expectedRevision,
      enabled: null,
      targetToken: null,
    ),
  );

  Future<Result<Map<String, Object?>>> clear({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required int expectedRevision,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.clear,
      text: null,
      noteId: null,
      expectedRevision: expectedRevision,
      enabled: null,
      targetToken: null,
    ),
  );

  Future<Result<Map<String, Object?>>> setEnabled({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required int expectedRevision,
    required bool enabled,
    required String? expectedTargetToken,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      kind: _WriteKind.settings,
      text: null,
      noteId: null,
      expectedRevision: expectedRevision,
      enabled: enabled,
      targetToken: expectedTargetToken,
    ),
  );

  Future<Result<Map<String, Object?>>> _access({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    _MemoryWrite? write,
  }) => database.transaction((tx) async {
    final denied = await _callerFailure(tx, owner, device, bearer);
    if (denied != null) return Err(denied);
    final account = await _ownedAi(tx, owner, ai);
    if (account == null) return _notFound();
    final grant = await _pair(tx, owner, ai, account);
    final target = grant == null ? null : await _target(tx, grant);
    final saved = await _settingsRow(tx, owner, ai);
    final revision = saved?['revision'] as int? ?? 0;
    if (write == null) {
      return _render(tx, owner, ai, saved, target);
    }
    if (write.expectedRevision < 0 || write.expectedRevision != revision) {
      return err(FailureCode.conflict, 'Memory note revision changed');
    }
    final now = clock.now().toUtc();
    var next = revision + 1;
    switch (write.kind) {
      case _WriteKind.add:
        final text = _validateText(write.text);
        if (text == null) return _invalid();
        final count =
            (await tx.query(
                  'SELECT COUNT(*) AS n FROM owner_memory_notes WHERE owner_id=? AND ai_profile_id=?',
                  [owner, ai.value],
                )).single['n']!
                as int;
        if (count >= maxNotes) {
          return err(FailureCode.invalidArgument, 'Memory note limit reached');
        }
        final id = _newId();
        await tx.execute('INSERT INTO owner_memory_notes VALUES(?,?,?,?,?,?)', [
          id,
          owner,
          ai.value,
          cipher.encrypt(text, aad: _aad(owner, ai.value, id)),
          now.toIso8601String(),
          now.toIso8601String(),
        ]);
        await _bump(tx, owner, ai.value, next);
        await _audit(tx, now, owner, 'owner_memory_note.add', ai.value, {
          'noteId': id,
          'revision': next,
        });
      case _WriteKind.edit:
        final text = _validateText(write.text);
        if (text == null) return _invalid();
        final existing = await _note(tx, owner, ai.value, write.noteId!);
        if (existing == null) return _noteNotFound();
        await tx.execute(
          'UPDATE owner_memory_notes SET encrypted_body=?,updated_at=? WHERE id=?',
          [
            cipher.encrypt(text, aad: _aad(owner, ai.value, write.noteId!)),
            now.toIso8601String(),
            write.noteId,
          ],
        );
        await _bump(tx, owner, ai.value, next);
        await _audit(tx, now, owner, 'owner_memory_note.edit', ai.value, {
          'noteId': write.noteId,
          'revision': next,
        });
      case _WriteKind.delete:
        if (await _note(tx, owner, ai.value, write.noteId!) == null) {
          return _noteNotFound();
        }
        await tx.execute(
          'DELETE FROM owner_memory_notes WHERE id=? AND owner_id=? AND ai_profile_id=?',
          [write.noteId, owner, ai.value],
        );
        await _bump(tx, owner, ai.value, next);
        await _audit(tx, now, owner, 'owner_memory_note.delete', ai.value, {
          'noteId': write.noteId,
          'revision': next,
        });
      case _WriteKind.clear:
        await tx.execute(
          'DELETE FROM owner_memory_notes WHERE owner_id=? AND ai_profile_id=?',
          [owner, ai.value],
        );
        await _bump(tx, owner, ai.value, next);
        await _audit(tx, now, owner, 'owner_memory_note.clear', ai.value, {
          'revision': next,
        });
      case _WriteKind.settings:
        final enabled = write.enabled!;
        final expected = write.targetToken;
        if ((enabled &&
                (target == null ||
                    expected == null ||
                    expected != target.token)) ||
            (!enabled && expected != null)) {
          return enabled && target == null
              ? err(FailureCode.conflict, 'Memory note target unavailable')
              : err(FailureCode.invalidArgument, 'Invalid memory note setting');
        }
        await tx.execute(
          '''
INSERT INTO owner_memory_note_settings(owner_id,ai_profile_id,revision,enabled,target_token)
VALUES(?,?,?,?,?) ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET
revision=excluded.revision,enabled=excluded.enabled,target_token=excluded.target_token''',
          [
            owner,
            ai.value,
            next,
            enabled ? 1 : 0,
            enabled ? target!.token : null,
          ],
        );
        await _audit(tx, now, owner, 'owner_memory_note.settings', ai.value, {
          'enabled': enabled,
          'revision': next,
        });
    }
    final fresh = await _settingsRow(tx, owner, ai);
    return _render(tx, owner, ai, fresh, target);
  });

  /// Snapshot only from the accepted-at source stamp. This cannot be forged by
  /// model output or HTTP content, and a later note/settings change makes it
  /// stale.
  Future<OwnerMemoryNoteUse?> forSourceInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
  ) async {
    final stamp = await _sourceStamp(tx, grant, sourceMessageId);
    if (stamp == null) return null;
    final target = await _target(tx, grant);
    if (target == null || stamp['target_token'] != target.token) return null;
    final notes = await _notes(tx, grant.ownerAccountId, grant.aiProfileId);
    if (notes == null || notes.isEmpty) return null;
    // Newest-first deterministic bound. The owner may retain up to maxNotes,
    // but one B2 prompt receives at most maxInjectedNotes and maxInjectedBytes.
    final selected = <String>[];
    var bytes = 0;
    for (final note in notes) {
      final length = utf8.encode(note.text).length;
      if (selected.length >= maxInjectedNotes ||
          bytes + length > maxInjectedBytes) {
        break;
      }
      selected.add(note.text);
      bytes += length;
    }
    if (selected.isEmpty) return null;
    return OwnerMemoryNoteUse._(
      target,
      stamp['settings_revision']! as int,
      List.unmodifiable(selected),
    );
  }

  /// Same accepted-at grant must still hold at model handoff and reply publish.
  Future<bool> isFreshInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
    OwnerMemoryNoteUse expected,
  ) async {
    final stamp = await _sourceStamp(tx, grant, sourceMessageId);
    if (stamp == null ||
        stamp['settings_revision'] != expected._settingsRevision ||
        stamp['target_token'] != expected._target.token) {
      return false;
    }
    final target = await _target(tx, grant);
    return target?.token == expected._target.token &&
        target?.baseUrl == expected._target.baseUrl;
  }

  Future<Map<String, Object?>?> _sourceStamp(
    Tx tx,
    OwnerAiDirectGrant grant,
    String source,
  ) async => (await tx.query(
    '''
SELECT s.settings_revision,s.target_token FROM owner_memory_note_sources s
JOIN owner_memory_note_settings p
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

  Future<Result<Map<String, Object?>>> _render(
    Tx tx,
    String owner,
    AiId ai,
    Map<String, Object?>? saved,
    _MemoryTarget? target,
  ) async {
    final notes = await _notes(tx, owner, ai.value);
    if (notes == null) {
      return err(FailureCode.internal, 'Memory note storage unavailable');
    }
    final enabled =
        saved?['enabled'] == 1 &&
        target != null &&
        saved?['target_token'] == target.token;
    return Ok({
      'revision': saved?['revision'] as int? ?? 0,
      'enabled': enabled,
      'maxNotes': maxNotes,
      'maxNoteBytes': maxNoteBytes,
      'notes': notes.map((n) => n.toJson()).toList(),
      'target': target?.toJson(),
    });
  }

  Future<List<OwnerMemoryNote>?> _notes(Tx tx, String owner, String ai) async {
    final rows = await tx.query(
      '''SELECT id,encrypted_body,created_at,updated_at FROM owner_memory_notes
WHERE owner_id=? AND ai_profile_id=? ORDER BY created_at DESC,id DESC''',
      [owner, ai],
    );
    final result = <OwnerMemoryNote>[];
    for (final row in rows) {
      final id = row['id']! as String;
      final plain = cipher.decrypt(
        row['encrypted_body']! as String,
        aad: _aad(owner, ai, id),
      );
      if (plain.isErr) return null;
      result.add(
        OwnerMemoryNote(
          id: id,
          text: plain.value,
          createdAt: DateTime.parse(row['created_at']! as String),
          updatedAt: DateTime.parse(row['updated_at']! as String),
        ),
      );
    }
    return result;
  }

  Future<Map<String, Object?>?> _note(
    Tx tx,
    String owner,
    String ai,
    String id,
  ) async => (await tx.query(
    'SELECT id FROM owner_memory_notes WHERE id=? AND owner_id=? AND ai_profile_id=?',
    [id, owner, ai],
  )).singleOrNull;

  Future<Map<String, Object?>?> _settingsRow(
    Tx tx,
    String owner,
    AiId ai,
  ) async => (await tx.query(
    'SELECT * FROM owner_memory_note_settings WHERE owner_id=? AND ai_profile_id=?',
    [owner, ai.value],
  )).singleOrNull;

  Future<void> _bump(Tx tx, String owner, String ai, int revision) async {
    final updated = await tx.execute(
      'UPDATE owner_memory_note_settings SET revision=? WHERE owner_id=? AND ai_profile_id=?',
      [revision, owner, ai],
    );
    if (updated == 0) {
      await tx.execute(
        '''
INSERT INTO owner_memory_note_settings(owner_id,ai_profile_id,revision,enabled,target_token)
VALUES(?,?,?,0,NULL)''',
        [owner, ai, revision],
      );
    }
  }

  String? _validateText(String? value) {
    if (value == null) return null;
    final text = value.trim();
    if (text.isEmpty || utf8.encode(text).length > maxNoteBytes) return null;
    if (RegExp(_hidden).hasMatch(text)) return null;
    return text;
  }

  String _newId() => List.generate(
    24,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  String _aad(String owner, String ai, String id) =>
      jsonEncode(['owner-memory-note:v1', owner, ai, id]);

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
        : const Failure(FailureCode.notFound, 'Memory notes not found');
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

  Future<_MemoryTarget?> _target(Tx tx, OwnerAiDirectGrant grant) async {
    final row = (await tx.query(
      '''
SELECT p.id,p.base_url,b.model,e.epoch FROM model_bindings b
JOIN providers p ON p.owner_id=b.owner_id AND p.id=b.provider_id AND p.enabled=1
JOIN owner_memory_target_epochs e ON e.owner_id=b.owner_id AND e.ai_profile_id=b.ai_profile_id
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
        RegExp(_hidden).hasMatch(model)) {
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
              'owner-memory-notes:v1',
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
    return _MemoryTarget(id, model, raw, uri.origin, token);
  }

  Future<void> _audit(
    Tx tx,
    DateTime at,
    String actor,
    String action,
    String ai,
    Map<String, Object?> meta,
  ) async {
    await tx.execute(
      'INSERT INTO audit_log(at,actor_id,action,target_kind,target_id,meta) VALUES(?,?,?,?,?,?)',
      [at.toIso8601String(), actor, action, 'ai_profile', ai, jsonEncode(meta)],
    );
  }

  static Result<Map<String, Object?>> _invalid() =>
      err(FailureCode.invalidArgument, 'Invalid memory note input');
  static Result<Map<String, Object?>> _notFound() =>
      err(FailureCode.notFound, 'AI not found');
  static Result<Map<String, Object?>> _noteNotFound() =>
      err(FailureCode.notFound, 'Memory note not found');
}

enum _WriteKind { add, edit, delete, clear, settings }

typedef _MemoryWrite = ({
  _WriteKind kind,
  String? text,
  String? noteId,
  int expectedRevision,
  bool? enabled,
  String? targetToken,
});
