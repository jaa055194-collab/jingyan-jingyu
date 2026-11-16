/// [DepartureStore] 契约测试。任何实现（内存、SQLite）都必须通过。
library;

import 'package:jingyu_host/src/lifecycle/departure.dart';
import 'package:test/test.dart';

void departureStoreContract(
  String label,
  DepartureStore Function() create,
  Future<void> Function(DepartureStore store) seed,
) {
  group('DepartureStore 契约 [$label]', () {
    late DepartureStore store;
    setUp(() async {
      store = create();
      await seed(store);
    });

    test('survey 返回对象计数且不清空数据', () async {
      final first = await store.survey('u1');
      expect(first.objectCounts['conversations'], 2);
      expect(first.objectCounts['messages'], 10);
      expect(first.momentsToAnonymize, 3);
      final second = await store.survey('u1');
      expect(second.objectCounts, first.objectCounts, reason: 'survey 不改变状态');
    });

    test('purge 返回计数并清空数据', () async {
      final purged = await store.purge('u1');
      expect(purged.objectCounts['conversations'], 2);
      expect(purged.momentsToAnonymize, 3);
      final after = await store.survey('u1');
      expect(after.objectCounts, isEmpty);
      expect(after.momentsToAnonymize, 0);
    });

    test('未知账号计数为空', () async {
      final survey = await store.survey('nobody');
      expect(survey.objectCounts, isEmpty);
      expect(survey.momentsToAnonymize, 0);
    });

    test('备份保留天数默认 30 天', () async {
      expect(await store.backupRetentionDays(), 30);
    });
  });
}
