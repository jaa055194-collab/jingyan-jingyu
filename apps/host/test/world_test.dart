/// M10 world 宿主切片测试入口：内存实现跑全部共享契约。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:jingyu_host/src/world/layout_store.dart';
import 'package:jingyu_host/src/world/presence.dart';

import 'world_avatar_registry_contract.dart';
import 'world_layout_store_contract.dart';
import 'world_presence_service_contract.dart';

void main() {
  FakeClock newClock() => FakeClock(DateTime.utc(2026, 11, 16, 12));

  spaceLayoutStoreContract('memory', () {
    final clock = newClock();
    return (store: InMemorySpaceLayoutStore(clock: clock), clock: clock);
  });

  presenceServiceContract('memory', () {
    final clock = newClock();
    final policy = FakeVisitAccessPolicy();
    return PresenceFixture(
      InMemoryPresenceService(clock: clock, policy: policy),
      policy,
      clock,
    );
  });

  avatarRegistryContract('memory', () {
    final clock = newClock();
    return (registry: InMemoryAvatarRegistry(clock: clock), clock: clock);
  });
}
