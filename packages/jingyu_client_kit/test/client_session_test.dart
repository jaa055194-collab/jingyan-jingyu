import 'package:jingyu_client_kit/jingyu_client_kit.dart';
import 'package:jingyu_core/jingyu_core.dart';
import 'package:test/test.dart';

CachedMessage _msg(
  String conversationId,
  int seq, {
  String? id,
  String sender = 'acct-b',
  String text = 'hi',
  String kind = 'text',
}) =>
    CachedMessage(
      messageId: id ?? 'm$conversationId$seq',
      conversationId: conversationId,
      seq: seq,
      senderId: sender,
      kind: kind,
      body: {'text': text},
      sentAt: DateTime.utc(2026, 11, 15, 0, 0, seq % 60),
    );

ClientSession _session({
  String account = 'acct-a',
  Outbox? outbox,
  LocalMessageCache? cache,
}) =>
    ClientSession(accountId: account, outbox: outbox, cache: cache);

void main() {
  group('ClientSession.ingest', () {
    test('按 seq 顺序应用并写入缓存', () {
      final s = _session();
      final r = s.ingest([_msg('c1', 1), _msg('c1', 2)]);
      expect(r.applied, 2);
      expect(r.duplicates, 0);
      expect(r.needsSync, isFalse);
      expect(s.messages('c1').map((m) => m.seq), [1, 2]);
      expect(s.headSeq('c1'), 2);
    });

    test('重复下发被忽略', () {
      final s = _session();
      s.ingest([_msg('c1', 1)]);
      final r = s.ingest([_msg('c1', 1)]);
      expect(r.applied, 0);
      expect(r.duplicates, 1);
      expect(s.messages('c1').length, 1);
    });

    test('缺口被报告且不写入乱序消息，补齐后按序应用', () {
      final s = _session();
      final r = s.ingest([_msg('c1', 2)]);
      expect(r.applied, 0);
      expect(r.needsSync, isTrue);
      expect(r.gaps.single.conversationId, 'c1');
      expect(r.gaps.single.afterSeq, 0);
      expect(s.messages('c1'), isEmpty);
      final r2 = s.ingest([_msg('c1', 1), _msg('c1', 2)]);
      expect(r2.applied, 2);
      expect(s.messages('c1').map((m) => m.seq), [1, 2]);
    });

    test('一个会话的缺口不影响其它会话', () {
      final s = _session();
      final r = s.ingest([_msg('c1', 2), _msg('c2', 1)]);
      expect(r.gaps.single.conversationId, 'c1');
      expect(s.messages('c2').map((m) => m.seq), [1]);
    });

    test('重启后（复用同一缓存）把重放当重复而非新消息', () {
      final cache = LocalMessageCache();
      final s1 = _session(cache: cache);
      s1.ingest([_msg('c1', 1)]);
      final s2 = _session(cache: cache);
      final r = s2.ingest([_msg('c1', 1)]);
      expect(r.duplicates, 1);
      expect(r.applied, 0);
    });
  });

  group('ClientSession 发件箱', () {
    test('sendText 入队并可 flush 提交', () async {
      final s = _session(outbox: Outbox(newClientMsgId: () => 'id1'));
      final id = s.sendText('c1', 'hello');
      expect(id, 'id1');
      expect(s.outbox.items.single.conversationId, 'c1');
      expect(s.outbox.items.single.body['text'], 'hello');
      final report = await s.flush((item) async => const Ok<void>(null));
      expect(report.sent, 1);
      expect(report.remaining, 0);
    });

    test('瞬时失败保留队首', () async {
      final s = _session();
      s.sendText('c1', 'x');
      final report = await s.flush(
          (item) async => err<void>(FailureCode.unavailable, 'offline'));
      expect(report.sent, 0);
      expect(report.remaining, 1);
      expect(s.outbox.items.single.attempts, 1);
    });
  });

  test('applyRecall 置撤回占位', () {
    final s = _session();
    s.ingest([_msg('c1', 1, id: 'm1')]);
    s.applyRecall('c1', 'm1');
    expect(s.messages('c1').single.recalled, isTrue);
  });

  test('clearAccount 清空缓存', () {
    final s = _session();
    s.ingest([_msg('c1', 1)]);
    s.clearAccount();
    expect(s.messages('c1'), isEmpty);
  });
}
