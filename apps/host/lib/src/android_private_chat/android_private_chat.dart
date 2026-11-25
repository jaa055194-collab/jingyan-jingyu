import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:jingyu_core/jingyu_core.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';

typedef PrivateChatClaim = ({
  String owner,
  String device,
  String bearer,
  AiId profile,
});

typedef _Texts = ({String user, String assistant});

/// SQLite transcript storage. Both roles are text in one owner's exchange;
/// neither becomes a message authored by a host account. Authorization,
/// duplicate lookup and append/read all use the supplied transaction.
final class AndroidPrivateChat {
  AndroidPrivateChat(this._database, this._cipher, this._clock);

  final Database _database;
  final ColumnCipher _cipher;
  final Clock _clock;

  static const maxUserBytes = 4096;
  static const maxAssistantBytes = 8192;
  static const pageSize = 16;
  static const _invalid = Failure(
    FailureCode.invalidArgument,
    'Invalid private transcript input',
  );
  static const _unreadable = Failure(
    FailureCode.internal,
    'Private transcript unavailable',
  );

  Future<Result<Map<String, Object?>>> list(
    PrivateChatClaim claim,
    int after,
  ) => _database.transaction((tx) async {
    final failure = await _authorize(tx, claim);
    if (failure != null) return Err(failure);
    if (after < 0) return const Err(_invalid);
    final rows = await tx.query(
      '''
SELECT seq,exchange_id,encrypted_payload FROM android_private_chat_exchanges
WHERE owner_id=? AND ai_profile_id=? AND seq>?
ORDER BY seq LIMIT ?''',
      [claim.owner, claim.profile.value, after, pageSize + 1],
    );
    final items = <Map<String, Object?>>[];
    for (final row in rows.take(pageSize)) {
      final seq = row['seq'] as int;
      final id = row['exchange_id'] as String;
      final texts = _open(claim, seq, id, row['encrypted_payload']);
      if (texts == null) return const Err(_unreadable);
      items.add({
        'seq': seq,
        'exchangeId': id,
        'user': texts.user,
        'assistant': texts.assistant,
      });
    }
    return Ok({'items': items, 'hasMore': rows.length > pageSize});
  });

  Future<Result<int>> push(
    PrivateChatClaim claim, {
    required String exchangeId,
    required String user,
    required String assistant,
  }) => _database.transaction((tx) async {
    final failure = await _authorize(tx, claim);
    if (failure != null) return Err(failure);
    try {
      validateId(exchangeId, kind: 'exchange');
    } on FormatException {
      return const Err(_invalid);
    }
    if (!_text(user, maxUserBytes) || !_text(assistant, maxAssistantBytes)) {
      return const Err(_invalid);
    }
    final owner = claim.owner;
    final profile = claim.profile.value;
    final existing = (await tx.query(
      '''
SELECT seq,encrypted_payload FROM android_private_chat_exchanges
WHERE owner_id=? AND ai_profile_id=? AND exchange_id=?''',
      [owner, profile, exchangeId],
    )).singleOrNull;
    if (existing != null) {
      final seq = existing['seq'] as int;
      final texts = _open(
        claim,
        seq,
        exchangeId,
        existing['encrypted_payload'],
      );
      if (texts == null) return const Err(_unreadable);
      return texts.user == user && texts.assistant == assistant
          ? Ok(seq)
          : err(FailureCode.conflict, 'Private transcript exchange changed');
    }

    // SQLite uses BEGIN IMMEDIATE; allocating and appending cannot race with
    // another writer. The leading columns of the primary key bound this read.
    final head =
        (await tx.query(
              '''
SELECT seq FROM android_private_chat_exchanges
WHERE owner_id=? AND ai_profile_id=? ORDER BY seq DESC LIMIT 1''',
              [owner, profile],
            )).singleOrNull?['seq']
            as int? ??
        0;
    if (head == 0x7fffffffffffffff) return const Err(_unreadable);
    final seq = head + 1;
    final sealed = _cipher.encrypt(
      jsonEncode({'user': user, 'assistant': assistant}),
      aad: _aad(claim, seq, exchangeId),
    );
    await tx.execute(
      '''
INSERT INTO android_private_chat_exchanges
  (owner_id,ai_profile_id,seq,exchange_id,encrypted_payload,created_at)
VALUES(?,?,?,?,?,?)''',
      [
        owner,
        profile,
        seq,
        exchangeId,
        sealed,
        _clock.now().millisecondsSinceEpoch,
      ],
    );
    return Ok(seq);
  });

  Future<Failure?> _authorize(Tx tx, PrivateChatClaim claim) async {
    // Pipeline authentication is a snapshot. Recheck the digest, owner, device
    // and expiry together. Match the SQLite accounts store's requirement of a
    // refresh row, not refresh expiry. Do not enter another service/transaction.
    final live =
        claim.bearer.length == 22 &&
        (await tx.query(
          '''
SELECT 1 FROM device d
JOIN refresh_token r ON r.device_id=d.id
JOIN account h ON h.id=d.account_id AND h.kind='human' AND h.disabled=0
WHERE d.id=? AND d.account_id=? AND d.access_hash=? AND d.access_expires>?''',
          [
            claim.device,
            claim.owner,
            sha256.convert(utf8.encode(claim.bearer)).toString(),
            _clock.now().millisecondsSinceEpoch,
          ],
        )).isNotEmpty;
    if (!live) {
      return const Failure(FailureCode.unauthenticated, 'Invalid credentials');
    }
    final canonical = await tx.query(
      '''
SELECT 1 FROM ai_profile p
JOIN account a ON a.id=p.account_id AND a.kind='ai' AND a.disabled=0
JOIN ai_operator o ON o.ai_id=a.id
WHERE p.id=? AND o.operator_id=?''',
      [claim.profile.value, claim.owner],
    );
    return canonical.isNotEmpty
        ? null
        : const Failure(FailureCode.notFound, 'Private transcript not found');
  }

  static String _aad(PrivateChatClaim claim, int seq, String id) =>
      'android_private_chat_exchanges:encrypted_payload:'
      '${claim.owner}:${claim.profile.value}:$seq:$id';

  _Texts? _open(PrivateChatClaim claim, int seq, String id, Object? sealed) {
    if (sealed is! String) return null;
    final plain = _cipher
        .decrypt(sealed, aad: _aad(claim, seq, id))
        .valueOrNull;
    if (plain == null) return null;
    try {
      final value = jsonDecode(plain);
      if (value is! Map<String, Object?> || value.length != 2) return null;
      final user = value['user'], assistant = value['assistant'];
      if (user is! String ||
          assistant is! String ||
          !_text(user, maxUserBytes) ||
          !_text(assistant, maxAssistantBytes)) {
        return null;
      }
      return (user: user, assistant: assistant);
    } on FormatException {
      // A parser exception may contain its input. Never forward it to a sink.
      return null;
    }
  }
}

bool _text(String text, int maxBytes) =>
    text.length <= maxBytes &&
    text.trim().isNotEmpty &&
    // UTF-8 encoding would otherwise replace unpaired UTF-16 surrogates.
    !text.runes.any((rune) => rune >= 0xd800 && rune <= 0xdfff) &&
    utf8.encode(text).length <= maxBytes;
