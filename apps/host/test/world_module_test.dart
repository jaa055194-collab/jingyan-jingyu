/// M10 WorldModule 装配测试 + 迁移分配检查。
///
/// 本切片只交付宿主侧世界模块与服务；HTTP 路由与 `jingyu_host.dart` 装配是
/// 建议项（见交付报告），因此模块 `mount` 暂不声明路由，`configure` 负责把
/// layout / presence / avatar 三个服务登记到 HostServices。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:jingyu_host/src/world/layout_store.dart';
import 'package:jingyu_host/src/world/presence.dart';
import 'package:jingyu_host/src/world/world_migrations.dart';
import 'package:jingyu_host/src/world/world_module.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:test/test.dart';

void main() {
  group('WorldModule', () {
    test('模块名与依赖声明', () {
      final module = WorldModule(clock: FakeClock(DateTime.utc(2026, 11, 16)));
      expect(module.name, 'world');
      expect(module.dependsOn, contains('social'));
    });

    test('configure 登记 layout / presence / avatar 三个服务', () async {
      final clock = FakeClock(DateTime.utc(2026, 11, 16));
      final layouts = InMemorySpaceLayoutStore(clock: clock);
      final presencePolicy = _AllowAllPolicy();
      final presence = InMemoryPresenceService(
        clock: clock,
        policy: presencePolicy,
      );
      final avatars = InMemoryAvatarRegistry(clock: clock);
      final module = WorldModule(
        layouts: layouts,
        presence: presence,
        avatars: avatars,
        clock: clock,
      );
      final services = HostServices();
      await module.configure(services);

      expect(identical(services.get<SpaceLayoutStore>(), layouts), isTrue);
      expect(identical(services.get<PresenceService>(), presence), isTrue);
      expect(identical(services.get<AvatarRegistry>(), avatars), isTrue);

      // 通过登记的服务可完成一次真实往返（最小装配冒烟）。
      final saved = await services.get<SpaceLayoutStore>().save(
        spaceId: 'villa_a',
        expectedVersion: 0,
        style: RoomStyle.seaside,
        rooms: [
          const RoomLayout(roomId: 'living', name: 'Living', furniture: []),
        ],
      );
      expect(saved.isOk, isTrue);
      expect(saved.value.version, 1);
    });

    test('重复登记同一服务由框架拒绝（防止静默覆盖）', () async {
      final clock = FakeClock(DateTime.utc(2026, 11, 16));
      final services = HostServices();
      await WorldModule(
        layouts: InMemorySpaceLayoutStore(clock: clock),
        presence: InMemoryPresenceService(clock: clock),
        avatars: InMemoryAvatarRegistry(clock: clock),
        clock: clock,
      ).configure(services);
      await expectLater(
        () => WorldModule(
          layouts: InMemorySpaceLayoutStore(clock: clock),
          presence: InMemoryPresenceService(clock: clock),
          avatars: InMemoryAvatarRegistry(clock: clock),
          clock: clock,
        ).configure(services),
        throwsStateError,
      );
    });
  });

  group('world 迁移分配 (900–999)', () {
    test('版本号唯一、严格递增且落在预留区间', () {
      expect(worldMigrations, isNotEmpty);
      var previous = 899;
      final seen = <int>{};
      for (final migration in worldMigrations) {
        expect(migration.version, inInclusiveRange(900, 999));
        expect(migration.version, greaterThan(previous));
        expect(seen.add(migration.version), isTrue);
        expect(migration.sql.trim(), isNotEmpty);
        previous = migration.version;
      }
    });
  });
}

class _AllowAllPolicy implements VisitAccessPolicy {
  @override
  Future<bool> areFriends(String visitorId, String hostOwnerId) async => true;

  @override
  Future<bool> isBlocked(String visitorId, String hostOwnerId) async => false;

  @override
  Future<bool> isHostPresent(String hostOwnerId) async => true;

  @override
  Future<bool> aiReceivesWhileAbsent(String hostOwnerId) async => true;
}
