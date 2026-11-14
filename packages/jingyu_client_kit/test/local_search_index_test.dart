import 'dart:convert';

import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:test/test.dart';

DateTime _at(int second) => DateTime.utc(2026, 1, 1, 0, 0, second);

void _add(
  LocalSearchIndex index,
  String accountId,
  String conversationId,
  String messageId,
  int seq,
  String text, {
  String senderId = 'u1',
  String kind = 'text',
}) {
  index.applyMessage(
    accountId,
    conversationId: conversationId,
    messageId: messageId,
    seq: seq,
    senderId: senderId,
    kind: kind,
    text: text,
    sentAt: _at(seq),
  );
}

void main() {
  group('LocalSearchIndex.tokenize', () {
    test('CJK 连续串生成单字与相邻二元组', () {
      expect(LocalSearchIndex.tokenize('你好'), {'你', '好', '你好'});
      expect(
        LocalSearchIndex.tokenize('你好世'),
        {'你', '好', '世', '你好', '好世'},
      );
    });

    test('单个 CJK 字符也入 token', () {
      expect(LocalSearchIndex.tokenize('好'), {'好'});
    });

    test('Latin/数字整词入 token，单字符忽略', () {
      expect(LocalSearchIndex.tokenize('Hello World 42'), {'hello', 'world', '42'});
      expect(LocalSearchIndex.tokenize('a b'), isEmpty);
    });

    test('大小写归一', () {
      expect(LocalSearchIndex.tokenize('ABC'), {'abc'});
    });
  });

  group('LocalSearchIndex 索引与检索', () {
    late LocalSearchIndex index;
    setUp(() => index = LocalSearchIndex());

    test('新增后可检索，命中携带完整轻量字段', () {
      _add(index, 'a', 'c1', 'm1', 1, '今天天气很好');
      final hits = index.search('a', '天气');
      expect(hits.map((h) => h.messageId), ['m1']);
      final hit = hits.single;
      expect(hit.conversationId, 'c1');
      expect(hit.seq, 1);
      expect(hit.senderId, 'u1');
      expect(hit.kind, 'text');
      expect(hit.text, '今天天气很好');
      expect(hit.sentAt, _at(1));
    });

    test('编辑替换旧文本：旧词不再命中，新词命中，公共词仍在', () {
      _add(index, 'a', 'c1', 'm1', 1, 'hello apple');
      expect(index.search('a', 'apple').map((h) => h.messageId), ['m1']);

      _add(index, 'a', 'c1', 'm1', 1, 'hello banana');

      expect(index.search('a', 'apple'), isEmpty);
      expect(index.search('a', 'banana').map((h) => h.messageId), ['m1']);
      expect(index.search('a', 'hello').map((h) => h.messageId), ['m1']);
    });

    test('删除后不再命中，重复删除安全', () {
      _add(index, 'a', 'c1', 'm1', 1, 'secret value');
      expect(index.search('a', 'secret').map((h) => h.messageId), ['m1']);

      index.removeMessage('a', 'm1');
      expect(index.search('a', 'secret'), isEmpty);

      expect(() => index.removeMessage('a', 'm1'), returnsNormally);
    });

    test('账号隔离：A 看不到 B 的消息', () {
      _add(index, 'A', 'c1', 'a1', 1, 'shared wordonly');
      _add(index, 'B', 'c1', 'b1', 1, 'shared wordonly');

      expect(index.search('A', 'shared').map((h) => h.messageId), ['a1']);
      expect(index.search('B', 'shared').map((h) => h.messageId), ['b1']);
    });

    test('按会话过滤', () {
      _add(index, 'a', 'c1', 'm1', 1, 'alpha');
      _add(index, 'a', 'c2', 'm2', 2, 'alpha');

      expect(index.search('a', 'alpha').map((h) => h.messageId), ['m1', 'm2']);
      expect(
        index.search('a', 'alpha', conversationId: 'c2').map((h) => h.messageId),
        ['m2'],
      );
    });

    test('limit 生效且按 seq 升序', () {
      for (var i = 1; i <= 5; i++) {
        _add(index, 'a', 'c1', 'm$i', i, 'tag common');
      }
      final hits = index.search('a', 'tag', limit: 2);
      expect(hits.map((h) => h.messageId), ['m1', 'm2']);
    });

    test('单个 CJK 字符查询可命中', () {
      _add(index, 'a', 'c1', 'm1', 1, '中文内容');
      expect(index.search('a', '中').map((h) => h.messageId), ['m1']);
    });

    test('单 Latin 子串查询经 contains 复核命中', () {
      _add(index, 'a', 'c1', 'm1', 1, 'abc');
      expect(index.search('a', 'bc').map((h) => h.messageId), ['m1']);
    });

    test('clearAccount 清空该账号，不影响其它账号', () {
      _add(index, 'a', 'c1', 'a1', 1, 'alpha');
      _add(index, 'b', 'c1', 'b1', 1, 'alpha');

      index.clearAccount('a');
      expect(index.search('a', 'alpha'), isEmpty);
      expect(index.search('b', 'alpha').map((h) => h.messageId), ['b1']);
    });

    test('export/import 往返保留检索结果', () {
      _add(index, 'a', 'c1', 'm1', 1, '导出搜索');
      _add(index, 'a', 'c2', 'm2', 2, 'second token');

      final snapshot = index.exportAccount('a');
      expect(() => jsonEncode(snapshot), returnsNormally);

      final restored = LocalSearchIndex();
      restored.importAccount('a', snapshot);

      expect(restored.search('a', '导出').map((h) => h.messageId), ['m1']);
      expect(restored.search('a', 'second').map((h) => h.messageId), ['m2']);
      expect(
        restored.search('a', 'second').single.sentAt,
        _at(2),
      );
    });

    test('空/空白 query 返回空', () {
      _add(index, 'a', 'c1', 'm1', 1, 'anything');
      expect(index.search('a', ''), isEmpty);
      expect(index.search('a', '   '), isEmpty);
    });
  });
}
