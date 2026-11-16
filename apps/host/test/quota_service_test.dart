/// M12 quota 接入：把纯 [QuotaPolicy] 与账号用量账本、磁盘状态、并发闸门接在一起。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/quota.dart';
import 'package:jingyu_host/src/lifecycle/quota_service.dart';
import 'package:test/test.dart';

const int gib = 1024 * 1024 * 1024;

void main() {
  late InMemoryQuotaStore store;
  late QuotaService service;

  setUp(() {
    store = InMemoryQuotaStore();
    service = QuotaService(store: store, quotaBytes: 20 * gib);
  });

  group('QuotaService.evaluate 接入用量账本', () {
    test('读取已用字节并触发 80% 告警，账号之间隔离', () async {
      await store.setUsedBytes('a', 16 * gib); // 80% of 20 GiB
      await store.addUsage('b', 1);
      final a = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.file,
        uploadBytes: 1 * gib,
      );
      expect(a.isOk, isTrue);
      expect(a.value.quotaWarning, isTrue);
      final b = await service.evaluate(
        accountId: 'b',
        kind: UploadKind.file,
        uploadBytes: 1 * gib,
      );
      expect(b.value.quotaWarning, isFalse);
    });

    test('100% 时只停 >50 MiB 的大文件，文字/小图/语音仍可发', () async {
      await store.setUsedBytes('a', 20 * gib);
      final big = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.file,
        uploadBytes: 50 * 1024 * 1024 + 1,
      );
      expect(big.failureOrNull?.code, FailureCode.budgetExhausted);
      expect(big.failureOrNull?.details['reason'], 'quota');

      final small = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.file,
        uploadBytes: 50 * 1024 * 1024,
      );
      expect(small.isOk, isTrue);

      for (final kind in [UploadKind.text, UploadKind.image, UploadKind.voice]) {
        final r = await service.evaluate(
          accountId: 'a',
          kind: kind,
          uploadBytes: 999 * 1024 * 1024,
        );
        expect(r.isOk, isTrue, reason: kind.name);
      }
    });

    test('磁盘剩余 <10% 时停全部新上传，优先于配额判断', () async {
      await store.setDiskSpace(freeBytes: 9, totalBytes: 100);
      await store.setUsedBytes('a', 20 * gib);
      final r = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.text,
        uploadBytes: 1,
      );
      expect(r.failureOrNull?.code, FailureCode.budgetExhausted);
      expect(r.failureOrNull?.details['reason'], 'disk');
    });

    test('空账号或负数上传字节返回 invalidArgument', () async {
      final empty = await service.evaluate(
        accountId: '  ',
        kind: UploadKind.file,
        uploadBytes: 1,
      );
      expect(empty.failureOrNull?.code, FailureCode.invalidArgument);
      final negative = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.file,
        uploadBytes: -1,
      );
      expect(negative.failureOrNull?.code, FailureCode.invalidArgument);
    });
  });

  group('QuotaService.commit 记账', () {
    test('只对计入配额的类别累加字节', () async {
      final fileDecision = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.file,
        uploadBytes: 123,
      );
      await service.commit(accountId: 'a', decision: fileDecision.value);
      expect(await store.usedBytes('a'), 123);

      final textDecision = await service.evaluate(
        accountId: 'a',
        kind: UploadKind.text,
        uploadBytes: 999,
      );
      await service.commit(accountId: 'a', decision: textDecision.value);
      expect(await store.usedBytes('a'), 123, reason: '文字不计入配额');
    });
  });

  group('QuotaService 并发上传闸门', () {
    test('同一账号最多 3 个并发上传，跨账号独立', () async {
      final p1 = service.acquireUploadSlot('a');
      final p2 = service.acquireUploadSlot('a');
      final p3 = service.acquireUploadSlot('a');
      expect(p1.isOk && p2.isOk && p3.isOk, isTrue);
      expect(
        service.acquireUploadSlot('a').failureOrNull?.code,
        FailureCode.rateLimited,
      );
      expect(service.acquireUploadSlot('b').isOk, isTrue);
      expect(service.releaseUploadSlot(p1.value).isOk, isTrue);
      expect(service.acquireUploadSlot('a').isOk, isTrue);
    });
  });
}
