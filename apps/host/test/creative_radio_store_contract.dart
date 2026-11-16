/// RadioStore 契约测试。任何实现（内存、SQLite）都必须通过。
library;

import 'package:jingyu_host/src/creative/radio/radio_models.dart';
import 'package:jingyu_host/src/creative/radio/radio_store.dart';
import 'package:test/test.dart';

void radioStoreContract(String label, RadioStore Function() create) {
  group('RadioStore 契约 [$label]', () {
    late RadioStore store;

    setUp(() => store = create());

    RadioEpisode episode({
      String owner = 'u1',
      String ai = 'ai1',
      String dateKey = '2026-11-16',
    }) => RadioEpisode(
      ownerAccountId: owner,
      aiId: ai,
      dateKey: dateKey,
      scheduledFor: DateTime.utc(2026, 11, 16, 15),
      generatedAt: DateTime.utc(2026, 11, 16, 14, 50),
      script: const RadioScript([
        RadioSegment(kind: 'comfort', text: '晚安'),
      ]),
      voiceId: 'voice-1',
      offlineCacheKey: 'cache/$dateKey',
      playableOffline: true,
    );

    test('未写入时 find 返回 null', () async {
      expect(
        await store.find(
          ownerAccountId: 'u1',
          aiId: 'ai1',
          dateKey: '2026-11-16',
        ),
        isNull,
      );
    });

    test('save 后可按 (owner, ai, dateKey) 找回', () async {
      await store.save(episode());
      final found = await store.find(
        ownerAccountId: 'u1',
        aiId: 'ai1',
        dateKey: '2026-11-16',
      );
      expect(found, isNotNull);
      expect(found!.voiceId, 'voice-1');
      expect(found.playableOffline, isTrue);
      expect(found.offlineCacheKey, isNotEmpty);
    });

    test('同 (owner, ai, dateKey) 覆盖', () async {
      await store.save(episode());
      await store.save(episode());
      expect(await store.listByOwner('u1'), hasLength(1));
    });

    test('不同日期是不同期', () async {
      await store.save(episode(dateKey: '2026-11-16'));
      await store.save(episode(dateKey: '2026-11-17'));
      expect(await store.listByOwner('u1'), hasLength(2));
    });

    test('跨用户隔离：A 的电台 B 查不到', () async {
      await store.save(episode(owner: 'u1'));
      expect(
        await store.find(
          ownerAccountId: 'u2',
          aiId: 'ai1',
          dateKey: '2026-11-16',
        ),
        isNull,
      );
    });
  });
}
