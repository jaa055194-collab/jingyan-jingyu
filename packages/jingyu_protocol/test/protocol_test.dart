import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  final at = DateTime.utc(2026, 11, 13, 5, 0, 0);

  group('编解码', () {
    test('sendMessage 往返一致', () {
      final frame = SendMessageFrame(
        id: 'req-1',
        at: at,
        conversationId: 'c1',
        clientMsgId: 'cmid-1',
        kind: MessageKind.text,
        body: const {'text': '刚浇完花'},
      );

      final decoded = decodeFrame(encodeFrame(frame));
      expect(decoded.isOk, isTrue, reason: '${decoded.failureOrNull}');

      final back = decoded.unwrap() as SendMessageFrame;
      expect(back.conversationId, 'c1');
      expect(back.clientMsgId, 'cmid-1');
      expect(back.kind, MessageKind.text);
      expect(back.body['text'], '刚浇完花');
      expect(back.at, at);
    });

    test('syncChunk 保序', () {
      final frame = SyncChunkFrame(
        id: 'req-2',
        at: at,
        conversationId: 'c1',
        messages: [
          {'seq': 1, 'messageId': 'm1'},
          {'seq': 2, 'messageId': 'm2'},
        ],
        hasMore: false,
      );
      final back = decodeFrame(encodeFrame(frame)).unwrap() as SyncChunkFrame;
      expect(back.messages.map((m) => m['seq']), [1, 2]);
      expect(back.hasMore, isFalse);
    });

    test('非法 JSON 返回 invalidArgument', () {
      final result = decodeFrame('{not json');
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('未知帧类型失败', () {
      final result = decodeFrame(jsonEncode({
        'v': 1,
        'type': 'nope',
        'id': 'x',
        'at': at.toIso8601String(),
        'payload': <String, Object?>{},
      }));
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('协议版本不符失败', () {
      final result = decodeFrame(jsonEncode({
        'v': 99,
        'type': 'ping',
        'id': 'x',
        'at': at.toIso8601String(),
        'payload': <String, Object?>{},
      }));
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('缺字段失败而不是填空', () {
      final result = decodeFrame(jsonEncode({
        'v': 1,
        'type': 'message.send',
        'id': 'x',
        'at': at.toIso8601String(),
        'payload': {'conversationId': 'c1'},
      }));
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('sync.request 的 limit 越界失败', () {
      final result = decodeFrame(jsonEncode({
        'v': 1,
        'type': 'sync.request',
        'id': 'x',
        'at': at.toIso8601String(),
        'payload': {
          'conversationId': 'c1',
          'afterSeq': 0,
          'limit': 5000,
        },
      }));
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });
  });

  group('错误码', () {
    test('失败分类映射到线上错误码', () {
      expect(ErrorCode.fromFailure(FailureCode.forbidden).wire, 'forbidden');
      expect(
          ErrorCode.fromFailure(FailureCode.budgetExhausted).httpStatus, 429);
      expect(ErrorCode.tryParse('not_found'), ErrorCode.notFound);
      expect(ErrorCode.tryParse('made_up'), isNull);
    });

    test('错误帧不含正文', () {
      final frame = errorFrameFrom(
        const Failure(FailureCode.forbidden, '不可见：消息正文细节'),
        id: 'req-9',
        at: at,
      );
      final envelope = jsonEncode(frame.toEnvelope());
      expect(envelope.contains('正文细节'), isFalse);
      expect(frame.code, 'forbidden');
    });
  });
}
