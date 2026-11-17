import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/lifecycle/cleanup.dart';
import 'package:test/test.dart';

void main() {
  late FakeClock clock;
  late InMemoryCleanupStore store;
  late CleanupService service;

  setUp(() async {
    clock = FakeClock(DateTime.utc(2026, 3, 1));
    store = InMemoryCleanupStore();
    service = CleanupService(store: store, clock: clock);
    Future<void> add(
      String id,
      MediaKind kind,
      int ageDays,
      Map<String, String> holders, {
      bool blobPresent = true,
    }) => store.addAsset(
      MediaAsset(
        id: id,
        kind: kind,
        createdAt: clock.now().subtract(Duration(days: ageDays)),
        holderMessageIds: holders,
        blobPresent: blobPresent,
      ),
    );
    await add('v-old', MediaKind.video, 91, {'owner': 'm1', 'other': 'm2'});
    await add('v-remind', MediaKind.video, 85, {'owner': 'm1'});
    await add('a-young', MediaKind.voice, 10, {'owner': 'm1'});
    await add('v-other', MediaKind.video, 91, {'other': 'm2'});
    await add('a-gone', MediaKind.voice, 91, {
      'owner': 'm1',
    }, blobPresent: false);
  });

  test(
    'preview classifies remind/expire per kind and filters by owner',
    () async {
      final owner = await service.retentionPreview(ownerAccountId: 'owner');
      expect(owner.dayKey, '2026-03-01');
      expect(owner.totalHeld[MediaKind.video], 2);
      expect(
        owner.totalHeld[MediaKind.voice],
        1,
      ); // a-gone blob absent excluded
      expect(owner.expiring[MediaKind.video], 1); // v-old
      expect(owner.remindSoon[MediaKind.video], 1); // v-remind

      final other = await service.retentionPreview(ownerAccountId: 'other');
      expect(other.totalHeld[MediaKind.video], 2); // v-old + v-other
      expect(other.expiring[MediaKind.video], 2);
      expect(other.remindSoon[MediaKind.video], isNull);
    },
  );

  test(
    'preview is read-only: no blob delete, reminder, placeholder or run mark',
    () async {
      await service.retentionPreview(ownerAccountId: 'owner');
      final assets = await store.expirableAssets();
      expect(assets.firstWhere((a) => a.id == 'v-old').blobPresent, isTrue);
      expect(await store.remindedAt('v-remind'), isNull);
      expect(await store.placeholdersFor('owner'), isEmpty);
      expect(await store.ranOn(dayKey(clock.now())), isFalse);
    },
  );

  test('after daily run the preview reflects cleaned/reminded state', () async {
    final report = (await service.run()).value;
    expect(report.expiredCount, 2); // v-old + v-other
    expect(report.remindedCount, 1); // v-remind

    final owner = await service.retentionPreview(ownerAccountId: 'owner');
    expect(owner.expiring[MediaKind.video], isNull); // v-old blob now absent
    expect(owner.remindSoon[MediaKind.video], isNull); // already reminded
    expect(owner.totalHeld[MediaKind.video], 1); // v-remind only
    expect(owner.totalHeld[MediaKind.voice], 1); // a-young
  });
}
