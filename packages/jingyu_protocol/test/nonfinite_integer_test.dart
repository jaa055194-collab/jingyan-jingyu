import 'dart:convert';

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void main() {
  String envelope(String type, String payload) =>
      '{"v":1,"id":"x","at":"2026-11-13T05:00:00Z","type":"$type","payload":$payload}';
  test(
    'valid JSON numeric exponent overflow returns Err instead of throwing',
    () {
      final raw = envelope(
        'message.ack',
        '{"conversationId":"c1","seq":1e999}',
      );
      expect((jsonDecode(raw) as Map)['payload']['seq'], double.infinity);
      expect(decodeFrame(raw).failureOrNull?.code, FailureCode.invalidArgument);
    },
  );
  for (final number in ['1e999', '-1e999']) {
    for (final fixture in [
      (
        type: 'hello',
        payload: '{"deviceId":"d1","accountId":"a1","lastSeq":{"c1":$number}}',
      ),
      (
        type: 'message.event',
        payload:
            '{"conversationId":"c1","seq":$number,"messageId":"m1","senderId":"a1","kind":"text","body":{},"sentAt":"2026-11-13T05:00:00Z"}',
      ),
      (type: 'message.ack', payload: '{"conversationId":"c1","seq":$number}'),
      (
        type: 'sync.request',
        payload: '{"conversationId":"c1","afterSeq":$number}',
      ),
      (
        type: 'sync.request',
        payload: '{"conversationId":"c1","afterSeq":0,"limit":$number}',
      ),
    ]) {
      test(
        '${fixture.type} integer field rejects $number through raw and map APIs',
        () {
          final raw = envelope(fixture.type, fixture.payload);
          expect(
            decodeFrame(raw).failureOrNull?.code,
            FailureCode.invalidArgument,
          );
          final map = (jsonDecode(raw) as Map).cast<String, Object?>();
          expect(
            decodeFrameMap(map).failureOrNull?.code,
            FailureCode.invalidArgument,
          );
        },
      );
    }
  }
  test(
    'finite integral doubles retain existing decoding and fractions stay invalid',
    () {
      final frame =
          decodeFrame(
                envelope('message.ack', '{"conversationId":"c1","seq":2.0}'),
              ).value
              as AckFrame;
      expect(frame.seq, 2);
      final request =
          decodeFrame(
                envelope(
                  'sync.request',
                  '{"conversationId":"c1","afterSeq":3.0,"limit":2.0}',
                ),
              ).value
              as SyncRequestFrame;
      expect(request.afterSeq, 3);
      expect(request.limit, 2);
      expect(
        decodeFrame(
          envelope('message.ack', '{"conversationId":"c1","seq":2.5}'),
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    },
  );
  test('direct map NaN or infinities use safe invalidArgument result', () {
    for (final value in [
      double.nan,
      double.infinity,
      double.negativeInfinity,
    ]) {
      final map = <String, Object?>{
        'v': 1,
        'id': 'x',
        'at': '2026-11-13T05:00:00Z',
        'type': 'message.ack',
        'payload': <String, Object?>{'conversationId': 'c1', 'seq': value},
      };
      expect(
        decodeFrameMap(map).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    }
  });
}
