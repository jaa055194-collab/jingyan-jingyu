/// SpaceLayoutStore 契约测试（内存实现必须通过）。
///
/// FR-35：每个用户/AI 拥有独立别墅 + 小院，家具布局存服务端版本号；
/// 街区不实时物理同步，只同步家具版本。版本号用乐观并发（CAS）推进，
/// 保存后客户端按版本号判断是否需要重载布局。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/layout_store.dart';
import 'package:test/test.dart';

RoomLayout _room(String id, {String name = 'Room', String item = 'sofa'}) =>
    RoomLayout(
      roomId: id,
      name: name,
      furniture: [
        FurniturePlacement(
          itemId: '${id}_$item',
          assetId: '${item}_01',
          x: 1,
          y: 0,
          z: 2,
          rotation: 0.5,
        ),
      ],
    );

void spaceLayoutStoreContract(
  String label,
  ({SpaceLayoutStore store, FakeClock clock}) Function() create,
) {
  group('SpaceLayoutStore 契约 [$label]', () {
    late SpaceLayoutStore store;
    late FakeClock clock;

    setUp(() {
      final fixture = create();
      store = fixture.store;
      clock = fixture.clock;
    });

    test('首次保存从版本 0 建到 1 并记录注入时钟', () async {
      final saved = (await store.save(
        spaceId: 'villa_a',
        expectedVersion: 0,
        style: RoomStyle.seaside,
        mainColor: '#11aa33',
        rooms: [_room('living')],
      )).value;
      expect(saved.spaceId, 'villa_a');
      expect(saved.version, 1);
      expect(saved.style, RoomStyle.seaside);
      expect(saved.mainColor, '#11aa33');
      expect(saved.rooms.single.roomId, 'living');
      expect(saved.rooms.single.furniture.single.assetId, 'sofa_01');
      expect(saved.updatedAt, clock.now().toUtc());

      final fetched = (await store.get('villa_a')).value;
      expect(fetched.version, 1);
      expect(fetched.rooms.single.furniture.single.itemId, 'living_sofa');
    });

    test('版本号不匹配返回 conflict 且不覆盖已有布局', () async {
      await store.save(
        spaceId: 'villa_a',
        expectedVersion: 0,
        style: RoomStyle.forest,
        rooms: [_room('living')],
      );
      // A second writer that read version 1 already advanced the row.
      final staleResult = await store.save(
        spaceId: 'villa_a',
        expectedVersion: 0,
        style: RoomStyle.modern,
        rooms: [_room('bedroom')],
      );
      expect(staleResult.isErr, isTrue);
      expect(staleResult.failureOrNull?.code, FailureCode.conflict);
      final current = (await store.get('villa_a')).value;
      expect(current.version, 1);
      expect(current.style, RoomStyle.forest);
      expect(current.rooms.single.roomId, 'living');
    });

    test('正确版本号保存后版本递增且时间前进', () async {
      await store.save(
        spaceId: 'villa_a',
        expectedVersion: 0,
        style: RoomStyle.seaside,
        rooms: [_room('living')],
      );
      clock.advance(const Duration(minutes: 5));
      final updated = (await store.save(
        spaceId: 'villa_a',
        expectedVersion: 1,
        style: RoomStyle.modern,
        rooms: [_room('living'), _room('bedroom')],
      )).value;
      expect(updated.version, 2);
      expect(updated.style, RoomStyle.modern);
      expect(updated.rooms.length, 2);
      expect(updated.updatedAt, clock.now().toUtc());
    });

    test('未知空间返回 notFound', () async {
      final result = await store.get('missing');
      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.code, FailureCode.notFound);
    });

    test('非法入参返回 invalidArgument', () async {
      // Invalid space id.
      expect(
        (await store.save(
          spaceId: 'bad id',
          expectedVersion: 0,
          style: RoomStyle.seaside,
          rooms: [_room('living')],
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      // Negative expected version.
      expect(
        (await store.save(
          spaceId: 'villa_a',
          expectedVersion: -1,
          style: RoomStyle.seaside,
          rooms: [_room('living')],
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      // Empty room list.
      expect(
        (await store.save(
          spaceId: 'villa_a',
          expectedVersion: 0,
          style: RoomStyle.seaside,
          rooms: const [],
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      // Duplicate room ids.
      expect(
        (await store.save(
          spaceId: 'villa_a',
          expectedVersion: 0,
          style: RoomStyle.seaside,
          rooms: [_room('living'), _room('living')],
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      // Duplicate furniture item ids within a room.
      expect(
        (await store.save(
          spaceId: 'villa_a',
          expectedVersion: 0,
          style: RoomStyle.seaside,
          rooms: [
            RoomLayout(
              roomId: 'living',
              name: 'Living',
              furniture: const [
                FurniturePlacement(itemId: 'dup', assetId: 'a'),
                FurniturePlacement(itemId: 'dup', assetId: 'b'),
              ],
            ),
          ],
        )).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });
  });
}
