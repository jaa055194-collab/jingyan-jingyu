/// PresenceService 契约测试。
///
/// 覆盖 FR-36/FR-37、AC-22/AC-23、NFR-04：
/// * 位置权威在宿主，2–5Hz 快照；
/// * 拜访：好友可进小院、室内需邀请、单户访客上限 4、被拉黑方被拒；
/// * 门锁/被拒/超时回自家都有日志；主人不在时 AI 可接待（默认开、可关）；
/// * 宿主离线时位置冻结，恢复后续算，不补造路上经历。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/presence.dart';
import 'package:test/test.dart';

/// 可控的好友/拉黑/主人在场策略，模拟 social 模块提供的判定。
class FakeVisitAccessPolicy implements VisitAccessPolicy {
  final Set<String> friends = <String>{};
  final Set<String> blocked = <String>{};
  bool hostPresent = true;
  bool aiReceives = true;

  static String _key(String visitorId, String hostOwnerId) =>
      '$visitorId|$hostOwnerId';

  void befriend(String a, String b) {
    friends.add(_key(a, b));
    friends.add(_key(b, a));
  }

  void block(String visitorId, String hostOwnerId) =>
      blocked.add(_key(visitorId, hostOwnerId));

  @override
  Future<bool> areFriends(String visitorId, String hostOwnerId) async =>
      friends.contains(_key(visitorId, hostOwnerId));

  @override
  Future<bool> isBlocked(String visitorId, String hostOwnerId) async =>
      blocked.contains(_key(visitorId, hostOwnerId));

  @override
  Future<bool> isHostPresent(String hostOwnerId) async => hostPresent;

  @override
  Future<bool> aiReceivesWhileAbsent(String hostOwnerId) async => aiReceives;
}

class PresenceFixture {
  PresenceFixture(this.service, this.policy, this.clock);
  final PresenceService service;
  final FakeVisitAccessPolicy policy;
  final FakeClock clock;
}

void presenceServiceContract(String label, PresenceFixture Function() create) {
  group('PresenceService 契约 [$label]', () {
    late PresenceService service;
    late FakeVisitAccessPolicy policy;
    late FakeClock clock;

    setUp(() {
      final fixture = create();
      service = fixture.service;
      policy = fixture.policy;
      clock = fixture.clock;
    });

    Future<void> register(String id, String home) async {
      final result = await service.registerResident(
        residentId: id,
        homeSpaceId: home,
      );
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
    }

    Future<PresenceRecord> moveTo(String id, String space, double x) async {
      final result = await service.move(
        residentId: id,
        spaceId: space,
        position: Position(x, 0, 0),
        motion: PresenceMotion.walk,
      );
      expect(result.isOk, isTrue, reason: result.failureOrNull?.message);
      return result.value;
    }

    Future<List<String>> actions({String? host}) async {
      final events = await service.events(hostOwnerId: host);
      return events.map((event) => event.action).toList();
    }

    test('宿主为位置权烇：move 更新快照，positions 按空间返回', () async {
      await register('ai_a', 'villa_a');
      final record = await moveTo('ai_a', 'villa_a', 5);
      expect(record.position.x, 5);
      expect(record.motion, PresenceMotion.walk);
      expect(record.spaceId, 'villa_a');
      expect(record.updatedAt, clock.now().toUtc());

      clock.advance(const Duration(milliseconds: 250));
      final later = await moveTo('ai_a', 'villa_a', 6);
      expect(later.updatedAt.isAfter(record.updatedAt), isTrue);

      final snapshot = (await service.positions('villa_a')).value;
      expect(snapshot.single.residentId, 'ai_a');
      expect(snapshot.single.position.x, 6);
      expect((await service.positions('villa_b')).value, isEmpty);
    });

    test('2–5Hz：同步间隔落在 200–500ms 之间（NFR-04）', () {
      final ms = service.syncInterval.inMilliseconds;
      expect(ms, greaterThanOrEqualTo(200));
      expect(ms, lessThanOrEqualTo(500));
    });

    test('宿主离线位置冻结，恢复后续算，不补造路上经历', () async {
      await register('ai_a', 'villa_a');
      await moveTo('ai_a', 'villa_a', 1);
      clock.advance(const Duration(seconds: 1));

      await service.setOnline(false);
      final frozen = await service.move(
        residentId: 'ai_a',
        spaceId: 'villa_a',
        position: Position(9, 0, 0),
        motion: PresenceMotion.walk,
      );
      expect(frozen.isErr, isTrue);
      expect(frozen.failureOrNull?.code, FailureCode.unavailable);
      expect((await service.record('ai_a')).value.position.x, 1);
      expect(await service.events(), isEmpty);

      await service.setOnline(true);
      final resumed = await moveTo('ai_a', 'villa_a', 2);
      expect(resumed.position.x, 2);
    });

    test('好友可进小院并产生拜访会话', () async {
      policy.befriend('ai_a', 'owner_b');
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');

      final visit = (await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      )).value;
      expect(visit.location, VisitLocation.yard);
      expect(visit.status, VisitStatus.active);
      expect(
        (await service.activeVisits('owner_b')).single.visitId,
        visit.visitId,
      );
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitStarted),
      );
    });

    test('室内需邀请：无邀请被门锁拒绝并记日志，有邀请则可进', () async {
      policy.befriend('ai_a', 'owner_b');
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');

      final locked = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.indoor,
      );
      expect(locked.isErr, isTrue);
      expect(locked.failureOrNull?.code, FailureCode.forbidden);
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitDoorLocked),
      );

      final token = (await service.grantInvitation(
        hostOwnerId: 'owner_b',
        visitorId: 'ai_a',
      )).value;
      final invited = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.indoor,
        invitationToken: token,
      );
      expect(invited.isOk, isTrue);
      expect(invited.value.location, VisitLocation.indoor);
    });

    test('单户同时访客上限 4：第 5 位被拒并记日志（AC-23）', () async {
      await register('owner_b', 'villa_b');
      for (var i = 1; i <= 5; i++) {
        policy.befriend('guest_$i', 'owner_b');
        await register('guest_$i', 'villa_$i');
      }
      for (var i = 1; i <= 4; i++) {
        final ok = await service.requestVisit(
          visitorId: 'guest_$i',
          hostOwnerId: 'owner_b',
          location: VisitLocation.yard,
        );
        expect(ok.isOk, isTrue);
      }
      final fifth = await service.requestVisit(
        visitorId: 'guest_5',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      );
      expect(fifth.isErr, isTrue);
      expect(fifth.failureOrNull?.code, FailureCode.conflict);
      expect((await service.activeVisits('owner_b')).length, 4);
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitCapacityRejected),
      );
    });

    test('被拉黑方无法拜访，即使只是小院（C-5 / AC-23）', () async {
      policy.block('ai_a', 'owner_b');
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');
      final result = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      );
      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.code, FailureCode.forbidden);
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitBlocked),
      );
    });

    test('非好友不能进小院', () async {
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');
      final result = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      );
      expect(result.failureOrNull?.code, FailureCode.forbidden);
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitNotFriend),
      );
    });

    test('主人不在时 AI 可接待（默认开），关闭后被拒', () async {
      policy.befriend('ai_a', 'owner_b');
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');
      final token = (await service.grantInvitation(
        hostOwnerId: 'owner_b',
        visitorId: 'ai_a',
      )).value;

      policy.hostPresent = false;
      policy.aiReceives = true;
      final received = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.indoor,
        invitationToken: token,
      );
      expect(received.isOk, isTrue);
      await service.endVisit(received.value.visitId);

      policy.aiReceives = false;
      final rejected = await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.indoor,
        invitationToken: token,
      );
      expect(rejected.isErr, isTrue);
      expect(rejected.failureOrNull?.code, FailureCode.unavailable);
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitHostAbsent),
      );
    });

    test('超时回自家并记日志；结束拜访同样回自家', () async {
      policy.befriend('ai_a', 'owner_b');
      await register('ai_a', 'villa_a');
      await register('owner_b', 'villa_b');

      final visit = (await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      )).value;
      final timedOut = (await service.timeoutVisit(visit.visitId)).value;
      expect(timedOut.status, VisitStatus.timedOut);
      expect((await service.record('ai_a')).value.spaceId, 'villa_a');
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitTimeoutHome),
      );

      final second = (await service.requestVisit(
        visitorId: 'ai_a',
        hostOwnerId: 'owner_b',
        location: VisitLocation.yard,
      )).value;
      final ended = (await service.endVisit(second.visitId)).value;
      expect(ended.status, VisitStatus.ended);
      expect((await service.record('ai_a')).value.spaceId, 'villa_a');
      expect(
        await actions(host: 'owner_b'),
        contains(PresenceEventAction.visitEnded),
      );
    });
  });
}
