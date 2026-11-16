/// FR-36 连续街区寻路：客户端导出 waypoint graph，宿主用 A* 计算路径。
///
/// 位置权威在宿主；边代价按三维欧氏距离，启发式用直线距离（可采纳且一致），
/// 因此结果确定、可复现。这里只测纯几何寻路，门锁与权限在 presence 处理。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host/src/world/pathfinding.dart';
import 'package:test/test.dart';

WaypointGraph _build({
  required List<Waypoint> nodes,
  List<WaypointEdge> edges = const [],
}) {
  final result = WaypointGraph.build(nodes: nodes, edges: edges);
  if (result.isErr) {
    throw StateError('fixture graph invalid: ${result.failureOrNull}');
  }
  return result.value;
}

Waypoint _wp(String id, double x, [double z = 0]) =>
    Waypoint(id: id, spaceId: 'street', x: x, y: 0, z: z);

void main() {
  group('A* 街区寻路', () {
    test('直线图返回最短路径与累计代价', () {
      final graph = _build(
        nodes: [_wp('a', 0), _wp('b', 3), _wp('c', 6)],
        edges: const [WaypointEdge('a', 'b'), WaypointEdge('b', 'c')],
      );
      final path = findPath(graph, from: 'a', to: 'c').value;
      expect(path.waypointIds, ['a', 'b', 'c']);
      expect(path.cost, closeTo(6, 1e-9));
    });

    test('存在两条路时选择总代价更短的一条', () {
      final graph = _build(
        nodes: [_wp('s', 0), _wp('short', 2), _wp('t', 4), _wp('detour', 2, 3)],
        edges: const [
          WaypointEdge('s', 'short'),
          WaypointEdge('short', 't'),
          WaypointEdge('s', 'detour'),
          WaypointEdge('detour', 't'),
        ],
      );
      final path = findPath(graph, from: 's', to: 't').value;
      expect(path.waypointIds, ['s', 'short', 't']);
      expect(path.cost, closeTo(4, 1e-9));
    });

    test('环状图不会死循环并返回可行路径', () {
      final graph = _build(
        nodes: [_wp('a', 0), _wp('b', 1), _wp('c', 2)],
        edges: const [
          WaypointEdge('a', 'b'),
          WaypointEdge('b', 'c'),
          WaypointEdge('c', 'a'),
        ],
      );
      final path = findPath(graph, from: 'a', to: 'c').value;
      expect(path.waypointIds.first, 'a');
      expect(path.waypointIds.last, 'c');
      expect(path.cost, closeTo(2, 1e-9));
    });

    test('不可达返回 notFound', () {
      final graph = _build(
        nodes: [_wp('a', 0), _wp('b', 3), _wp('island', 100)],
        edges: const [WaypointEdge('a', 'b')],
      );
      final result = findPath(graph, from: 'a', to: 'island');
      expect(result.isErr, isTrue);
      expect(result.failureOrNull?.code, FailureCode.notFound);
    });

    test('未知端点返回 notFound', () {
      final graph = _build(
        nodes: [_wp('a', 0), _wp('b', 3)],
        edges: const [WaypointEdge('a', 'b')],
      );
      expect(
        findPath(graph, from: 'a', to: 'ghost').failureOrNull?.code,
        FailureCode.notFound,
      );
      expect(
        findPath(graph, from: 'ghost', to: 'b').failureOrNull?.code,
        FailureCode.notFound,
      );
    });

    test('起点等于终点返回单点零代价', () {
      final graph = _build(nodes: [_wp('a', 0)], edges: const []);
      final path = findPath(graph, from: 'a', to: 'a').value;
      expect(path.waypointIds, ['a']);
      expect(path.cost, 0);
    });

    test('有向边不可逆向通行', () {
      final graph = _build(
        nodes: [_wp('a', 0), _wp('b', 3)],
        edges: const [WaypointEdge('a', 'b', bidirectional: false)],
      );
      expect(findPath(graph, from: 'a', to: 'b').isOk, isTrue);
      expect(
        findPath(graph, from: 'b', to: 'a').failureOrNull?.code,
        FailureCode.notFound,
      );
    });

    test('构建校验重复节点与悬空边', () {
      expect(
        WaypointGraph.build(
          nodes: [_wp('a', 0), _wp('a', 1)],
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      expect(
        WaypointGraph.build(
          nodes: [_wp('a', 0)],
          edges: const [WaypointEdge('a', 'missing')],
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
      // Self loop edge is invalid input.
      expect(
        WaypointGraph.build(
          nodes: [_wp('a', 0)],
          edges: const [WaypointEdge('a', 'a')],
        ).failureOrNull?.code,
        FailureCode.invalidArgument,
      );
    });
  });
}
