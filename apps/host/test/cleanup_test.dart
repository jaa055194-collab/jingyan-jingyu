/// M12 每日清理队列：视频/语音 90 天到期删 blob、留占位、到期前 7 天提醒，
/// 每日 03:30 单队列执行并写审计（AC-14 / FR-63）。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/audit/audit_log.dart';
import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:test/test.dart';

void main() {
  final base = DateTime.utc(2026, 6, 1, 12);
  late InMemoryCleanupStore store;
  late InMemoryAuditLog audit;
  late CleanupService service;

  MediaAsset media(
    String id, {
    required int ageDays,
    MediaKind kind = MediaKind.video,
    required Map<String, String> holders,
  }) => MediaAsset(
    id: id,
    kind: kind,
    createdAt: base.subtract(Duration(days: ageDays)),
    holderMessageIds: holders,
  );

  setUp(() async {
    store = InMemoryCleanupStore();
    audit = InMemoryAuditLog(clock: FakeClock(base));
    service = CleanupService(store: store, clock: FakeClock(base), audit: audit);
    await store.addAsset(media('fresh', ageDays: 80, holders: {'a': 'm0'}));
    await store.addAsset(media('remind', ageDays: 85, holders: {'a': 'm1'}));
    await store.addAsset(media('expired', ageDays: 90, holders: {'a': 'm2'}));
    await store.addAsset(
      media(
        'shared',
        ageDays: 95,
        kind: MediaKind.voice,
        holders: {'c': 'm3', 'd': 'm4'},
      ),
    );
  });

  group('每日清理单队列', () {
    test('恰好 90 天到期：删 blob、留占位，未到期不动', () async {
      final report = (await service.run(at: base)).value;
      expect(report.alreadyRan, isFalse);
      expect(report.expiredCount, 2, reason: '90 天与 95 天各一条');
      expect(report.remindedCount, 1, reason: '85 天在 7 天提醒窗内');
      expect(report.placeholderCount, 3, reason: 'expired 一个持有者 + shared 两个');

      expect((await store.asset('fresh'))!.blobPresent, isTrue);
      expect((await store.asset('remind'))!.blobPresent, isTrue);
      expect((await store.asset('expired'))!.blobPresent, isFalse);
      expect((await store.asset('shared'))!.blobPresent, isFalse);

      final aPlaceholders = await store.placeholdersFor('a');
      expect(aPlaceholders.map((p) => p.messageId), ['m2']);
      expect(
        aPlaceholders.single.reason,
        '媒体已过期清理（可重新上传）',
      );
    });

    test('共享媒体被一方清理后其他持有者都保留占位', () async {
      await service.run(at: base);
      expect((await store.placeholdersFor('c')).single.messageId, 'm3');
      expect((await store.placeholdersFor('d')).single.messageId, 'm4');
    });

    test('到期前 7 天只提醒一次，不删 blob', () async {
      final first = (await service.run(at: base)).value;
      expect(first.remindedCount, 1);
      expect(store.remindedAt('remind'), base);
      expect((await store.asset('remind'))!.blobPresent, isTrue);

      final nextDay = (await service.run(at: base.add(const Duration(days: 1)))).value;
      expect(nextDay.remindedCount, 0, reason: '已提醒过不再重复');
    });

    test('同一天重复运行幂等，不产生额外占位', () async {
      final first = (await service.run(at: base)).value;
      final second = (await service.run(at: base.add(const Duration(hours: 2)))).value;
      expect(first.alreadyRan, isFalse);
      expect(second.alreadyRan, isTrue);
      expect(second.expiredCount, 0);
      expect(second.placeholderCount, 0);
      expect((await store.placeholdersFor('a')).length, 1);
    });

    test('写审计且审计不含正文/密钥字段', () async {
      await service.run(at: base);
      final actions = audit.entries.map((e) => e.action).toList();
      expect(actions.where((a) => a == 'media.cleanup.expire').length, 2);
      expect(actions.where((a) => a == 'media.cleanup.remind').length, 1);
      for (final entry in audit.entries) {
        expect(AuditEntry.forbiddenKeys.intersection(entry.meta.keys.toSet()), isEmpty);
      }
    });

    test('报告带运行日键，跨日可再次运行', () async {
      final first = (await service.run(at: base)).value;
      expect(first.dayKey, dayKey(base));
      final next = (await service.run(at: base.add(const Duration(days: 1)))).value;
      expect(next.alreadyRan, isFalse);
      expect(next.dayKey, dayKey(base.add(const Duration(days: 1))));
    });
  });

  group('每日 03:30 调度时刻', () {
    test('当天 03:30 之前安排到当天', () {
      expect(
        CleanupService.nextScheduledRun(DateTime.utc(2026, 6, 1, 2)),
        DateTime.utc(2026, 6, 1, 3, 30),
      );
    });

    test('当天 03:30 之后安排到次日', () {
      expect(
        CleanupService.nextScheduledRun(DateTime.utc(2026, 6, 1, 10)),
        DateTime.utc(2026, 6, 2, 3, 30),
      );
    });

    test('恰好 03:30 严格顺延到次日', () {
      expect(
        CleanupService.nextScheduledRun(DateTime.utc(2026, 6, 1, 3, 30)),
        DateTime.utc(2026, 6, 2, 3, 30),
      );
    });
  });
}
