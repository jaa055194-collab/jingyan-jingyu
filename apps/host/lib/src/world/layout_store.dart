/// FR-35 世界结构：每个用户/AI 拥有独立别墅 + 小院，所有人在同一条街区。
///
/// 街区外景静态共享，别墅/小院实例按需加载，家具布局存服务端版本号。
/// 不做整条街的实时物理同步，只同步 presence、拜访、门锁、家具版本。
///
/// 版本号用乐观并发（CAS）：调用方带上读到的 [SpaceLayout.version]，
/// 服务端不匹配即返回 conflict，客户端据此重新拉取布局。
library;

import 'package:jingyu_core/jingyu_core.dart';

/// 房间风格预设，对应 `docs/plugins/02-assets.md` §2 的五个方向（C-13）。
enum RoomStyle {
  seaside('seaside'),
  forest('forest'),
  modern('modern'),
  cyber('cyber'),
  chineseCourtyard('chinese_courtyard');

  const RoomStyle(this.wire);

  /// 线协议值。
  final String wire;

  static RoomStyle? tryParse(String raw) {
    for (final style in values) {
      if (style.wire == raw) return style;
    }
    return null;
  }
}

/// 单件家具摆放。[assetId] 只引用宿主本地素材目录，绝不包含可执行内容。
class FurniturePlacement {
  const FurniturePlacement({
    required this.itemId,
    required this.assetId,
    this.x = 0,
    this.y = 0,
    this.z = 0,
    this.rotation = 0,
  });

  final String itemId;
  final String assetId;
  final double x;
  final double y;
  final double z;
  final double rotation;

  Map<String, Object?> toJson() => {
    'itemId': itemId,
    'assetId': assetId,
    'x': x,
    'y': y,
    'z': z,
    'rotation': rotation,
  };
}

/// 一个房间的布局：家具摆放列表，顺序稳定即渲染顺序。
class RoomLayout {
  const RoomLayout({
    required this.roomId,
    required this.name,
    required this.furniture,
  });

  final String roomId;
  final String name;
  final List<FurniturePlacement> furniture;

  Map<String, Object?> toJson() => {
    'roomId': roomId,
    'name': name,
    'furniture': [for (final item in furniture) item.toJson()],
  };
}

/// space_layout：一份房间布局 + 版本号（FR-35）。
class SpaceLayout {
  const SpaceLayout({
    required this.spaceId,
    required this.version,
    required this.style,
    required this.mainColor,
    required this.rooms,
    required this.updatedAt,
  });

  /// 空间标识（别墅主人账号 id）。
  final String spaceId;
  final int version;
  final RoomStyle style;
  final String? mainColor;
  final List<RoomLayout> rooms;
  final DateTime updatedAt;

  Map<String, Object?> toJson() => {
    'spaceId': spaceId,
    'version': version,
    'style': style.wire,
    'mainColor': mainColor,
    'rooms': [for (final room in rooms) room.toJson()],
    'updatedAt': updatedAt.toUtc().toIso8601String(),
  };
}

/// 布局存储契约。持久化实现（SQLite）必须通过同一组契约测试。
abstract interface class SpaceLayoutStore {
  /// 读取当前布局；未知空间返回 notFound。
  Future<Result<SpaceLayout>> get(String spaceId);

  /// 保存布局。[expectedVersion] 为读到的版本号，首次创建传 0。
  /// 版本不匹配返回 conflict 且不覆盖；成功返回版本 +1 的新布局。
  Future<Result<SpaceLayout>> save({
    required String spaceId,
    required int expectedVersion,
    required RoomStyle style,
    String? mainColor,
    required List<RoomLayout> rooms,
  });
}

/// 内存实现。
class InMemorySpaceLayoutStore implements SpaceLayoutStore {
  InMemorySpaceLayoutStore({this.clock = const SystemClock()});

  final Clock clock;
  final Map<String, SpaceLayout> _byId = <String, SpaceLayout>{};

  @override
  Future<Result<SpaceLayout>> get(String spaceId) async {
    final String id;
    try {
      id = validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad space id');
    }
    final layout = _byId[id];
    if (layout == null) return err(FailureCode.notFound, 'layout not found');
    return Ok(layout);
  }

  @override
  Future<Result<SpaceLayout>> save({
    required String spaceId,
    required int expectedVersion,
    required RoomStyle style,
    String? mainColor,
    required List<RoomLayout> rooms,
  }) async {
    final String id;
    try {
      id = validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad space id');
    }
    if (expectedVersion < 0) {
      return err(FailureCode.invalidArgument, 'expectedVersion must be >= 0');
    }
    final color = mainColor;
    if (color != null && (color.isEmpty || color.length > 32)) {
      return err(FailureCode.invalidArgument, 'bad mainColor');
    }
    if (rooms.isEmpty) {
      return err(FailureCode.invalidArgument, 'layout needs at least one room');
    }
    final roomIds = <String>{};
    for (final room in rooms) {
      if (room.roomId.isEmpty || room.roomId.length > 64) {
        return err(FailureCode.invalidArgument, 'bad room id');
      }
      if (!roomIds.add(room.roomId)) {
        return err(FailureCode.invalidArgument, 'duplicate room id');
      }
      if (room.name.length > 128) {
        return err(FailureCode.invalidArgument, 'bad room name');
      }
      final itemIds = <String>{};
      for (final item in room.furniture) {
        if (item.itemId.isEmpty || item.itemId.length > 64) {
          return err(FailureCode.invalidArgument, 'bad furniture item id');
        }
        if (!itemIds.add(item.itemId)) {
          return err(
            FailureCode.invalidArgument,
            'duplicate furniture item id',
          );
        }
        if (item.assetId.isEmpty || item.assetId.length > 128) {
          return err(FailureCode.invalidArgument, 'bad furniture asset id');
        }
        if (!item.x.isFinite ||
            !item.y.isFinite ||
            !item.z.isFinite ||
            !item.rotation.isFinite) {
          return err(FailureCode.invalidArgument, 'non-finite furniture pose');
        }
      }
    }

    final current = _byId[id];
    final currentVersion = current?.version ?? 0;
    if (expectedVersion != currentVersion) {
      return err(FailureCode.conflict, 'layout version mismatch');
    }
    final saved = SpaceLayout(
      spaceId: id,
      version: currentVersion + 1,
      style: style,
      mainColor: color,
      rooms: List<RoomLayout>.unmodifiable([
        for (final room in rooms)
          RoomLayout(
            roomId: room.roomId,
            name: room.name,
            furniture: List<FurniturePlacement>.unmodifiable(room.furniture),
          ),
      ]),
      updatedAt: clock.now().toUtc(),
    );
    _byId[id] = saved;
    return Ok(saved);
  }
}
