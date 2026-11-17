/// M10 world HTTP 路由契约测试：认证、owner 隔离、版本 CAS、404、门锁、拜访鉴权。
///
/// 直接对 `WorldModule.mount` 声明的路由调用 handler（不经过 dart:io），
/// 通过 `request.principal` 模拟已认证主体。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/avatars.dart';
import 'package:jingyu_host/src/world/layout_store.dart';
import 'package:jingyu_host/src/world/presence.dart';
import 'package:jingyu_host/src/world/world_module.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';
import 'package:test/test.dart';

import 'world_presence_service_contract.dart';

const _me = Principal(accountId: 'me', deviceId: 'd1');
const _guest = Principal(accountId: 'guest', deviceId: 'd2');
const _stranger = Principal(accountId: 'stranger', deviceId: 'd3');

// Same owner, different devices: avatar state is per device.
const _mePhone = Principal(accountId: 'me', deviceId: 'phone');
const _mePc = Principal(accountId: 'me', deviceId: 'pc');

class _Harness {
  _Harness() {
    router = Router();
    module = WorldModule(
      layouts: layouts,
      presence: presence,
      avatars: avatars,
      clock: clock,
    );
    module.mount(router);
  }

  final FakeClock clock = FakeClock(DateTime.utc(2026, 11, 16, 12));
  final FakeVisitAccessPolicy policy = FakeVisitAccessPolicy();
  late final InMemorySpaceLayoutStore layouts = InMemorySpaceLayoutStore(
    clock: clock,
  );
  late final InMemoryPresenceService presence = InMemoryPresenceService(
    clock: clock,
    policy: policy,
  );
  late final InMemoryAvatarRegistry avatars = InMemoryAvatarRegistry(
    clock: clock,
  );
  late final WorldModule module;
  late final Router router;

  Future<HostResponse> call(
    String method,
    String path, {
    Principal? principal,
    Object? body,
  }) async {
    final match = router.match(method, path);
    if (match == null) throw StateError('no route $method $path');
    return match.handler(
      HostRequest(
        method: method,
        path: path,
        principal: principal,
        body: body,
        pathParams: match.pathParams,
      ),
    );
  }
}

String _layoutPath(String spaceId) =>
    Routes.worldSpaceLayout.replaceAll('{spaceId}', spaceId);
String _presencePath(String spaceId) =>
    Routes.worldSpacePresence.replaceAll('{spaceId}', spaceId);
String _invitationsPath(String spaceId) =>
    Routes.worldSpaceInvitations.replaceAll('{spaceId}', spaceId);
String _endPath(String visitId) =>
    Routes.worldVisitEnd.replaceAll('{visitId}', visitId);
String _timeoutPath(String visitId) =>
    Routes.worldVisitTimeout.replaceAll('{visitId}', visitId);
String _enablePath(String avatarId) =>
    Routes.worldAvatarEnable.replaceAll('{avatarId}', avatarId);

Map<String, Object?> _layoutBody(
  int expectedVersion, {
  String style = 'seaside',
}) => {
  'expectedVersion': expectedVersion,
  'style': style,
  'rooms': [
    {
      'roomId': 'living',
      'name': 'Living',
      'furniture': [
        {'itemId': 'sofa', 'assetId': 'sofa_01', 'x': 1, 'y': 0, 'z': 2},
      ],
    },
  ],
};

void main() {
  test('未认证请求一律 401', () async {
    final h = _Harness();
    final cases = <(String, String)>[
      ('GET', _layoutPath('me')),
      ('PUT', _layoutPath('me')),
      ('GET', _presencePath('villa_me')),
      ('POST', Routes.worldVisits),
      ('POST', _endPath('v1')),
      ('POST', _timeoutPath('v1')),
      ('POST', _invitationsPath('me')),
      ('GET', Routes.worldAvatars),
      ('POST', Routes.worldAvatars),
      ('POST', _enablePath('av1')),
      ('GET', Routes.worldAvatarActive),
    ];
    for (final (method, path) in cases) {
      final response = await h.call(method, path);
      expect(response.status, 401, reason: '$method $path');
    }
  });

  test('PUT 自己别墅布局：版本 CAS，成功递增 / 过期 conflict', () async {
    final h = _Harness();
    final first = await h.call(
      'PUT',
      _layoutPath('me'),
      principal: _me,
      body: _layoutBody(0),
    );
    expect(first.status, 200);
    expect((first.json! as Map<String, Object?>)['version'], 1);

    final stale = await h.call(
      'PUT',
      _layoutPath('me'),
      principal: _me,
      body: _layoutBody(0),
    );
    expect(stale.status, 409);

    final second = await h.call(
      'PUT',
      _layoutPath('me'),
      principal: _me,
      body: _layoutBody(1, style: 'modern'),
    );
    expect(second.status, 200);
    expect((second.json! as Map<String, Object?>)['version'], 2);
  });

  test('owner 隔离：不能修改他人别墅布局（404），但可读已知布局', () async {
    final h = _Harness();
    final denied = await h.call(
      'PUT',
      _layoutPath('other'),
      principal: _me,
      body: _layoutBody(0),
    );
    expect(denied.status, 404);

    // 未知空间读取 404。
    final unknown = await h.call('GET', _layoutPath('nope'), principal: _me);
    expect(unknown.status, 404);

    // 自己保存后任意登录用户可按 id 读取（街区共享外景）。
    await h.call(
      'PUT',
      _layoutPath('me'),
      principal: _me,
      body: _layoutBody(0),
    );
    final read = await h.call('GET', _layoutPath('me'), principal: _guest);
    expect(read.status, 200);
    expect((read.json! as Map<String, Object?>)['spaceId'], 'me');
  });

  test('GET presence 返回宿主权威位置快照', () async {
    final h = _Harness();
    await h.presence.registerResident(
      residentId: 'me',
      homeSpaceId: 'villa_me',
    );
    await h.presence.move(
      residentId: 'me',
      spaceId: 'villa_me',
      position: const Position(3, 0, 0),
      motion: PresenceMotion.walk,
    );
    final response = await h.call(
      'GET',
      _presencePath('villa_me'),
      principal: _me,
    );
    expect(response.status, 200);
    final positions =
        (response.json! as Map<String, Object?>)['positions']! as List<Object?>;
    expect(positions, hasLength(1));
  });

  test('门锁：室内无邀请 403；主人发邀请后可进', () async {
    final h = _Harness();
    h.policy.befriend('guest', 'me');
    await h.presence.registerResident(
      residentId: 'guest',
      homeSpaceId: 'villa_guest',
    );
    await h.presence.registerResident(
      residentId: 'me',
      homeSpaceId: 'villa_me',
    );

    final locked = await h.call(
      'POST',
      Routes.worldVisits,
      principal: _guest,
      body: {'hostOwnerId': 'me', 'location': 'indoor'},
    );
    expect(locked.status, 403);

    final invite = await h.call(
      'POST',
      _invitationsPath('me'),
      principal: _me,
      body: {'visitorId': 'guest'},
    );
    expect(invite.status, 200);
    final token = (invite.json! as Map<String, Object?>)['token']! as String;

    final invited = await h.call(
      'POST',
      Routes.worldVisits,
      principal: _guest,
      body: {
        'hostOwnerId': 'me',
        'location': 'indoor',
        'invitationToken': token,
      },
    );
    expect(invited.status, 200);
    expect((invited.json! as Map<String, Object?>)['status'], 'active');
  });

  test('邀请 owner 隔离：不能替他人别院发邀请', () async {
    final h = _Harness();
    final denied = await h.call(
      'POST',
      _invitationsPath('other'),
      principal: _me,
      body: {'visitorId': 'guest'},
    );
    expect(denied.status, 404);
  });

  test('拜访结束/超时：非参与方 404，访客可结束', () async {
    final h = _Harness();
    h.policy.befriend('guest', 'me');
    await h.presence.registerResident(
      residentId: 'guest',
      homeSpaceId: 'villa_guest',
    );
    await h.presence.registerResident(
      residentId: 'me',
      homeSpaceId: 'villa_me',
    );
    final created = await h.call(
      'POST',
      Routes.worldVisits,
      principal: _guest,
      body: {'hostOwnerId': 'me', 'location': 'yard'},
    );
    expect(created.status, 200);
    final visitId =
        (created.json! as Map<String, Object?>)['visitId']! as String;

    final denied = await h.call(
      'POST',
      _endPath(visitId),
      principal: _stranger,
    );
    expect(denied.status, 404);

    final ended = await h.call('POST', _endPath(visitId), principal: _guest);
    expect(ended.status, 200);
    expect((ended.json! as Map<String, Object?>)['status'], 'ended');

    // 未知拜访 404。
    final missing = await h.call(
      'POST',
      _endPath('missing'),
      principal: _guest,
    );
    expect(missing.status, 404);
  });

  test(
    'avatar creation accepts only kind and stable modelId references',
    () async {
      final h = _Harness();
      for (final body in <Map<String, Object?>>[
        {
          'kind': 'live2d',
          'modelId': 'model_local',
          'paramMap': {'mouthOpen': 'Param'},
        },
        {
          'kind': 'live2d',
          'modelId': 'model_local',
          'modelFile': 'avatar.moc3',
        },
        {'kind': 'live2d', 'modelId': 'model_local', 'unexpected': true},
        // The device must come from the authenticated principal, never the body.
        {'kind': 'live2d', 'modelId': 'model_local', 'deviceId': 'pc'},
        {'kind': 'live2d', 'modelId': '../avatar.moc3'},
        {'kind': 'live2d', 'modelId': 'https://example.test/model'},
      ]) {
        final response = await h.call(
          'POST',
          Routes.worldAvatars,
          principal: _me,
          body: body,
        );
        expect(response.status, 400, reason: '$body');
      }
      final accepted = await h.call(
        'POST',
        Routes.worldAvatars,
        principal: _me,
        body: {'kind': 'live2d', 'modelId': 'local_model-v2'},
      );
      expect(accepted.status, 200);
      expect(
        (accepted.json! as Map<String, Object?>).keys,
        isNot(contains('paramMap')),
      );
      expect(
        (accepted.json! as Map<String, Object?>).keys,
        isNot(contains('modelFile')),
      );
    },
  );

  test('avatars：同一 owner 手机与 PC 各自 active，跨设备不可见', () async {
    final h = _Harness();

    // 手机登记并启用手机形象。
    final phoneCreated = await h.call(
      'POST',
      Routes.worldAvatars,
      principal: _mePhone,
      body: {'kind': 'vrm', 'modelId': 'vrm_phone'},
    );
    expect(phoneCreated.status, 200);
    final phoneId = (phoneCreated.json! as Map<String, Object?>)['avatarId']!
        as String;
    final phoneEnabled = await h.call(
      'POST',
      _enablePath(phoneId),
      principal: _mePhone,
      body: {'expectedRevision': 1},
    );
    expect(phoneEnabled.status, 200);

    // PC 与手机同 owner，但看不到也启用不了手机形象。
    final pcList = await h.call('GET', Routes.worldAvatars, principal: _mePc);
    expect(pcList.status, 200);
    expect(
      (pcList.json! as Map<String, Object?>)['avatars']! as List<Object?>,
      isEmpty,
    );
    final pcForeignEnable = await h.call(
      'POST',
      _enablePath(phoneId),
      principal: _mePc,
      body: {'expectedRevision': 1},
    );
    expect(pcForeignEnable.status, 404);
    final pcActiveBefore = await h.call(
      'GET',
      Routes.worldAvatarActive,
      principal: _mePc,
    );
    expect(pcActiveBefore.status, 404);

    // PC 登记并启用自己的形象，手机 active 不受影响。
    final pcCreated = await h.call(
      'POST',
      Routes.worldAvatars,
      principal: _mePc,
      body: {'kind': 'live2d', 'modelId': 'l2d_pc'},
    );
    expect(pcCreated.status, 200);
    final pcId = (pcCreated.json! as Map<String, Object?>)['avatarId']! as String;
    final pcEnabled = await h.call(
      'POST',
      _enablePath(pcId),
      principal: _mePc,
      body: {'expectedRevision': 1},
    );
    expect(pcEnabled.status, 200);

    final phoneActive = await h.call(
      'GET',
      Routes.worldAvatarActive,
      principal: _mePhone,
    );
    expect((phoneActive.json! as Map<String, Object?>)['modelId'], 'vrm_phone');
    final pcActive = await h.call(
      'GET',
      Routes.worldAvatarActive,
      principal: _mePc,
    );
    expect((pcActive.json! as Map<String, Object?>)['modelId'], 'l2d_pc');
  });

  test('avatars：owner 隔离 + 创建/启用/active 广播', () async {
    final h = _Harness();
    final created = await h.call(
      'POST',
      Routes.worldAvatars,
      principal: _me,
      body: {'kind': 'vrm', 'modelId': 'vrm_a'},
    );
    expect(created.status, 200);
    final profile = created.json! as Map<String, Object?>;
    final avatarId = profile['avatarId']! as String;
    expect(profile['profileRev'], 1);

    // 他人不能启用我的形象（404，不泄露存在性）。
    final otherEnable = await h.call(
      'POST',
      _enablePath(avatarId),
      principal: _stranger,
      body: {'expectedRevision': 1},
    );
    expect(otherEnable.status, 404);

    final list = await h.call('GET', Routes.worldAvatars, principal: _me);
    expect(list.status, 200);
    expect(
      (list.json! as Map<String, Object?>)['avatars']! as List<Object?>,
      hasLength(1),
    );

    final enabled = await h.call(
      'POST',
      _enablePath(avatarId),
      principal: _me,
      body: {'expectedRevision': 1},
    );
    expect(enabled.status, 200);
    expect((enabled.json! as Map<String, Object?>)['profileRev'], 2);

    final active = await h.call(
      'GET',
      Routes.worldAvatarActive,
      principal: _me,
    );
    expect(active.status, 200);
    expect((active.json! as Map<String, Object?>)['modelId'], 'vrm_a');

    // 没有启用形象的人 active 返回 404。
    final none = await h.call(
      'GET',
      Routes.worldAvatarActive,
      principal: _stranger,
    );
    expect(none.status, 404);
  });
}
