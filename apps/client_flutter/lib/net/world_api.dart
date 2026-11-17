library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_protocol/jingyu_protocol.dart';

import 'host_connection.dart';

/// Typed, read-only adapters for the merged host world routes.
///
/// This layer performs no UI, no rendering, no 3D work and holds no secrets. It
/// only projects host JSON into validated value objects. Authentication renewal
/// (bounded one-shot 401 replay) is inherited from [HostConnection]; this class
/// adds no retry of its own.

/// One furniture placement inside a room layout.
class WorldFurniturePlacement {
  const WorldFurniturePlacement({
    required this.itemId,
    required this.assetId,
    required this.x,
    required this.y,
    required this.z,
    required this.rotation,
  });

  final String itemId;
  final String assetId;
  final double x;
  final double y;
  final double z;
  final double rotation;

  factory WorldFurniturePlacement.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid furniture');
    final itemId = value['itemId'];
    final assetId = value['assetId'];
    final x = value['x'];
    final y = value['y'];
    final z = value['z'];
    final rotation = value['rotation'];
    if (itemId is! String ||
        itemId.isEmpty ||
        itemId.length > 64 ||
        assetId is! String ||
        assetId.isEmpty ||
        assetId.length > 128 ||
        x is! num ||
        y is! num ||
        z is! num ||
        rotation is! num ||
        !x.isFinite ||
        !y.isFinite ||
        !z.isFinite ||
        !rotation.isFinite) {
      throw const FormatException('Invalid furniture');
    }
    return WorldFurniturePlacement(
      itemId: itemId,
      assetId: assetId,
      x: x.toDouble(),
      y: y.toDouble(),
      z: z.toDouble(),
      rotation: rotation.toDouble(),
    );
  }
}

/// One room inside a space layout.
class WorldRoomLayout {
  const WorldRoomLayout({
    required this.roomId,
    required this.name,
    required this.furniture,
  });

  final String roomId;
  final String name;
  final List<WorldFurniturePlacement> furniture;

  factory WorldRoomLayout.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid room');
    final roomId = value['roomId'];
    final name = value['name'];
    final furniture = value['furniture'];
    if (roomId is! String ||
        roomId.isEmpty ||
        roomId.length > 64 ||
        name is! String ||
        name.length > 128 ||
        furniture is! List) {
      throw const FormatException('Invalid room');
    }
    return WorldRoomLayout(
      roomId: roomId,
      name: name,
      furniture: List<WorldFurniturePlacement>.unmodifiable(
        furniture.map(WorldFurniturePlacement.fromJson),
      ),
    );
  }
}

/// A host-authoritative space layout with a monotonic version.
class WorldSpaceLayout {
  const WorldSpaceLayout({
    required this.spaceId,
    required this.version,
    required this.style,
    required this.mainColor,
    required this.rooms,
    required this.updatedAt,
  });

  final String spaceId;
  final int version;
  final String style;
  final String? mainColor;
  final List<WorldRoomLayout> rooms;
  final DateTime updatedAt;

  factory WorldSpaceLayout.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid layout');
    final spaceId = value['spaceId'];
    final version = value['version'];
    final style = value['style'];
    final mainColor = value['mainColor'];
    final rooms = value['rooms'];
    final updatedAt = value['updatedAt'];
    final updated = updatedAt is String ? DateTime.tryParse(updatedAt) : null;
    if (spaceId is! String ||
        spaceId.isEmpty ||
        spaceId.length > 64 ||
        version is! int ||
        version < 1 ||
        style is! String ||
        style.isEmpty ||
        style.length > 32 ||
        (mainColor != null && mainColor is! String) ||
        rooms is! List ||
        updated == null ||
        !updated.isUtc) {
      throw const FormatException('Invalid layout');
    }
    return WorldSpaceLayout(
      spaceId: spaceId,
      version: version,
      style: style,
      mainColor: mainColor as String?,
      rooms: List<WorldRoomLayout>.unmodifiable(
        rooms.map(WorldRoomLayout.fromJson),
      ),
      updatedAt: updated,
    );
  }
}

/// One resident's presence snapshot (host is the position authority).
class WorldPresenceRecord {
  const WorldPresenceRecord({
    required this.residentId,
    required this.spaceId,
    required this.x,
    required this.y,
    required this.z,
    required this.motion,
    required this.updatedAt,
  });

  final String residentId;
  final String spaceId;
  final double x;
  final double y;
  final double z;
  final String motion;
  final DateTime updatedAt;

  static const Set<String> _motions = {'idle', 'walk', 'sit', 'wave'};

  factory WorldPresenceRecord.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid presence');
    final residentId = value['residentId'];
    final spaceId = value['spaceId'];
    final position = value['position'];
    final motion = value['motion'];
    final updatedAt = value['updatedAt'];
    if (residentId is! String ||
        residentId.isEmpty ||
        residentId.length > 64 ||
        spaceId is! String ||
        spaceId.isEmpty ||
        spaceId.length > 64 ||
        position is! Map ||
        motion is! String ||
        !_motions.contains(motion) ||
        updatedAt is! String) {
      throw const FormatException('Invalid presence');
    }
    final x = position['x'];
    final y = position['y'];
    final z = position['z'];
    final updated = DateTime.tryParse(updatedAt);
    if (x is! num ||
        y is! num ||
        z is! num ||
        !x.isFinite ||
        !y.isFinite ||
        !z.isFinite ||
        updated == null ||
        !updated.isUtc) {
      throw const FormatException('Invalid presence');
    }
    return WorldPresenceRecord(
      residentId: residentId,
      spaceId: spaceId,
      x: x.toDouble(),
      y: y.toDouble(),
      z: z.toDouble(),
      motion: motion,
      updatedAt: updated,
    );
  }
}

/// A registered avatar reference (no model bytes or paths).
class WorldAvatarProfile {
  const WorldAvatarProfile({
    required this.avatarId,
    required this.ownerId,
    required this.kind,
    required this.modelId,
    required this.profileRev,
    required this.updatedAt,
  });

  final String avatarId;
  final String ownerId;
  final String kind;
  final String modelId;
  final int profileRev;
  final DateTime updatedAt;

  static const Set<String> _kinds = {'vrm', 'live2d'};

  factory WorldAvatarProfile.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid avatar');
    final avatarId = value['avatarId'];
    final ownerId = value['ownerId'];
    final kind = value['kind'];
    final modelId = value['modelId'];
    final profileRev = value['profileRev'];
    final updatedAt = value['updatedAt'];
    final updated = updatedAt is String ? DateTime.tryParse(updatedAt) : null;
    if (avatarId is! String ||
        avatarId.isEmpty ||
        avatarId.length > 64 ||
        ownerId is! String ||
        ownerId.isEmpty ||
        ownerId.length > 64 ||
        kind is! String ||
        !_kinds.contains(kind) ||
        modelId is! String ||
        modelId.isEmpty ||
        modelId.length > 128 ||
        profileRev is! int ||
        profileRev < 1 ||
        updated == null ||
        !updated.isUtc) {
      throw const FormatException('Invalid avatar');
    }
    return WorldAvatarProfile(
      avatarId: avatarId,
      ownerId: ownerId,
      kind: kind,
      modelId: modelId,
      profileRev: profileRev,
      updatedAt: updated,
    );
  }
}

/// The active avatar broadcast reference for this device.
class WorldAvatarActive {
  const WorldAvatarActive({
    required this.modelId,
    required this.profileRev,
    required this.kind,
  });

  final String modelId;
  final int profileRev;
  final String kind;

  static const Set<String> _kinds = {'vrm', 'live2d'};

  factory WorldAvatarActive.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('Invalid active avatar');
    final modelId = value['modelId'];
    final profileRev = value['profileRev'];
    final kind = value['kind'];
    if (modelId is! String ||
        modelId.isEmpty ||
        modelId.length > 128 ||
        profileRev is! int ||
        profileRev < 1 ||
        kind is! String ||
        !_kinds.contains(kind)) {
      throw const FormatException('Invalid active avatar');
    }
    return WorldAvatarActive(
      modelId: modelId,
      profileRev: profileRev,
      kind: kind,
    );
  }
}

/// Read-only world API. No UI, no rendering, no secret handling.
class WorldApi {
  WorldApi(this.connection);

  final HostConnection connection;

  String _spaceId(String raw) {
    try {
      return validateId(raw, kind: 'space');
    } on FormatException {
      throw const FormatException('空间标识非法');
    }
  }

  /// GET host-authoritative layout for one space.
  Future<WorldSpaceLayout> layout(String spaceId) async {
    final id = _spaceId(spaceId);
    try {
      final json = await connection.request(
        'GET',
        Routes.worldSpaceLayout.replaceFirst(
          '{spaceId}',
          Uri.encodeComponent(id),
        ),
      );
      return WorldSpaceLayout.fromJson(json);
    } on FormatException {
      throw const FormatException('世界布局响应无效');
    }
  }

  /// GET presence snapshots for one space.
  Future<List<WorldPresenceRecord>> presence(String spaceId) async {
    final id = _spaceId(spaceId);
    try {
      final json = await connection.request(
        'GET',
        Routes.worldSpacePresence.replaceFirst(
          '{spaceId}',
          Uri.encodeComponent(id),
        ),
      );
      final positions = json['positions'];
      if (positions is! List) throw const FormatException('Invalid presence');
      return List<WorldPresenceRecord>.unmodifiable(
        positions.map(WorldPresenceRecord.fromJson),
      );
    } on FormatException {
      throw const FormatException('世界位置响应无效');
    }
  }

  /// GET avatar references for this owner/device.
  Future<List<WorldAvatarProfile>> avatars() async {
    try {
      final json = await connection.request('GET', Routes.worldAvatars);
      final avatars = json['avatars'];
      if (avatars is! List) throw const FormatException('Invalid avatars');
      return List<WorldAvatarProfile>.unmodifiable(
        avatars.map(WorldAvatarProfile.fromJson),
      );
    } on FormatException {
      throw const FormatException('形象列表响应无效');
    }
  }

  /// GET the active avatar reference for this owner/device.
  Future<WorldAvatarActive> activeAvatar() async {
    try {
      final json = await connection.request('GET', Routes.worldAvatarActive);
      return WorldAvatarActive.fromJson(json);
    } on FormatException {
      throw const FormatException('当前形象响应无效');
    }
  }
}
