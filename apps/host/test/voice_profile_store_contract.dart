// 音色档案存储契约（M08）。
//
// 内存实现与将来的 SQLite 实现必须通过同一份契约：
// * AC-11 同一 AI 只有一个音色档案；
// * FR-31 导入样本必须有 consent_ref 且满足 10–30s、单声道、≥16kHz；
// * AC-11 参数变更产生新 revision，且只在句边界生效；可回滚；
// * FR-31 删除只保留同意记录，不保留音频明文。
import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/voice/voice_profiles.dart';
import 'package:test/test.dart';

/// 一个实现需要提供的夹具。
abstract class VoiceProfileFixture {
  VoiceProfiles get profiles;
  FakeClock get clock;
  Future<void> close();
}

/// 对任意 [VoiceProfiles] 实现运行契约测试。
void voiceProfileContract(
  String label,
  Future<VoiceProfileFixture> Function() create,
) {
  group(label, () {
    late VoiceProfileFixture fixture;
    final ai = AiId.parse('ai1');

    setUp(() async => fixture = await create());
    tearDown(() => fixture.close());

    Future<Result<VoiceProfile>> seed({
      Map<String, Object?> params = const {'speed': 1.0},
    }) =>
        fixture.profiles.create(
          ai: ai,
          provider: 'minimax',
          model: 'speech-01',
          voiceId: 'v-100',
          consentRef: 'consent-1',
          grantedBy: 'owner',
          params: params,
        );

    test('AC-11 one AI has exactly one voice profile', () async {
      final first = await seed();
      expect(first.isOk, isTrue, reason: first.failureOrNull?.message);
      expect(first.value.revision, 1);
      expect(first.value.voiceId, 'v-100');
      expect(first.value.provider, 'minimax');

      final second = await fixture.profiles.create(
        ai: ai,
        provider: 'azure',
        model: 'other',
        voiceId: 'v-other',
        consentRef: 'consent-2',
        grantedBy: 'owner',
      );
      expect(second.failureOrNull?.code, FailureCode.conflict);

      final current = await fixture.profiles.get(ai: ai);
      expect(current.value.voiceId, 'v-100');
      expect(current.value.provider, 'minimax');
    });

    test('FR-31 import sample enforces consent and quality window', () async {
      final valid = VoiceSampleMeta(
        duration: const Duration(seconds: 20),
        sampleRateHz: 24000,
        channels: 1,
      );

      final missingConsent = await fixture.profiles.importSample(
        ai: ai,
        sample: valid,
        consentRef: '',
      );
      expect(missingConsent.failureOrNull?.code, FailureCode.invalidArgument);

      final tooShort = await fixture.profiles.importSample(
        ai: ai,
        sample: VoiceSampleMeta(
          duration: const Duration(seconds: 6),
          sampleRateHz: 24000,
          channels: 1,
        ),
        consentRef: 'consent-1',
      );
      expect(tooShort.failureOrNull?.code, FailureCode.invalidArgument);

      final monoLowRate = await fixture.profiles.importSample(
        ai: ai,
        sample: VoiceSampleMeta(
          duration: const Duration(seconds: 20),
          sampleRateHz: 8000,
          channels: 2,
        ),
        consentRef: 'consent-1',
      );
      expect(monoLowRate.failureOrNull?.code, FailureCode.invalidArgument);

      final ok = await fixture.profiles.importSample(
        ai: ai,
        sample: valid,
        consentRef: 'consent-1',
      );
      expect(ok.isOk, isTrue, reason: ok.failureOrNull?.message);
    });

    test(
      'AC-11 param change opens a new revision but only applies at sentence boundary',
      () async {
        await seed(params: {'speed': 1.0});

        final staged = await fixture.profiles.stageParams(
          ai: ai,
          params: {'speed': 1.2, 'emotion': 'happy'},
        );
        expect(staged.isOk, isTrue);
        // Still on the active revision 1 until the sentence boundary.
        expect(staged.value.revision, 1);
        expect(staged.value.params['speed'], 1.0);
        expect(staged.value.hasPendingRevision, isTrue);
        expect(staged.value.pendingRevision, 2);

        final applied = await fixture.profiles.applyAtSentenceBoundary(ai: ai);
        expect(applied.value.revision, 2);
        expect(applied.value.params['speed'], 1.2);
        expect(applied.value.params['emotion'], 'happy');
        expect(applied.value.hasPendingRevision, isFalse);

        final history = await fixture.profiles.history(ai: ai);
        expect(
          history.value.map((revision) => revision.revision).toList(),
          [1, 2],
        );
      },
    );

    test('AC-11 rollback restores an earlier revision at the next boundary',
        () async {
      await seed(params: {'speed': 1.0});
      await fixture.profiles.stageParams(ai: ai, params: {'speed': 1.5});
      await fixture.profiles.applyAtSentenceBoundary(ai: ai); // revision 2

      final rolledBack = await fixture.profiles.rollback(ai: ai, revision: 1);
      expect(rolledBack.isOk, isTrue, reason: rolledBack.failureOrNull?.message);
      expect(rolledBack.value.hasPendingRevision, isTrue);
      expect(rolledBack.value.pendingParams!['speed'], 1.0);

      final applied = await fixture.profiles.applyAtSentenceBoundary(ai: ai);
      expect(applied.value.revision, 3);
      expect(applied.value.params['speed'], 1.0);
    });

    test('AC-11 rollback to unknown revision is rejected', () async {
      await seed();
      final result = await fixture.profiles.rollback(ai: ai, revision: 99);
      expect(result.failureOrNull?.code, FailureCode.notFound);
    });

    test('FR-31 delete drops the profile but keeps the consent record',
        () async {
      await seed();

      final removed = await fixture.profiles.delete(ai: ai);
      expect(removed.isOk, isTrue, reason: removed.failureOrNull?.message);

      expect(
        (await fixture.profiles.get(ai: ai)).failureOrNull?.code,
        FailureCode.notFound,
      );
      final consents = await fixture.profiles.consents(ai: ai);
      expect(
        consents.value.map((consent) => consent.consentRef).toList(),
        contains('consent-1'),
      );
    });
  });
}
