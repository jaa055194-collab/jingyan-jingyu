/// M12 用户离开与删除回执（口径 C-4 / AC-15 / NFR-11）。
///
/// 回执给出对象计数与备份轮转到期日，并沿用诚实口径"轮转后清除"，
/// 不宣称"瞬间不可恢复"。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/lifecycle/departure.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 7, 1, 9);
  late InMemoryDepartureStore store;
  late InMemoryAuditLog audit;
  late DepartureService service;

  setUp(() {
    store = InMemoryDepartureStore();
    audit = InMemoryAuditLog(clock: FakeClock(now));
    service = DepartureService(
      store: store,
      clock: FakeClock(now),
      audit: audit,
    );
    store.seed('u1', {
      'conversations': 2,
      'messages': 12,
      'memories': 6,
      'attachments': 3,
      'vitals': 1,
      'schedules': 4,
      'voiceProfiles': 2,
      'live2dBindings': 1,
      'providerConfigs': 2,
      'usageRecords': 30,
    }, moments: 5);
  });

  group('删除回执', () {
    test('回执含对象计数、匿名化数量与备份轮转到期日', () async {
      final receipt = (await service.depart(
        accountId: 'u1',
        aiDisposition: AiDisposition.transfer,
      )).value;

      expect(receipt.accountId, 'u1');
      expect(receipt.generatedAt, now);
      expect(receipt.objectCounts['conversations'], 2);
      expect(receipt.objectCounts['messages'], 12);
      expect(receipt.totalObjects, 63, reason: '仅统计对象计数之和，不含匿名化动态');
      expect(receipt.momentsAnonymized, 5);
      expect(receipt.aiDisposition, AiDisposition.transfer);
      expect(
        receipt.backupRotationDueAt,
        now.add(const Duration(days: 30)),
      );
    });

    test('诚实口径：只说轮转后清除，不宣称瞬间不可恢复', () async {
      final receipt = (await service.depart(
        accountId: 'u1',
        aiDisposition: AiDisposition.delete,
      )).value;
      expect(receipt.notice.contains('轮转后清除'), isTrue);
      expect(receipt.notice.contains('瞬间'), isFalse);
      expect(receipt.notice.contains('立即清除'), isFalse);
    });

    test('离开后数据已清除，再次离开计数为零', () async {
      await service.depart(accountId: 'u1', aiDisposition: AiDisposition.retain);
      final again = (await service.depart(
        accountId: 'u1',
        aiDisposition: AiDisposition.retain,
      )).value;
      expect(again.totalObjects, 0);
      expect(again.momentsAnonymized, 0);
    });

    test('空账号标识返回 invalidArgument', () async {
      final result = await service.depart(
        accountId: '  ',
        aiDisposition: AiDisposition.retain,
      );
      expect(result.failureOrNull?.code, FailureCode.invalidArgument);
    });

    test('AI 处置方式写入回执与审计，审计不含正文/密钥', () async {
      final receipt = (await service.depart(
        accountId: 'u1',
        aiDisposition: AiDisposition.transfer,
      )).value;
      expect(receipt.aiDisposition, AiDisposition.transfer);
      final entry = audit.entries.single;
      expect(entry.action, 'account.departure');
      expect(entry.meta['aiDisposition'], 'transfer');
      expect(
        AuditEntry.forbiddenKeys.intersection(entry.meta.keys.toSet()),
        isEmpty,
      );
    });

    test('回执 JSON 可序列化且不含正文字段', () async {
      final receipt = (await service.depart(
        accountId: 'u1',
        aiDisposition: AiDisposition.delete,
      )).value;
      final json = receipt.toJson();
      expect(json['accountId'], 'u1');
      expect(json['totalObjects'], 63);
      expect(json.containsKey('body'), isFalse);
      expect(json.containsKey('text'), isFalse);
    });
  });
}
