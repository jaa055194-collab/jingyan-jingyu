/// [QuotaStore] 契约测试。任何实现（内存、SQLite）都必须通过。
///
/// 用法：在实现的测试文件里调用 `quotaStoreContract('名字', () => 实现())`。
library;

import 'package:jingyu_host/src/lifecycle/quota_service.dart';
import 'package:test/test.dart';

void quotaStoreContract(String label, QuotaStore Function() create) {
  group('QuotaStore 契约 [$label]', () {
    late QuotaStore store;
    setUp(() => store = create());

    test('未知账号的已用配额字节为 0', () async {
      expect(await store.usedBytes('unknown'), 0);
    });

    test('addUsage 累加，账号之间互不影响', () async {
      await store.addUsage('a', 10);
      await store.addUsage('a', 5);
      await store.addUsage('b', 7);
      expect(await store.usedBytes('a'), 15);
      expect(await store.usedBytes('b'), 7);
      expect(await store.usedBytes('c'), 0);
    });

    test('setUsedBytes 覆盖既有累计值', () async {
      await store.addUsage('a', 10);
      await store.setUsedBytes('a', 3);
      expect(await store.usedBytes('a'), 3);
    });

    test('负数字节计数被拒绝，不改变已用值', () async {
      await store.addUsage('a', 10);
      await expectLater(store.addUsage('a', -1), throwsArgumentError);
      await expectLater(store.setUsedBytes('a', -5), throwsArgumentError);
      expect(await store.usedBytes('a'), 10);
    });

    test('磁盘空间默认合法，可显式设置', () async {
      final initial = await store.diskSpace();
      expect(initial.freeBytes, greaterThanOrEqualTo(0));
      expect(initial.totalBytes, greaterThan(0));
      expect(initial.freeBytes, lessThanOrEqualTo(initial.totalBytes));

      await store.setDiskSpace(freeBytes: 3, totalBytes: 10);
      final set = await store.diskSpace();
      expect(set.freeBytes, 3);
      expect(set.totalBytes, 10);
    });

    test('非法磁盘设置被拒绝，不改变原值', () async {
      await store.setDiskSpace(freeBytes: 5, totalBytes: 10);
      await expectLater(
        store.setDiskSpace(freeBytes: 11, totalBytes: 10),
        throwsArgumentError,
      );
      await expectLater(
        store.setDiskSpace(freeBytes: -1, totalBytes: 10),
        throwsArgumentError,
      );
      final after = await store.diskSpace();
      expect(after.freeBytes, 5);
      expect(after.totalBytes, 10);
    });
  });
}
