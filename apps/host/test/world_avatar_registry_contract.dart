/// AvatarRegistry 契约测试。
///
/// 覆盖 FR-38/FR-39、AC-25：形象登记（VRM 默认 / Live2D 宿主端）、
/// `model_id + profile_rev` 广播一致、缺语义参数映射禁止启用、跨 owner 隔离。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:test/test.dart';

Map<String, Object?> _completeParamMap() => <String, Object?>{
  AvatarSemanticParam.mouthOpen: 'ParamMouthOpenY',
  AvatarSemanticParam.expression: 'ParamExpression',
  AvatarSemanticParam.valence: 'ParamValence',
  AvatarSemanticParam.energy: 'ParamEnergy',
};

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
        paramMap: _completeParamMap(),
      )).value;
      expect(live2d.kind, AvatarKind.live2d);
      expect(live2d.profileRev, 1);
      expect((await registry.list('owner')).length, 2);
    });

    test('Live2D 缺语义参数映射禁止启用', () async {
      final profile = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.live2d,
        modelId: 'l2d_incomplete',
      )).value;
      final enabled = await registry.enable(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        expectedRevision: profile.profileRev,
      );
      expect(enabled.isErr, isTrue);
      expect(enabled.failureOrNull?.code, FailureCode.conflict);
      expect((await registry.active('owner')).isErr, isTrue);
    });

    test('补齐参数映射后可启用，profileRev 前进', () async {
      final profile = (await registry.register(
        ownerId: 'owner',
        kind: AvatarKind.live2d,
        modelId: 'l2d_incomplete',
      )).value;
      final mapped = (await registry.setParamMap(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        paramMap: _completeParamMap(),
      )).value;
      expect(mapped.profileRev, greaterThan(profile.profileRev));
      final enabled = (await registry.enable(
        ownerId: 'owner',
        avatarId: profile.avatarId,
        expectedRevision: mapped.profileRev,
      )).value;
      final broadcast = (await registry.active('owner')).value;
      expect(broadcast.modelId, 'l2d_incomplete');
      expect(broadcast.profileRev, enabled.profileRev);
    });

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
