import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import '../storage/cipher.dart';
import '../storage/database.dart';
import 'message_store.dart';

/// 定时消息：入库、到点投递、取消（FR-20、B-4）。
///
/// 到点投递复用 [MessageStore.append]，clientMsgId 固定为 `scheduled:<id>`，
/// 因此重复投递只会写入一次。超过 24 小时未投递的按 B-4 标记 expired、不补发；
/// 本项目尚无通知通道，故仅记录状态。
class ScheduledMessageService {
  ScheduledMessageService({
    required Database database,
    required ColumnCipher cipher,
    required MessageStore store,
    this.clock = const SystemClock(),
    String Function()? newId,
  }) : _database = database,
       _cipher = cipher,
       _store = store,
       _newId = newId ?? _randomId;

  final Database _database;
  final ColumnCipher _cipher;
  final MessageStore _store;
  final Clock clock;
  final String Function() _newId;

  static String _randomId() {
    final random = Random.secure();
    return base64UrlEncode(List.generate(24, (_) => random.nextInt(256)));
  }

  static const _maxDelay = Duration(hours: 24);

  /// 创建未来时间的定时消息；时间必须严格晚于当前注入时钟。
  Future<Result<Map<String, Object?>>> schedule({
    required String conversationId,
    required String senderId,
    required MessageKind kind,
    required Map<String, Object?> body,
    required DateTime deliverAt,
  }) async {
    final now = clock.now().toUtc();
    final at = deliverAt.toUtc();
    if (!at.isAfter(now)) {
      return err(
        FailureCode.invalidArgument,
        'deliverAt must be in the future',
      );
    }
    final String encoded;
    try {
      encoded = jsonEncode(body);
    } on JsonUnsupportedObjectError {
      return err(FailureCode.invalidArgument, 'Body must be a JSON object');
    }
    final id = _newId();
    await _database.execute(
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
  }

  /// 取消自己的待投递定时消息。
  Future<Result<void>> cancel({
    required String conversationId,
    required String scheduledId,
    required String senderId,
  }) => _database.transaction((tx) async {
    final rows = await tx.query(
      'SELECT sender_id, status FROM scheduled_messages WHERE id = ? AND conversation_id = ?',
      [scheduledId, conversationId],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'not found');
    final row = rows.single;
    if (row['sender_id'] != senderId) {
      return err(FailureCode.forbidden, 'only the sender can cancel');
    }
    if (row['status'] != 'pending') {
      return err(FailureCode.invalidArgument, 'not pending');
    }
    await tx.execute(
      "UPDATE scheduled_messages SET status = 'cancelled' WHERE id = ?",
      [scheduledId],
    );
    return const Ok(null);
  });

  /// 投递所有到点消息，返回成功追加的条数；过期的标记 expired。
  Future<int> deliverDue({DateTime? now}) async {
    final current = (now ?? clock.now()).toUtc();
    // Compare parsed DateTimes instead of ISO text: the fractional-second width
    // of toIso8601String is not fixed, so TEXT comparison can misorder values.
    final pending = await _database.query('''
SELECT id, conversation_id, sender_id, kind, body, deliver_at FROM scheduled_messages
WHERE status = 'pending'
ORDER BY rowid
''');
    var delivered = 0;
    for (final row in pending) {
      final id = row['id'] as String;
      final conversationId = row['conversation_id'] as String;
      final senderId = row['sender_id'] as String;
      final kind = MessageKind.tryParse(row['kind'] as String);
      final deliverAt = DateTime.parse(row['deliver_at'] as String).toUtc();
      if (kind == null) continue;
      if (deliverAt.isAfter(current)) continue;
      if (current.difference(deliverAt) > _maxDelay) {
        await _mark(id, 'expired');
        continue;
      }
      final decoded = _cipher.decrypt(
        row['body'] as String,
        aad: 'scheduled_messages:body:$id',
      );
      if (decoded.isErr) continue;
      final body = jsonDecode(decoded.value);
      if (body is! Map<String, dynamic>) continue;
      final appended = await _store.append(
        conversationId: conversationId,
        senderId: senderId,
        clientMsgId: 'scheduled:$id',
        kind: kind,
        body: Map<String, Object?>.unmodifiable(body),
      );
      if (appended.isErr) continue;
      await _mark(id, 'delivered');
      if (!appended.value.duplicate) delivered++;
    }
    return delivered;
  }

  Future<void> _mark(String id, String status) => _database.execute(
    'UPDATE scheduled_messages SET status = ? WHERE id = ?',
    [status, id],
  );
}
