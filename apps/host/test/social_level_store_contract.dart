import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/ai/social_level/social_level_service.dart';
import 'package:test/test.dart';

abstract class SocialLevelFixture {
  SocialLevelService get store;
  FakeClock get clock;
  Future<void> transfer(String owner);
  Future<void> setOwnerActive(bool active);
  Future<void> setAiActive(bool active);
  Future<void> close();
}

void socialLevelContract(
  String label,
  Future<SocialLevelFixture> Function() create,
) {
  group(label, () {
    late SocialLevelFixture fixture;
    final owner = AccountId.parse('owner');
    final other = AccountId.parse('other');
    final ai = AiId.parse('profile');
    setUp(() async => fixture = await create());
    tearDown(() => fixture.close());
    test('FR43 absence is explicit and no default is inferred', () async {
      final result = await fixture.store.get(owner: owner, ai: ai);
      expect(result.isOk, isTrue);
      expect(result.value.configurationRequired, isTrue);
      expect(result.value.level, isNull);
      expect(result.value.updatedAt, isNull);
    });
    test('FR43 every explicit level persists with injected clock', () async {
      for (final level in AiSocialLevel.values) {
        final saved = await fixture.store.set(
          owner: owner,
          ai: ai,
          level: level,
        );
        expect(saved.isOk, isTrue);
        expect(saved.value.level, level);
        expect(saved.value.updatedAt, fixture.clock.now());
        expect(
          (await fixture.store.get(owner: owner, ai: ai)).value.level,
          level,
        );
        fixture.clock.advance(const Duration(seconds: 1));
      }
    });
    test(
      'FR67 foreign owner and unknown AI never read or mutate state',
      () async {
        await fixture.store.set(owner: owner, ai: ai, level: AiSocialLevel.l1);
        expect(
          (await fixture.store.get(owner: other, ai: ai)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await fixture.store.set(
            owner: other,
            ai: ai,
            level: AiSocialLevel.l4,
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await fixture.store.get(
            owner: owner,
            ai: AiId.parse('missing'),
          )).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await fixture.store.get(owner: owner, ai: ai)).value.level,
          AiSocialLevel.l1,
        );
      },
    );
    test(
      'FR43 transfer isolates new owner and retransfer restores dormant explicit state',
      () async {
        await fixture.store.set(owner: owner, ai: ai, level: AiSocialLevel.l3);
        await fixture.transfer('other');
        expect(
          (await fixture.store.get(owner: owner, ai: ai)).failureOrNull?.code,
          FailureCode.notFound,
        );
        expect(
          (await fixture.store.get(
            owner: other,
            ai: ai,
          )).value.configurationRequired,
          isTrue,
        );
        await fixture.store.set(owner: other, ai: ai, level: AiSocialLevel.l0);
        await fixture.transfer('owner');
        expect(
          (await fixture.store.get(owner: owner, ai: ai)).value.level,
          AiSocialLevel.l3,
        );
        expect(
          (await fixture.store.get(owner: other, ai: ai)).failureOrNull?.code,
          FailureCode.notFound,
        );
      },
    );
    test(
      'FR43 disabled owner or AI denies read and write without changing saved state',
      () async {
        await fixture.store.set(owner: owner, ai: ai, level: AiSocialLevel.l1);
        for (final change in [fixture.setOwnerActive, fixture.setAiActive]) {
          await change(false);
          expect(
            (await fixture.store.get(owner: owner, ai: ai)).failureOrNull?.code,
            FailureCode.notFound,
          );
          expect(
            (await fixture.store.set(
              owner: owner,
              ai: ai,
              level: AiSocialLevel.l4,
            )).failureOrNull?.code,
            FailureCode.notFound,
          );
          await change(true);
        }
        expect(
          (await fixture.store.get(owner: owner, ai: ai)).value.level,
          AiSocialLevel.l1,
        );
      },
    );
  });
}
