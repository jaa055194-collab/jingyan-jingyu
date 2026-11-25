import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../../social/owner_ai_direct_consent.dart';
import '../../storage/cipher.dart';
import '../../storage/database.dart';

enum OwnerReplyLength { brief, detailed }

enum OwnerReplyFormat { paragraphs, bullets }

/// Fixed low-risk choices only: no free-form note or remembered chat content.
final class OwnerReplyChoices {
  const OwnerReplyChoices({this.length, this.format});
  final OwnerReplyLength? length;
  final OwnerReplyFormat? format;
  bool get isEmpty => length == null && format == null;

  Map<String, Object?> toJson() => {
    'length': length?.name,
    'format': format?.name,
  };

  factory OwnerReplyChoices.parse(Object? length, Object? format) {
    T? optional<T extends Enum>(Object? raw, List<T> values) {
      if (raw == null) return null;
      for (final value in values) {
        if (raw == value.name) return value;
      }
      throw const FormatException('Invalid reply preference choice');
    }

    return OwnerReplyChoices(
      length: optional(length, OwnerReplyLength.values),
      format: optional(format, OwnerReplyFormat.values),
    );
  }
}

/// Pin for exactly one accepted source. Never persists or exposes a credential.
/// Tracks the full configured base URL internally, rather than the displayed
/// origin, and ties use to both choice and recipient incarnations.
final class OwnerReplyPreferenceUse {
  const OwnerReplyPreferenceUse._(this._target, this._revision, this.choices);
  final _Recipient _target;
  final int _revision;
  final OwnerReplyChoices choices;

  bool matchesRecipient(String providerId, String model, String baseUrl) =>
      providerId == _target.providerId &&
      model == _target.model &&
      baseUrl == _target.baseUrl;
}

final class _Recipient {
  const _Recipient(
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

/// Independent, default-off grant for the current owner's canonical AI direct
/// reply. This service does not open conversations or invoke a model.
final class OwnerReplyPreferences {
  OwnerReplyPreferences({
    required this.database,
    required this.cipher,
    required this.clock,
  });

  final Database database;
  final ColumnCipher cipher;
  final Clock clock;

  Future<Result<Map<String, Object?>>> read({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
  }) => _access(owner: owner, device: device, bearer: bearer, ai: ai);

  Future<Result<Map<String, Object?>>> write({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    required int expectedRevision,
    required bool enabled,
    required OwnerReplyChoices choices,
    required String? expectedTargetToken,
  }) => _access(
    owner: owner,
    device: device,
    bearer: bearer,
    ai: ai,
    write: (
      expectedRevision: expectedRevision,
      enabled: enabled,
      choices: choices,
      expectedTargetToken: expectedTargetToken,
    ),
  );

  Future<Result<Map<String, Object?>>> _access({
    required String owner,
    required String device,
    required String bearer,
    required AiId ai,
    ({
      int expectedRevision,
      bool enabled,
      OwnerReplyChoices choices,
      String? expectedTargetToken,
    })?
    write,
  }) => database.transaction((tx) async {
    // Same bound account/device, digest, expiry and active-account contract as
    // the SQLite authenticator. Do not re-enter AccountsDomain here: the
    // preference CAS and this live credential check must share one Tx.
    final validBearer =
        bearer.length == 22 &&
        (await tx.query(
              '''
SELECT 1 FROM device d
JOIN refresh_token r ON r.device_id=d.id
JOIN account h ON h.id=d.account_id AND h.disabled=0
WHERE d.id=? AND d.account_id=? AND d.access_hash=? AND d.access_expires>?''',
              [
                device,
                owner,
                sha256.convert(utf8.encode(bearer)).toString(),
                clock.now().toUtc().millisecondsSinceEpoch,
              ],
            )).length ==
            1;
    if (!validBearer) {
      return err(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final canonical = await tx.query(
      '''
SELECT p.account_id FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id AND o.operator_id=?
JOIN account h ON h.id=o.operator_id AND h.kind='human' AND h.disabled=0
WHERE p.id=?''',
      [owner, ai.value],
    );
    if (canonical.length != 1) return err(FailureCode.notFound, 'AI not found');
    final grantRow = (await tx.query(
      '''
SELECT conversation_id FROM owner_ai_direct_grants
WHERE owner_account_id=? AND ai_profile_id=? AND enabled=1''',
      [owner, ai.value],
    )).singleOrNull;
    final grant = grantRow == null
        ? null
        : await OwnerAiDirectConsent.resolveInTx(
            tx,
            ownerAccountId: owner,
            conversationId: grantRow['conversation_id']! as String,
          );
    final target =
        grant?.aiAccountId == canonical.single['account_id'] &&
            grant?.aiProfileId == ai.value
        ? await _recipient(tx, grant!)
        : null;
    final saved = await _row(tx, owner, ai.value);
    final revision = saved?['revision'] as int? ?? 0;
    if (write == null) {
      final choices = _decode(
        owner,
        ai.value,
        saved?['encrypted_choices'] as String?,
      );
      return choices.map(
        (value) => _view(
          revision,
          target != null && saved?['target_token'] == target.token,
          value,
          target,
        ),
      );
    }
    if (write.expectedRevision < 0 ||
        (write.enabled &&
            (write.choices.isEmpty || write.expectedTargetToken == null)) ||
        (!write.enabled && write.expectedTargetToken != null)) {
      return err(
        FailureCode.invalidArgument,
        'Invalid reply preference settings',
      );
    }
    if (write.expectedRevision != revision ||
        (write.enabled &&
            (target == null || target.token != write.expectedTargetToken))) {
      return err(
        FailureCode.conflict,
        'Reply preference revision or target changed',
      );
    }
    final next = revision + 1;
    final encrypted = write.choices.isEmpty
        ? null
        : cipher.encrypt(
            jsonEncode(write.choices.toJson()),
            aad: _aad(owner, ai.value),
          );
    await tx.execute(
      '''
INSERT INTO owner_reply_preferences(owner_id,ai_profile_id,revision,encrypted_choices,target_token)
VALUES(?,?,?,?,?) ON CONFLICT(owner_id,ai_profile_id) DO UPDATE SET
 revision=excluded.revision,encrypted_choices=excluded.encrypted_choices,target_token=excluded.target_token''',
      [owner, ai.value, next, encrypted, write.enabled ? target!.token : null],
    );
    await tx.execute(
      '''
INSERT INTO audit_log(at,actor_id,action,target_kind,target_id,meta)
VALUES(?,?,'owner_reply_preferences.configure','ai_profile',?,?)''',
      [
        clock.now().toUtc().toIso8601String(),
        owner,
        ai.value,
        jsonEncode({'enabled': write.enabled, 'revision': next}),
      ],
    );
    return Ok(_view(next, write.enabled, write.choices, target));
  });

  /// Call only after revalidating the canonical accepted source in the same Tx.
  /// An accepted-at stamp does not itself grant access; it is an extra fence.
  Future<OwnerReplyPreferenceUse?> forSourceInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
  ) async {
    final saved = await _rowForSource(tx, grant, sourceMessageId);
    if (saved == null) return null;
    final target = await _recipient(tx, grant);
    if (target == null || saved['target_token'] != target.token) return null;
    final choices = _decode(
      grant.ownerAccountId,
      grant.aiProfileId,
      saved['encrypted_choices'] as String?,
    );
    if (choices.isErr || choices.value.isEmpty) return null;
    return OwnerReplyPreferenceUse._(
      target,
      saved['revision']! as int,
      choices.value,
    );
  }

  /// The same accepted-at grant must still hold at model admission and reply
  /// publication. Settings, identity and recipient cycles can never revive it.
  Future<bool> isFreshInTx(
    Tx tx,
    OwnerAiDirectGrant grant,
    String sourceMessageId,
    OwnerReplyPreferenceUse expected,
  ) async {
    final saved = await _rowForSource(tx, grant, sourceMessageId);
    if (saved == null ||
        saved['revision'] != expected._revision ||
        saved['target_token'] != expected._target.token) {
      return false;
    }
    final target = await _recipient(tx, grant);
    return target?.token == expected._target.token &&
        target?.baseUrl == expected._target.baseUrl;
  }

  Future<Map<String, Object?>?> _row(
    Tx tx,
    String owner,
    String ai,
  ) async => (await tx.query(
    'SELECT revision,encrypted_choices,target_token FROM owner_reply_preferences WHERE owner_id=? AND ai_profile_id=?',
    [owner, ai],
  )).singleOrNull;

  Future<Map<String, Object?>?> _rowForSource(
    Tx tx,
    OwnerAiDirectGrant grant,
    String source,
  ) async => (await tx.query(
    '''
SELECT p.revision,p.encrypted_choices,p.target_token FROM owner_reply_preferences p
JOIN owner_reply_preference_sources a ON a.preference_revision=p.revision AND a.target_token=p.target_token
JOIN owner_ai_direct_sources s ON s.source_message_id=a.source_message_id
  AND s.owner_account_id=p.owner_id AND s.ai_profile_id=p.ai_profile_id
WHERE a.source_message_id=? AND p.owner_id=? AND p.ai_profile_id=?
  AND s.ai_account_id=? AND s.conversation_id=? AND s.grant_revision=?''',
    [
      source,
      grant.ownerAccountId,
      grant.aiProfileId,
      grant.aiAccountId,
      grant.conversationId,
      grant.revision,
    ],
  )).singleOrNull;

  Future<_Recipient?> _recipient(Tx tx, OwnerAiDirectGrant grant) async {
    final row = (await tx.query(
      '''
SELECT p.id,p.base_url,b.model,e.epoch FROM model_bindings b
JOIN providers p ON p.owner_id=b.owner_id AND p.id=b.provider_id AND p.enabled=1
JOIN owner_reply_target_epochs e ON e.owner_id=b.owner_id AND e.ai_profile_id=b.ai_profile_id
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
        RegExp(
          r'[\x00-\x1f\x7f-\x9f\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
        ).hasMatch(model)) {
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
    // Only the independent random epoch and canonical grant identity are hashed;
    // never a key, ciphertext, masked key, request body or private URL path.
    final token = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'owner-reply-preferences:v1',
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
    return _Recipient(id, model, raw, uri.origin, token);
  }

  Map<String, Object?> _view(
    int revision,
    bool enabled,
    OwnerReplyChoices choices,
    _Recipient? target,
  ) => {
    'revision': revision,
    'enabled': enabled,
    ...choices.toJson(),
    'target': target?.toJson(),
  };

  Result<OwnerReplyChoices> _decode(
    String owner,
    String ai,
    String? encrypted,
  ) {
    if (encrypted == null) return const Ok(OwnerReplyChoices());
    final decrypted = cipher.decrypt(encrypted, aad: _aad(owner, ai));
    if (decrypted.isOk) {
      try {
        final json = jsonDecode(decrypted.value);
        if (json is Map &&
            json.length == 2 &&
            json.containsKey('length') &&
            json.containsKey('format')) {
          return Ok(OwnerReplyChoices.parse(json['length'], json['format']));
        }
      } on FormatException {
        // Never echo a stored/decrypted payload.
      }
    }
    return err(FailureCode.internal, 'Reply preference storage unavailable');
  }

  String _aad(String owner, String ai) =>
      jsonEncode(['owner-reply-preferences:v1', owner, ai]);
}
