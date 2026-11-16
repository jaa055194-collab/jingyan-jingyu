/// AvatarRegistry 契约测试。
///
/// Covers reference-only avatar registration and revision broadcasts.
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:test/test.dart';

void avatarRegistryContract(
  String label,
  ({AvatarRegistry registry, FakeClock clock}) Function() create,
) {
  group('AvatarRegistry 契约 [$label]', () {
    late AvatarRegistry registry;
    late FakeClock clock;

    setUp(() {
      final fixture = create();
      registry = fixture.registry;
      clock = fixture.clock;
    });

    test('登记 VRM 与 Live2D 得到第 1 版记录', () async {
      final vrm = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_default',
      )).value;
      expect(vrm.kind, AvatarKind.vrm);
      expect(vrm.modelId, 'vrm_default');
      expect(vrm.profileRev, 1);
      expect(vrm.updatedAt, clock.now().toUtc());

      final live2d = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.live2d,
        modelId: 'l2d_default',
      )).value;
      expect(live2d.kind, AvatarKind.live2d);
      expect(live2d.profileRev, 1);
      expect(live2d.toJson().keys, isNot(contains('paramMap')));
      expect((await registry.list('owner')).length, 2);
    });

    test(
      'Live2D without server-side mapping can be enabled by reference',
      () async {
        final profile = (await registry.register(
          ownerId: 'owner',
          kind: AvatarKind.live2d,
          modelId: 'l2d_local_model',
        )).value;
        final enabled = (await registry.enable(
          ownerId: 'owner',
          avatarId: profile.avatarId,
          expectedRevision: profile.profileRev,
        )).value;
        final broadcast = (await registry.active('owner')).value;
        expect(broadcast.kind, AvatarKind.live2d);
        expect(broadcast.modelId, 'l2d_local_model');
        expect(broadcast.profileRev, enabled.profileRev);
        expect(enabled.toJson().keys, isNot(contains('paramMap')));
      },
    );

    test('切换形象后双端拿到相同 model_id + profile_rev（AC-25）', () async {
      final first = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_a',
      )).value;
      final second = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_b',
      )).value;

      final firstActive = (await registry.enable(
        ownerId: 'owner',
        avatarId: first.avatarId,
        expectedRevision: first.profileRev,
      )).value;
      expect(firstActive.modelId, 'vrm_a');
      expect((await registry.active('owner')).value.modelId, 'vrm_a');

      final secondActive = (await registry.enable(
        ownerId: 'owner',
        avatarId: second.avatarId,
        expectedRevision: second.profileRev,
      )).value;
      final broadcast = (await registry.active('owner')).value;
      expect(broadcast.modelId, 'vrm_b');
      expect(broadcast.profileRev, secondActive.profileRev);
      // 广播与存取记录一致，双端据此渲染同一形象。
      final stored = (await registry.get(
        ownerId: 'owner',
        avatarId: second.avatarId,
      )).value;
      expect(stored.modelId, broadcast.modelId);
      expect(stored.profileRev, broadcast.profileRev);
    });

    test('过期 revision 启用返回 conflict', () async {
      final profile = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_a',
      )).value;
      final result = await registry.enable(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        expectedRevision: profile.profileRev + 5,
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.code, FailureCode.conflict);
    });

    test('跨 owner 访问返回 notFound', () async {
      final profile = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_a',
      )).value;
      expect(
        (await registry.get(
          ownerId: 'other',
          avatarId: profile.avatarId,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        (await registry.enable(
          ownerId: 'other',
          avatarId: profile.avatarId,
          expectedRevision: 1,
        )).failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(await registry.list('other'), isEmpty);
    });

    test('profileRev 每次变更单调递增', () async {
      final profile = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.vrm,
        modelId: 'vrm_a',
      )).value;
      final disabled = (await registry.disable(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        expectedRevision: profile.profileRev,
      )).value;
      expect(disabled.profileRev, greaterThan(profile.profileRev));
      final enabled = (await registry.enable(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        expectedRevision: disabled.profileRev,
      )).value;
      expect(enabled.profileRev, greaterThan(disabled.profileRev));
    });
  });
}
