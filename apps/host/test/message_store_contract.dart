/// MessageStore 契约测试。任何实现（内存、SQLite）都必须通过。
///
/// 用法：在实现的测试文件里调用 `messageStoreContract('名字', () => 实现())`。
library;

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

void messageStoreContract(String label, MessageStore Function() create) {
  group('MessageStore 契约 [$label]', () {
    late MessageStore store;
    setUp(() => store = create());

    Future<AppendResult> send(
      String conv,
      String sender,
      String cmid, [
      String text = 'x',
    ]) async => (await store.append(
      conversationId: conv,
      senderId: sender,
      clientMsgId: cmid,
      kind: MessageKind.text,
      body: {'text': text},
    )).value;

    test('seq 在会话内从 1 单调递增，会话间独立', () async {
      expect((await send('c1', 'u1', 'a')).message.seq, 1);
      expect((await send('c1', 'u2', 'b')).message.seq, 2);
      expect((await send('c2', 'u1', 'c')).message.seq, 1);
      expect(await store.headSeq('c1'), 2);
    });

    test('同一发送者重复 clientMsgId 不重复写入', () async {
      final first = await send('c1', 'u1', 'dup', '第一次');
      final again = await send('c1', 'u1', 'dup', '第二次');
      expect(again.duplicate, isTrue);
      expect(again.message.messageId, first.message.messageId);
      expect(again.message.body['text'], '第一次');
      expect(await store.headSeq('c1'), 1);
    });

    test('不同发送者可用相同 clientMsgId', () async {
      await send('c1', 'u1', 'same');
      final other = await send('c1', 'u2', 'same');
      expect(other.duplicate, isFalse);
      expect(await store.headSeq('c1'), 2);
    });

    test('差集按 seq 升序分页', () async {
      for (var i = 0; i < 5; i++) {
        await send('c1', 'u1', 'm$i');
      }
      final page = (await store.since(
        conversationId: 'c1',
        afterSeq: 1,
        limit: 2,
      )).value;
      expect(page.messages.map((m) => m.seq), [2, 3]);
      expect(page.hasMore, isTrue);
      final rest = (await store.since(conversationId: 'c1', afterSeq: 3)).value;
      expect(rest.messages.map((m) => m.seq), [4, 5]);
      expect(rest.hasMore, isFalse);
    });

    test('ack 只前进不后退，且不超过会话头', () async {
      await send('c1', 'u1', 'a');
      await send('c1', 'u1', 'b');
      expect(await store.ack(conversationId: 'c1', deviceId: 'd1', seq: 2), 2);
      expect(await store.ack(conversationId: 'c1', deviceId: 'd1', seq: 1), 2);
      expect(await store.ack(conversationId: 'c1', deviceId: 'd1', seq: 99), 2);
      expect(await store.ack(conversationId: 'c1', deviceId: 'd2', seq: 1), 1);
    });

    test('非法参数返回失败', () async {
      final bad = await store.append(
        conversationId: 'c1',
        senderId: 'u1',
        clientMsgId: '',
        kind: MessageKind.text,
        body: const {},
      );
      expect(bad.isErr, isTrue);
      expect(
        (await store.since(conversationId: 'c1', afterSeq: -1)).isErr,
        isTrue,
      );
      expect(
        (await store.since(conversationId: 'c1', afterSeq: 0, limit: 0)).isErr,
        isTrue,
      );
    });

    test('撤回自己的近期消息：正文变占位，他人/未知/重复撤回失败', () async {
      final mine = await send('c1', 'u1', 'r1', '秘密');
      final id = mine.message.messageId;
      final ok = await store.recall(
        conversationId: 'c1',
        messageId: id,
        senderId: 'u1',
      );
      expect(ok.isOk, isTrue);
      final page = (await store.since(conversationId: 'c1', afterSeq: 0)).value;
      expect(page.messages.single.body, {'recalled': true});
      expect(page.messages.single.seq, 1);

      final other = await send('c1', 'u1', 'r2', '仍然可见');
      final otherId = other.message.messageId;
      expect(
        (await store.recall(
          conversationId: 'c1',
          messageId: otherId,
          senderId: 'u2',
        )).isErr,
        isTrue,
      );
      expect(
        (await store.recall(
          conversationId: 'c1',
          messageId: 'missing',
          senderId: 'u1',
        )).isErr,
        isTrue,
      );
      expect(
        (await store.recall(
          conversationId: 'c1',
          messageId: id,
          senderId: 'u1',
        )).isErr,
        isTrue,
      );
      final after = (await store.since(
        conversationId: 'c1',
        afterSeq: 1,
      )).value;
      expect(after.messages.single.body['text'], '仍然可见');
    });

    test('正文恰好是撤回占位的普通消息也能被撤回（两实现一致）', () async {
      final sent = await store.append(
        conversationId: 'c1',
        senderId: 'u1',
        clientMsgId: 'meta-body',
        kind: MessageKind.text,
        body: {'recalled': true},
      );
      final id = sent.value.message.messageId;
      final before = (await store.since(
        conversationId: 'c1',
        afterSeq: 0,
      )).value.messages.singleWhere((m) => m.messageId == id);
      expect(before.body, {'recalled': true});
      expect(
        (await store.recall(
          conversationId: 'c1',
          messageId: id,
          senderId: 'u1',
        )).isOk,
        isTrue,
        reason: '正文内容不能被当作撤回状态',
      );
    });
  });
}
