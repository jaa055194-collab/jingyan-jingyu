/// M10 world 宿主模块：房间布局、连续街区寻路、presence、形象登记 + HTTP 路由。
///
/// 3D 渲染、Live2D/VRM 导入与客户端不在本模块。所有路由默认要求登录
/// （`Router.add` 默认 `Access.authenticated`），负责人/访客隔离在 handler 内基于
/// `request.principal` 判定，绝不信任请求 JSON 里的 owner。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'avatars.dart';
import 'layout_store.dart';
import 'presence.dart';

/// 世界模块。`name = 'world'`；依赖 social 提供的好友/拉黑判定。
class WorldModule extends HostModule {
  WorldModule({
    SpaceLayoutStore? layouts,
    PresenceService? presence,
    AvatarRegistry? avatars,
    this.clock = const SystemClock(),
  }) : _layouts = layouts ?? InMemorySpaceLayoutStore(clock: clock),
       _presence = presence ?? InMemoryPresenceService(clock: clock),
       _avatars = avatars ?? InMemoryAvatarRegistry(clock: clock);

  final SpaceLayoutStore _layouts;
  final PresenceService _presence;
  final AvatarRegistry _avatars;

  /// 供测试与装配注入；内存实现默认用它派生时间戳。
  final Clock clock;

  @override
  String get name => 'world';

  @override
  List<String> get dependsOn => const <String>['social'];

  @override
  Future<void> configure(HostServices services) async {
    services.provide<SpaceLayoutStore>(_layouts, owner: name);
    services.provide<PresenceService>(_presence, owner: name);
    services.provide<AvatarRegistry>(_avatars, owner: name);
  }

  @override
  void mount(Router router) {
    router.get(Routes.worldSpaceLayout, _getLayout);
    router.put(Routes.worldSpaceLayout, _putLayout);
    router.get(Routes.worldSpacePresence, _getPresence);
    router.post(Routes.worldVisits, _createVisit);
    router.post(Routes.worldVisitEnd, _endVisit);
    router.post(Routes.worldVisitTimeout, _timeoutVisit);
    router.post(Routes.worldSpaceInvitations, _invite);
    router.get(Routes.worldAvatars, _listAvatars);
    router.post(Routes.worldAvatars, _createAvatar);
    router.post(Routes.worldAvatarEnable, _enableAvatar);
    router.get(Routes.worldAvatarActive, _activeAvatar);
  }

  // ---- response helpers -----------------------------------------------------

  HostResponse _unauth() => HostResponse.failure(
    const Failure(FailureCode.unauthenticated, 'authentication required'),
  );

  HostResponse _bad() => HostResponse.failure(
    const Failure(FailureCode.invalidArgument, 'bad request'),
  );

  HostResponse _notFound() =>
      HostResponse.failure(const Failure(FailureCode.notFound, 'not found'));

  // ---- layout ---------------------------------------------------------------

  Future<HostResponse> _getLayout(HostRequest request) async {
    if (request.principal == null) return _unauth();
    final spaceId = request.pathParams['spaceId'] ?? '';
    final result = await _layouts.get(spaceId);
    return HostResponse.fromResult(result, (layout) => layout.toJson());
  }

  Future<HostResponse> _putLayout(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final spaceId = request.pathParams['spaceId'] ?? '';
    // 只有别墅主人能改自己的布局；对他人一律按不可见处理，避免探测。
    if (spaceId != principal.accountId) return _notFound();
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final expected = json['expectedVersion'];
    final styleRaw = json['style'];
    final color = json['mainColor'];
    final roomsRaw = json['rooms'];
    if (expected is! int ||
        styleRaw is! String ||
        (color != null && color is! String) ||
        roomsRaw is! List<Object?>) {
      return _bad();
    }
    final style = RoomStyle.tryParse(styleRaw);
    if (style == null) return _bad();
    final rooms = _parseRooms(roomsRaw);
    if (rooms == null) return _bad();
    final result = await _layouts.save(
      spaceId: spaceId,
      expectedVersion: expected,
      style: style,
      mainColor: color as String?,
      rooms: rooms,
    );
    return HostResponse.fromResult(result, (layout) => layout.toJson());
  }

  List<RoomLayout>? _parseRooms(List<Object?> raw) {
    final rooms = <RoomLayout>[];
    for (final entry in raw) {
      if (entry is! Map<String, Object?>) return null;
      final roomId = entry['roomId'];
      final name = entry['name'];
      final furnitureRaw = entry['furniture'];
      if (roomId is! String || name is! String || furnitureRaw is! List) {
        return null;
      }
      final furniture = <FurniturePlacement>[];
      for (final item in furnitureRaw) {
        if (item is! Map<String, Object?>) return null;
        final itemId = item['itemId'];
        final assetId = item['assetId'];
        final x = item['x'] ?? 0;
        final y = item['y'] ?? 0;
        final z = item['z'] ?? 0;
        final rotation = item['rotation'] ?? 0;
        if (itemId is! String ||
            assetId is! String ||
            x is! num ||
            y is! num ||
            z is! num ||
            rotation is! num) {
          return null;
        }
        furniture.add(
          FurniturePlacement(
            itemId: itemId,
            assetId: assetId,
            x: x.toDouble(),
            y: y.toDouble(),
            z: z.toDouble(),
            rotation: rotation.toDouble(),
          ),
        );
      }
      rooms.add(RoomLayout(roomId: roomId, name: name, furniture: furniture));
    }
    return rooms;
  }

  // ---- presence -------------------------------------------------------------

  Future<HostResponse> _getPresence(HostRequest request) async {
    if (request.principal == null) return _unauth();
    final spaceId = request.pathParams['spaceId'] ?? '';
    final result = await _presence.positions(spaceId);
    return HostResponse.fromResult(
      result,
      (records) => {
        'positions': [for (final record in records) record.toJson()],
      },
    );
  }

  // ---- visits ---------------------------------------------------------------

  Future<HostResponse> _createVisit(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    final hostOwnerId = json['hostOwnerId'];
    final locationRaw = json['location'];
    final token = json['invitationToken'];
    if (hostOwnerId is! String ||
        locationRaw is! String ||
        (token != null && token is! String)) {
      return _bad();
    }
    final VisitLocation? location = switch (locationRaw) {
      'indoor' => VisitLocation.indoor,
      'yard' => VisitLocation.yard,
      _ => null,
    };
    if (location == null) return _bad();
    final result = await _presence.requestVisit(
      visitorId: principal.accountId,
      hostOwnerId: hostOwnerId,
      location: location,
      invitationToken: token as String?,
    );
    return HostResponse.fromResult(result, (visit) => visit.toJson());
  }

  Future<HostResponse> _endVisit(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final visitId = request.pathParams['visitId'] ?? '';
    final denied = await _authorizeVisit(principal.accountId, visitId);
    if (denied != null) return denied;
    final result = await _presence.endVisit(visitId);
    return HostResponse.fromResult(result, (visit) => visit.toJson());
  }

  Future<HostResponse> _timeoutVisit(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final visitId = request.pathParams['visitId'] ?? '';
    final denied = await _authorizeVisit(principal.accountId, visitId);
    if (denied != null) return denied;
    final result = await _presence.timeoutVisit(visitId);
    return HostResponse.fromResult(result, (visit) => visit.toJson());
  }

  /// 只有访客本人或主人能操作该拜访；其余按不存在处理（不泄露存在性）。
  Future<HostResponse?> _authorizeVisit(
    String accountId,
    String visitId,
  ) async {
    final result = await _presence.getVisit(visitId);
    if (result.isErr) return HostResponse.failure(result.failureOrNull!);
    final visit = result.value;
    if (visit.visitorId != accountId && visit.hostOwnerId != accountId) {
      return _notFound();
    }
    return null;
  }

  Future<HostResponse> _invite(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final spaceId = request.pathParams['spaceId'] ?? '';
    if (spaceId != principal.accountId) return _notFound();
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final visitorId = body.value['visitorId'];
    if (visitorId is! String) return _bad();
    final result = await _presence.grantInvitation(
      hostOwnerId: principal.accountId,
      visitorId: visitorId,
    );
    return HostResponse.fromResult(result, (token) => {'token': token});
  }

  // ---- avatars --------------------------------------------------------------

  Future<HostResponse> _listAvatars(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final list = await _avatars.list(principal.accountId);
    return HostResponse.ok({
      'avatars': [for (final profile in list) profile.toJson()],
    });
  }

  Future<HostResponse> _createAvatar(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final json = body.value;
    if (json.keys.toSet().difference(const {'kind', 'modelId'}).isNotEmpty ||
        !json.keys.toSet().containsAll(const {'kind', 'modelId'})) {
      return _bad();
    }
    final kindRaw = json['kind'];
    final modelId = json['modelId'];
    if (kindRaw is! String || modelId is! String) return _bad();
    final kind = AvatarKind.tryParse(kindRaw);
    if (kind == null) return _bad();
    final result = await _avatars.register(
      ownerId: principal.accountId,
      kind: kind,
      modelId: modelId,
    );
    return HostResponse.fromResult(result, (profile) => profile.toJson());
  }

  Future<HostResponse> _enableAvatar(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final avatarId = request.pathParams['avatarId'] ?? '';
    final body = request.jsonObject();
    if (body is Err<Map<String, Object?>>) {
      return HostResponse.failure(body.failure);
    }
    final revision = body.value['expectedRevision'];
    if (revision is! int) return _bad();
    final result = await _avatars.enable(
      ownerId: principal.accountId,
      avatarId: avatarId,
      expectedRevision: revision,
    );
    return HostResponse.fromResult(result, (profile) => profile.toJson());
  }

  Future<HostResponse> _activeAvatar(HostRequest request) async {
    final principal = request.principal;
    if (principal == null) return _unauth();
    final result = await _avatars.active(principal.accountId);
    return HostResponse.fromResult(result, (broadcast) => broadcast.toJson());
  }
}
