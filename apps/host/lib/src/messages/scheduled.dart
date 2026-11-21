import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'sqlite_message_store.dart';

typedef ScheduledHistoryAccess =
    Future<int?> Function(
      Tx tx,
      String accountId,
      String conversationId, {
      required bool requirePost,
    });

typedef ScheduledAttachmentCheck =
    Future<Result<void>> Function(
      Tx tx, {
      required String ownerAccountId,
      required String attachmentId,
      required String conversationId,
    });

/// 定时消息：入库、到点投递、取消（FR-20、B-4）。
///
/// Delivery revalidates the pending row and current sender access inside the
/// transaction that appends the message and records its terminal state.
class ScheduledMessageService {
  ScheduledMessageService({
    required Database database,
    required ColumnCipher cipher,
    required SqliteMessageStore store,
    required ScheduledHistoryAccess historyAccess,
    ScheduledAttachmentCheck? attachmentCheck,
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _database = database,
       _cipher = cipher,
       _store = store,
       _historyAccess = historyAccess,
       _attachmentCheck = attachmentCheck,
       _newId = newId ?? _randomId;

  final Database _database;
  final ColumnCipher _cipher;
  final SqliteMessageStore _store;
  final ScheduledHistoryAccess _historyAccess;
  final ScheduledAttachmentCheck? _attachmentCheck;
  final Clock clock;
  final String Function() _newId;

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  static const _maxDelay = Duration(hours: 24);
  static const _readLimit = 50;

  Future<Result<Map<String, Object?>>> schedule({
    required String conversationId,
    required String senderId,
    required MessageKind kind,
    required Map<String, Object?> body,
    required DateTime deliverAt,
    ScheduledAttachmentCheck? attachmentCheck,
  }) async {
    final at = deliverAt.toUtc();
    final String encoded;
    try {
      encoded = jsonEncode(body);
    } on JsonUnsupportedObjectError {
      return err(FailureCode.invalidArgument, 'Body must be a JSON object');
    }
    final id = _newId();
    return _database.transaction((tx) async {
      final now = clock.now().toUtc();
      if (!at.isAfter(now)) {
        return err(
          FailureCode.invalidArgument,
          'deliverAt must be in the future',
        );
      }
      if (await _historyAccess(
            tx,
            senderId,
            conversationId,
            requirePost: true,
          ) ==
          null) {
        return _notFound();
      }
      final attachmentId = body['attachmentId'];
      if (attachmentId != null) {
        if (attachmentId is! String) {
          return err(FailureCode.invalidArgument, 'invalid attachmentId');
        }
        final check = attachmentCheck ?? _attachmentCheck;
        if (check == null) {
          return err(FailureCode.internal, 'attachments unavailable');
        }
        final sendable = await check(
          tx,
          ownerAccountId: senderId,
          attachmentId: attachmentId,
          conversationId: conversationId,
        );
        if (sendable.isErr) return Err(sendable.failureOrNull!);
      }
      await tx.execute(
        '''
INSERT INTO scheduled_messages(id, conversation_id, sender_id, kind, body, deliver_at, status, created_at)
VALUES (?, ?, ?, ?, ?, ?, 'pending', ?)
''',
        [
          id,
          conversationId,
          senderId,
          kind.wire,
          _cipher.encrypt(encoded, aad: 'scheduled_messages:body:$id'),
          at.toIso8601String(),
          now.toIso8601String(),
        ],
      );
      return Ok({
        'id': id,
        'conversationId': conversationId,
        'deliverAt': at.toIso8601String(),
        'status': 'pending',
      });
    });
  }

  /// Sender-only bounded metadata readback. No body or other owner's rows.
  /// Status stays recoverable after the sender leaves or loses posting access.
  Future<Result<Map<String, Object?>>> readOwn({
    required String conversationId,
    required String senderId,
    String? scheduledId,
  }) => _database.transaction((tx) async {
    if (scheduledId != null) {
      final rows = await tx.query(
        '''SELECT id,conversation_id,deliver_at,status FROM scheduled_messages
WHERE id=? AND conversation_id=? AND sender_id=?''',
        [scheduledId, conversationId, senderId],
      );
      if (rows.isEmpty) return _notFound();
      return Ok({
        'scheduledMessages': [_view(rows.single)],
        'hasMore': false,
      });
    }
    final rows = await tx.query(
      '''SELECT id,conversation_id,deliver_at,status FROM scheduled_messages
WHERE conversation_id=? AND sender_id=? ORDER BY rowid DESC LIMIT ?''',
      [conversationId, senderId, _readLimit + 1],
    );
    return Ok({
      'scheduledMessages': [
        for (final row in rows.take(_readLimit)) _view(row),
      ],
      'hasMore': rows.length > _readLimit,
    });
  });

  Map<String, Object?> _view(Map<String, Object?> row) => {
    'id': row['id'],
    'conversationId': row['conversation_id'],
    'deliverAt': row['deliver_at'],
    'status': row['status'],
  };

  Future<Result<void>> cancel({
    required String conversationId,
    required String scheduledId,
    required String senderId,
  }) => _database.transaction((tx) async {
    final rows = await tx.query(
      'SELECT sender_id,status FROM scheduled_messages WHERE id=? AND conversation_id=?',
      [scheduledId, conversationId],
    );
    if (rows.isEmpty) return _notFoundResult<void>();
    if (rows.single['sender_id'] != senderId) {
      return err(FailureCode.forbidden, 'only the sender can cancel');
    }
    if (rows.single['status'] != 'pending') {
      return err(FailureCode.invalidArgument, 'not pending');
    }
    final changed = await tx.execute(
      "UPDATE scheduled_messages SET status='cancelled' WHERE id=? AND conversation_id=? AND sender_id=? AND status='pending'",
      [scheduledId, conversationId, senderId],
    );
    if (changed != 1) return _notFoundResult<void>();
    return const Ok(null);
  });

  Future<int> deliverDue({DateTime? now}) async {
    final current = now?.toUtc() ?? clock.now().toUtc();
    final candidates = await _database.query('''
SELECT id,deliver_at FROM scheduled_messages WHERE status='pending' ORDER BY rowid
''');
    var delivered = 0;
    for (final candidate in candidates) {
      final id = candidate['id'] as String;
      final dueAt = DateTime.tryParse(
        candidate['deliver_at'] as String,
      )?.toUtc();
      if (dueAt != null && dueAt.isAfter(current)) continue;
      try {
        final appended = await _database.transaction((tx) async {
          final freshRows = await tx.query(
            '''SELECT id,conversation_id,sender_id,kind,body,deliver_at,status
FROM scheduled_messages WHERE id=?''',
            [id],
          );
          if (freshRows.isEmpty || freshRows.single['status'] != 'pending') {
            return false;
          }
          final row = freshRows.single;
          final due = DateTime.tryParse(row['deliver_at'] as String)?.toUtc();
          final dispatchNow = now?.toUtc() ?? clock.now().toUtc();
          if (due == null) {
            await _terminalize(tx, id, 'cancelled');
            return false;
          }
          if (due.isAfter(dispatchNow)) return false;
          if (dispatchNow.difference(due) > _maxDelay) {
            await _terminalize(tx, id, 'expired');
            return false;
          }
          if (await _historyAccess(
                tx,
                row['sender_id'] as String,
                row['conversation_id'] as String,
                requirePost: true,
              ) ==
              null) {
            // The existing status vocabulary has no rejected state. A denied
            // due slot is terminal and cannot revive after membership returns.
            await _terminalize(tx, id, 'cancelled');
            return false;
          }
          final kind = MessageKind.tryParse(row['kind'] as String);
          final body = _decode(row);
          final attachmentId = body?['attachmentId'];
          final attachment = _attachmentCheck;
          final attachmentAllowed = attachmentId == null
              ? true
              : attachmentId is String &&
                    attachment != null &&
                    (await attachment(
                      tx,
                      ownerAccountId: row['sender_id'] as String,
                      attachmentId: attachmentId,
                      conversationId: row['conversation_id'] as String,
                    )).isOk;
          if (kind == null || body == null || !attachmentAllowed) {
            await _terminalize(tx, id, 'cancelled');
            return false;
          }
          final result = await _store.appendInTransaction(
            tx,
            conversationId: row['conversation_id'] as String,
            senderId: row['sender_id'] as String,
            clientMsgId: 'scheduled:$id',
            kind: kind,
            body: Map<String, Object?>.unmodifiable(body),
          );
          if (result.isErr) {
            if (result.failureOrNull!.code == FailureCode.invalidArgument) {
              await _terminalize(tx, id, 'cancelled');
              return false;
            }
            throw _ScheduledAppendFailure();
          }
          await _terminalize(tx, id, 'delivered');
          return !result.value.duplicate;
        });
        if (appended) delivered++;
      } on Object {
        // Transient failures roll back append and status together; the existing
        // timer may retry only while the job remains pending and authorized.
      }
    }
    return delivered;
  }

  Future<void> _terminalize(Tx tx, String id, String status) async {
    final changed = await tx.execute(
      "UPDATE scheduled_messages SET status=? WHERE id=? AND status='pending'",
      [status, id],
    );
    if (changed != 1) throw _ScheduledAppendFailure();
  }

  Map<String, Object?>? _decode(Map<String, Object?> row) {
    try {
      final decoded = _cipher.decrypt(
        row['body'] as String,
        aad: 'scheduled_messages:body:${row['id']}',
      );
      if (decoded.isErr) return null;
      final body = jsonDecode(decoded.value);
      if (body is! Map<String, dynamic>) return null;
      return body.cast<String, Object?>();
    } on Object {
      return null;
    }
  }

  Result<Map<String, Object?>> _notFound() =>
      err(FailureCode.notFound, 'Not found');

  Result<T> _notFoundResult<T>() => err(FailureCode.notFound, 'Not found');
}

final class _ScheduledAppendFailure implements Exception {
  const _ScheduledAppendFailure();
}
