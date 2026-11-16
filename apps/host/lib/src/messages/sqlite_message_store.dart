import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'message_store.dart';

/// Persistent message kernel. The caller owns database/cipher lifetimes.
///
/// MessageStore has no Principal argument: authorization and conversation
/// membership checks belong to the MembershipCheck/service boundary. This
/// repository deliberately provides no user isolation or permission decisions.
class SqliteMessageStore implements MessageStore {
  SqliteMessageStore({
    required Database database,
    required ColumnCipher cipher,
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _database = database,
       _cipher = cipher,
       _newId = newId ?? _randomId;

  final Database _database;
  final ColumnCipher _cipher;
  final Clock clock;
  final String Function() _newId;

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  @override
  Future<Result<AppendResult>> append({
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required MessageKind kind,
    required Map<String, Object?> body,
  }) async {
    if (clientMsgId.isEmpty || clientMsgId.length > 64) {
      return err(
        FailureCode.invalidArgument,
        'clientMsgId length must be 1–64',
      );
    }
    // A failed transaction (including commit) must escape: returning an error
    // inside the callback would commit any preceding sequence allocation.
    return _database.transaction(
      (tx) => appendInTransaction(
        tx,
        conversationId: conversationId,
        senderId: senderId,
        clientMsgId: clientMsgId,
        kind: kind,
        body: body,
      ),
    );
  }

  /// Appends using an active caller-owned transaction, without opening another
  /// transaction or making outer Database calls. Authorization remains the
  /// caller's responsibility; this helper makes no permission decisions.
  ///
  /// The result is provisional until the caller commits. An Err does not roll
  /// back earlier caller writes: throw from the transaction callback when those
  /// writes must also be reverted. Storage/cipher exceptions propagate and must
  /// not be swallowed if the caller requires the entire transaction to roll back.
  Future<Result<AppendResult>> appendInTransaction(
    Tx tx, {
    required String conversationId,
    required String senderId,
    required String clientMsgId,
    required MessageKind kind,
    required Map<String, Object?> body,
  }) async {
    if (clientMsgId.isEmpty || clientMsgId.length > 64) {
      return err(
        FailureCode.invalidArgument,
        'clientMsgId length must be 1–64',
      );
    }
    final existing = await tx.query(
      '''
SELECT * FROM messages
WHERE conversation_id = ? AND sender_id = ? AND client_msg_id = ?
''',
      [conversationId, senderId, clientMsgId],
    );
    if (existing.isNotEmpty) {
      return _read(
        existing.single,
      ).map((m) => AppendResult(m, duplicate: true));
    }
    final String encoded;
    try {
      encoded = jsonEncode(body);
    } on JsonUnsupportedObjectError {
      return err<AppendResult>(
        FailureCode.invalidArgument,
        'Body must be a JSON object',
      );
    }
    final id = _newId();
    final sealed = _cipher.encrypt(encoded, aad: 'messages:body:$id');
    final seq = await headSeqInTransaction(tx, conversationId) + 1;
    final sentAt = clock.now().toUtc();
    await tx.execute(
      '''
INSERT INTO message_heads(conversation_id, seq) VALUES (?, ?)
ON CONFLICT(conversation_id) DO UPDATE SET seq = excluded.seq
''',
      [conversationId, seq],
    );
    await tx.execute(
      '''
INSERT INTO messages(message_id, conversation_id, seq, sender_id, client_msg_id, kind, body, sent_at)
VALUES (?, ?, ?, ?, ?, ?, ?, ?)
''',
      [
        id,
        conversationId,
        seq,
        senderId,
        clientMsgId,
        kind.wire,
        sealed,
        sentAt.toIso8601String(),
      ],
    );
    // Decode the serialized snapshot, so later mutations of nested caller
    // maps cannot change the returned message relative to persistent data.
    return Ok(
      AppendResult(
        StoredMessage(
          conversationId: conversationId,
          seq: seq,
          messageId: id,
          senderId: senderId,
          clientMsgId: clientMsgId,
          kind: kind,
          body: Map<String, Object?>.unmodifiable(
            jsonDecode(encoded) as Map<String, dynamic>,
          ),
          sentAt: sentAt,
        ),
        duplicate: false,
      ),
    );
  }

  Result<StoredMessage> _read(Map<String, Object?> row) {
    final id = row['message_id'] as String;
    final decoded = _cipher.decrypt(
      row['body'] as String,
      aad: 'messages:body:$id',
    );
    if (decoded.isErr) {
      return err(FailureCode.internal, 'Stored message body cannot be decoded');
    }
    try {
      final body = jsonDecode(decoded.value);
      if (body is! Map<String, dynamic>) {
        return err(
          FailureCode.internal,
          'Stored message body is not an object',
        );
      }
      final kind = MessageKind.tryParse(row['kind'] as String);
      if (kind == null) {
        return err(FailureCode.internal, 'Stored message kind is invalid');
      }
      return Ok(
        StoredMessage(
          conversationId: row['conversation_id'] as String,
          seq: row['seq'] as int,
          messageId: id,
          senderId: row['sender_id'] as String,
          clientMsgId: row['client_msg_id'] as String,
          kind: kind,
          body: Map<String, Object?>.unmodifiable(body),
          sentAt: DateTime.parse(row['sent_at'] as String).toUtc(),
        ),
      );
    } on FormatException {
      return err(FailureCode.internal, 'Stored message encoding is invalid');
    }
  }

  @override
  Future<Result<SyncPage>> since({
    required String conversationId,
    required int afterSeq,
    int limit = 200,
  }) async {
    if (afterSeq < 0 || limit <= 0 || limit > 1000) {
      return err(FailureCode.invalidArgument, 'Invalid sequence or page limit');
    }
    final rows = await _database.query(
      '''
SELECT * FROM messages WHERE conversation_id = ? AND seq > ? ORDER BY seq LIMIT ?
''',
      [conversationId, afterSeq, limit + 1],
    );
    final messages = <StoredMessage>[];
    for (final row in rows.take(limit)) {
      final result = _read(row);
      if (result.isErr) return Err(result.failureOrNull!);
      messages.add(result.value);
    }
    return Ok(SyncPage(messages, hasMore: rows.length > limit));
  }

  @override
  Future<int> ack({
    required String conversationId,
    required String deviceId,
    required int seq,
  }) => _database.transaction((tx) async {
    final head = await headSeqInTransaction(tx, conversationId);
    final clamped = seq.clamp(0, head);
    await tx.execute(
      '''
INSERT INTO message_acks(conversation_id, device_id, seq) VALUES (?, ?, ?)
ON CONFLICT(conversation_id, device_id) DO UPDATE SET seq = MAX(message_acks.seq, excluded.seq)
''',
      [conversationId, deviceId, clamped],
    );
    return (await tx.query(
          '''
SELECT seq FROM message_acks WHERE conversation_id = ? AND device_id = ?
''',
          [conversationId, deviceId],
        )).single['seq']
        as int;
  });

  /// Reads the head within a caller-owned membership transaction, so joining
  /// a conversation and establishing its history boundary are atomic.
  Future<int> headSeqInTransaction(Tx tx, String conversationId) async {
    final rows = await tx.query(
      'SELECT seq FROM message_heads WHERE conversation_id = ?',
      [conversationId],
    );
    return rows.isEmpty ? 0 : rows.single['seq'] as int;
  }

  @override
  Future<int> headSeq(String conversationId) =>
      _database.transaction((tx) => headSeqInTransaction(tx, conversationId));

  @override
  Future<Result<void>> recall({
    required String conversationId,
    required String messageId,
    required String senderId,
  }) => _database.transaction((tx) async {
    final rows = await tx.query(
      '''
SELECT sender_id, sent_at, recalled_at FROM messages
WHERE conversation_id = ? AND message_id = ?
''',
      [conversationId, messageId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'message not found');
    final row = rows.single;
    if (row['sender_id'] != senderId) {
      return err(FailureCode.forbidden, 'only the sender can recall');
    }
    if (row['recalled_at'] != null) {
      return err(FailureCode.invalidArgument, 'already recalled');
    }
    final sentAt = DateTime.parse(row['sent_at'] as String).toUtc();
    if (clock.now().toUtc().difference(sentAt) > const Duration(hours: 24)) {
      return err(FailureCode.forbidden, 'recall window expired');
    }
    final sealed = _cipher.encrypt(
      jsonEncode({'recalled': true}),
      aad: 'messages:body:$messageId',
    );
    await tx.execute(
      '''
UPDATE messages SET body = ?, recalled_at = ?
WHERE conversation_id = ? AND message_id = ?
''',
      [
        sealed,
        clock.now().toUtc().toIso8601String(),
        conversationId,
        messageId,
      ],
    );
    return const Ok(null);
  });

  @override
  Future<Result<EditResult>> edit({
    required String conversationId,
    required String messageId,
    required String senderId,
    required Map<String, Object?> body,
  }) => _database.transaction((tx) async {
    final rows = await tx.query(
      'SELECT * FROM messages WHERE conversation_id = ? AND message_id = ?',
      [conversationId, messageId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'message not found');
    final row = rows.single;
    if (row['sender_id'] != senderId) {
      return err(FailureCode.forbidden, 'only the sender can edit');
    }
    if (row['recalled_at'] != null) {
      return err(
        FailureCode.invalidArgument,
        'recalled message cannot be edited',
      );
    }
    final String encoded;
    try {
      encoded = jsonEncode(body);
    } on JsonUnsupportedObjectError {
      return err<EditResult>(
        FailureCode.invalidArgument,
        'Body must be a JSON object',
      );
    }
    final previous = _read(row);
    if (previous.isErr) return Err<EditResult>(previous.failureOrNull!);
    final editId = _newId();
    final editedAt = clock.now().toUtc();
    await tx.execute(
      '''
INSERT INTO message_edits(edit_id, message_id, conversation_id, editor_id, body, edited_at)
VALUES (?, ?, ?, ?, ?, ?)
''',
      [
        editId,
        messageId,
        conversationId,
        senderId,
        _cipher.encrypt(
          jsonEncode(previous.value.body),
          aad: 'message_edits:body:$editId',
        ),
        editedAt.toIso8601String(),
      ],
    );
    await tx.execute(
      'UPDATE messages SET body = ? WHERE conversation_id = ? AND message_id = ?',
      [
        _cipher.encrypt(encoded, aad: 'messages:body:$messageId'),
        conversationId,
        messageId,
      ],
    );
    final updated = StoredMessage(
      conversationId: previous.value.conversationId,
      seq: previous.value.seq,
      messageId: previous.value.messageId,
      senderId: previous.value.senderId,
      clientMsgId: previous.value.clientMsgId,
      kind: previous.value.kind,
      body: Map<String, Object?>.unmodifiable(
        jsonDecode(encoded) as Map<String, dynamic>,
      ),
      sentAt: previous.value.sentAt,
    );
    return Ok(EditResult(updated, editId));
  });

  @override
  Future<Result<List<EditVersion>>> editHistory({
    required String conversationId,
    required String messageId,
  }) async {
    final rows = await _database.query(
      '''
SELECT edit_id, message_id, editor_id, body, edited_at FROM message_edits
WHERE conversation_id = ? AND message_id = ?
ORDER BY rowid
''',
      [conversationId, messageId],
    );
    final versions = <EditVersion>[];
    for (final row in rows) {
      final editId = row['edit_id'] as String;
      final decoded = _cipher.decrypt(
        row['body'] as String,
        aad: 'message_edits:body:$editId',
      );
      if (decoded.isErr) {
        return err(FailureCode.internal, 'Stored edit body cannot be decoded');
      }
      try {
        final body = jsonDecode(decoded.value);
        if (body is! Map<String, dynamic>) {
          return err(FailureCode.internal, 'Stored edit body is not an object');
        }
        versions.add(
          EditVersion(
            editId: editId,
            messageId: row['message_id'] as String,
            editorId: row['editor_id'] as String,
            body: Map<String, Object?>.unmodifiable(body),
            editedAt: DateTime.parse(row['edited_at'] as String).toUtc(),
          ),
        );
      } on FormatException {
        return err(FailureCode.internal, 'Stored edit encoding is invalid');
      }
    }
    return Ok(List<EditVersion>.unmodifiable(versions));
  }
}
