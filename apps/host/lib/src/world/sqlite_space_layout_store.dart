/// FR-35 布局存储的 SQLite 实现。与 `InMemorySpaceLayoutStore` 共用同一组契约测试。
///
/// 版本号仍用乐观并发（CAS）：读取当前版本与写入在同一事务内完成，避免竞态覆盖。
library;

import 'package:jingyu_core/jingyu_core.dart';

import '../storage/database.dart';
import 'layout_store.dart';

class SqliteSpaceLayoutStore implements SpaceLayoutStore {
  SqliteSpaceLayoutStore({
    required this.database,
    this.clock = const SystemClock(),
  });

  final Database database;
  final Clock clock;

  @override
  Future<Result<SpaceLayout>> get(String spaceId) async {
    final String id;
    try {
      id = validateId(spaceId, kind: 'space');
    } on FormatException {
      return err(FailureCode.invalidArgument, 'bad space id');
    }
    final rows = await database.query(
      'SELECT version, style, main_color, updated_at FROM world_space_layouts WHERE space_id = ?',
      [id],
    );
    if (rows.isEmpty) return err(FailureCode.notFound, 'layout not found');
    final row = rows.single;
    final version = row['version'];
    final styleRaw = row['style'];
    final updatedRaw = row['updated_at'];
    final mainColor = row['main_color'];
    if (version is! int || styleRaw is! String || updatedRaw is! String) {
      return err(FailureCode.internal, 'corrupt layout row');
    }
    final style = RoomStyle.tryParse(styleRaw);
    final updated = DateTime.tryParse(updatedRaw);
    if (style == null ||
        updated == null ||
        !updated.isUtc ||
        (mainColor != null && mainColor is! String)) {
      return err(FailureCode.internal, 'corrupt layout row');
    }
    final roomRows = await database.query(
      'SELECT room_id, name FROM world_space_rooms WHERE space_id = ? ORDER BY sort_order',
      [id],
    );
    final rooms = <RoomLayout>[];
    for (final roomRow in roomRows) {
      final roomId = roomRow['room_id'];
      final name = roomRow['name'];
      if (roomId is! String || name is! String) {
        return err(FailureCode.internal, 'corrupt room row');
      }
      final furnitureRows = await database.query(
        'SELECT item_id, asset_id, x, y, z, rotation FROM world_room_furniture '
        'WHERE space_id = ? AND room_id = ? ORDER BY item_id',
        [id, roomId],
      );
      final furniture = <FurniturePlacement>[];
      for (final itemRow in furnitureRows) {
        final itemId = itemRow['item_id'];
        final assetId = itemRow['asset_id'];
        final x = itemRow['x'];
        final y = itemRow['y'];
        final z = itemRow['z'];
        final rotation = itemRow['rotation'];
        if (itemId is! String ||
            assetId is! String ||
            x is! num ||
            y is! num ||
            z is! num ||
            rotation is! num) {
          return err(FailureCode.internal, 'corrupt furniture row');
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
      rooms.add(
        RoomLayout(
          roomId: roomId,
          name: name,
          furniture: List<FurniturePlacement>.unmodifiable(furniture),
        ),
      );
    }
    return Ok(
      SpaceLayout(
        spaceId: id,
        version: version,
        style: style,
        mainColor: mainColor as String?,
        rooms: List<RoomLayout>.unmodifiable(rooms),
        updatedAt: updated,
      ),
    );
  }

  Failure? _validate(
    int expectedVersion,
    String? mainColor,
    List<RoomLayout> rooms,
  ) {
    if (expectedVersion < 0) {
      return const Failure(
        FailureCode.invalidArgument,
        'expectedVersion must be >= 0',
      );
    }
    if (mainColor != null && (mainColor.isEmpty || mainColor.length > 32)) {
      return const Failure(FailureCode.invalidArgument, 'bad mainColor');
    }
    if (rooms.isEmpty) {
      return const Failure(
        FailureCode.invalidArgument,
        'layout needs at least one room',
      );
    }
    final roomIds = <String>{};
    for (final room in rooms) {
      if (room.roomId.isEmpty || room.roomId.length > 64) {
        return const Failure(FailureCode.invalidArgument, 'bad room id');
      }
      if (!roomIds.add(room.roomId)) {
        return const Failure(FailureCode.invalidArgument, 'duplicate room id');
      }
      if (room.name.length > 128) {
        return const Failure(FailureCode.invalidArgument, 'bad room name');
      }
      final itemIds = <String>{};
      for (final item in room.furniture) {
        if (item.itemId.isEmpty || item.itemId.length > 64) {
          return const Failure(
            FailureCode.invalidArgument,
            'bad furniture item id',
          );
        }
        if (!itemIds.add(item.itemId)) {
          return const Failure(
            FailureCode.invalidArgument,
            'duplicate furniture item id',
          );
        }
        if (item.assetId.isEmpty || item.assetId.length > 128) {
          return const Failure(
            FailureCode.invalidArgument,
            'bad furniture asset id',
          );
        }
        if (!item.x.isFinite ||
            !item.y.isFinite ||
            !item.z.isFinite ||
            !item.rotation.isFinite) {
          return const Failure(
            FailureCode.invalidArgument,
            'non-finite furniture pose',
          );
        }
      }
    }
    return null;
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
    final invalid = _validate(expectedVersion, mainColor, rooms);
    if (invalid != null) return Err<SpaceLayout>(invalid);
    final now = clock.now().toUtc();
    return database.transaction((tx) async {
      final head = await tx.query(
        'SELECT version FROM world_space_layouts WHERE space_id = ?',
        [id],
      );
      final currentVersion = head.isEmpty ? 0 : head.single['version'] as int;
      if (expectedVersion != currentVersion) {
        return err(FailureCode.conflict, 'layout version mismatch');
      }
      final nextVersion = currentVersion + 1;
      await tx.execute(
        'INSERT INTO world_space_layouts(space_id, version, style, main_color, updated_at) '
        'VALUES(?,?,?,?,?) '
        'ON CONFLICT(space_id) DO UPDATE SET '
        'version=excluded.version, style=excluded.style, '
        'main_color=excluded.main_color, updated_at=excluded.updated_at',
        [id, nextVersion, style.wire, mainColor, now.toIso8601String()],
      );
      await tx.execute('DELETE FROM world_space_rooms WHERE space_id = ?', [
        id,
      ]);
      await tx.execute('DELETE FROM world_room_furniture WHERE space_id = ?', [
        id,
      ]);
      for (var i = 0; i < rooms.length; i++) {
        final room = rooms[i];
        await tx.execute(
          'INSERT INTO world_space_rooms(space_id, room_id, name, sort_order) '
          'VALUES(?,?,?,?)',
          [id, room.roomId, room.name, i],
        );
        for (final item in room.furniture) {
          await tx.execute(
            'INSERT INTO world_room_furniture('
            'space_id, room_id, item_id, asset_id, x, y, z, rotation'
            ') VALUES(?,?,?,?,?,?,?,?)',
            [
              id,
              room.roomId,
              item.itemId,
              item.assetId,
              item.x,
              item.y,
              item.z,
              item.rotation,
            ],
          );
        }
      }
      return Ok(
        SpaceLayout(
          spaceId: id,
          version: nextVersion,
          style: style,
          mainColor: mainColor,
          rooms: List<RoomLayout>.unmodifiable([
            for (final room in rooms)
              RoomLayout(
                roomId: room.roomId,
                name: room.name,
                furniture: List<FurniturePlacement>.unmodifiable(
                  room.furniture,
                ),
              ),
          ]),
          updatedAt: now,
        ),
      );
    });
  }
}
