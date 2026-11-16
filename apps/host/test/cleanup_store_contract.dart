/// [CleanupStore] 契约测试。任何实现（内存、SQLite）都必须通过。
library;

import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:test/test.dart';

void cleanupStoreContract(String label, CleanupStore Function() create) {
  group('CleanupStore 契约 [$label]', () {
    late CleanupStore store;
    setUp(() => store = create());

    MediaAsset asset(
      String id, {
      DateTime? created,
      Map<String, String>? holders,
    }) => MediaAsset(
      id: id,
      kind: MediaKind.video,
      createdAt: created ?? DateTime.utc(2026, 1, 1),
      holderMessageIds: holders ?? const {'a': 'm1'},
    );

    test('新增媒体可按 id 取回，默认 blob 存在', () async {
      await store.addAsset(asset('x'));
      final got = await store.asset('x');
      expect(got, isNotNull);
      expect(got!.blobPresent, isTrue);
      expect(await store.asset('missing'), isNull);
    });

    test('deleteBlob 幂等置为不存在', () async {
      await store.addAsset(asset('x'));
      await store.deleteBlob('x');
      expect((await store.asset('x'))!.blobPresent, isFalse);
      await store.deleteBlob('x');
      expect((await store.asset('x'))!.blobPresent, isFalse);
    });

    test('占位按持有账号查询，互不串', () async {
      await store.putPlaceholder(
        const MediaPlaceholder(
          assetId: 'x',
          ownerAccountId: 'a',
          messageId: 'm1',
          reason: '媒体已过期清理（可重新上传）',
        ),
      );
      await store.putPlaceholder(
        const MediaPlaceholder(
          assetId: 'y',
          ownerAccountId: 'b',
          messageId: 'm2',
          reason: '媒体已过期清理（可重新上传）',
        ),
      );
      final a = await store.placeholdersFor('a');
      expect(a.single.assetId, 'x');
      expect((await store.placeholdersFor('b')).single.assetId, 'y');
      expect(await store.placeholdersFor('c'), isEmpty);
    });

    test('提醒时间记录与每日运行标记', () async {
      await store.addAsset(asset('x'));
      expect(store.remindedAt('x'), isNull);
      await store.markReminded('x', DateTime.utc(2026, 3, 1));
      expect(store.remindedAt('x'), DateTime.utc(2026, 3, 1));
      expect(await store.ranOn('2026-03-01'), isFalse);
      await store.markRan('2026-03-01');
      expect(await store.ranOn('2026-03-01'), isTrue);
      expect(await store.ranOn('2026-03-02'), isFalse);
    });
  });
}
