/// ReportsStore 契约测试。任何实现（内存、SQLite）都必须通过。
///
/// 用法：在实现的测试文件里调用 `reportsStoreContract('内存', () => InMemoryReportsStore())`。
library;

import 'package:jingyu_host/src/creative/reports/reports_models.dart';
import 'package:jingyu_host/src/creative/reports/reports_store.dart';
import 'package:test/test.dart';

void reportsStoreContract(String label, ReportsStore Function() create) {
  group('ReportsStore 契约 [$label]', () {
    late ReportsStore store;

    setUp(() => store = create());

    ReportRecord record({
      String owner = 'u1',
      String ai = 'ai1',
      ReportKind kind = ReportKind.weekly,
      String periodKey = '2026-11-15',
      ReportStatus status = ReportStatus.missed,
    }) => ReportRecord(
      ownerAccountId: owner,
      aiId: ai,
      kind: kind,
      periodKey: periodKey,
      status: status,
      updatedAt: DateTime.utc(2026, 11, 15, 13, 30),
    );

    test('未写入时 find 返回 null', () async {
      final found = await store.find(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        kind: ReportKind.weekly,
        periodKey: '2026-11-15',
      );
      expect(found, isNull);
    });

    test('upsert 后可按唯一键找回，字段一致', () async {
      await store.upsert(record(status: ReportStatus.generated));
      final found = await store.find(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        kind: ReportKind.weekly,
        periodKey: '2026-11-15',
      );
      expect(found, isNotNull);
      expect(found!.status, ReportStatus.generated);
      expect(found.ownerAccountId, 'u1');
      expect(found.aiId, 'ai1');
    });

    test('同唯一键 upsert 覆盖而非新增', () async {
      await store.upsert(record(status: ReportStatus.deferred));
      await store.upsert(record(status: ReportStatus.generated));
      final all = await store.listByOwner('u1');
      expect(all, hasLength(1));
      expect(all.single.status, ReportStatus.generated);
    });

    test('不同 kind/period 是不同记录', () async {
      await store.upsert(record(kind: ReportKind.weekly));
      await store.upsert(record(kind: ReportKind.annual, periodKey: '2026'));
      expect(await store.listByOwner('u1'), hasLength(2));
    });

    test('跨用户隔离：A 的记录 B 查不到', () async {
      await store.upsert(record(owner: 'u1'));
      final foreign = await store.find(
        ownerAccountId: 'u2',
        aiId: 'ai1',
        kind: ReportKind.weekly,
        periodKey: '2026-11-15',
      );
      expect(foreign, isNull);
    });

    test('listByOwner 只返回本用户记录', () async {
      await store.upsert(record(owner: 'u1'));
      await store.upsert(record(owner: 'u2'));
      final mine = await store.listByOwner('u1');
      expect(mine, hasLength(1));
      expect(mine.single.ownerAccountId, 'u1');
    });
  });
}
