/// FR-36 连续街区寻路：客户端导出 waypoint graph，宿主用 A* 计算路径。
///
/// 位置权威在宿主。这里只做纯几何寻路：边代价取三维欧氏距离，启发式取到目标的
/// 直线距离（可采纳且一致），因此总能得到最短路径且结果确定可复现。
/// 门锁/权限由 presence（拜访权威）处理，寻路本身不感知权限。
library;

import 'dart:math' as math;

import 'package:jingyu_core/jingyu_core.dart';

/// 街区图上的一个路点（waypoint）。
class Waypoint {
  const Waypoint({
    required this.id,
    required this.spaceId,
    required this.x,
    required this.y,
    required this.z,
  });

  final String id;

  /// 所属空间（别墅/小院/公共街道）。用于按空间分组导航。
  final String spaceId;
  final double x;
  final double y;
  final double z;

  double distanceTo(Waypoint other) {
    final dx = x - other.x;
    final dy = y - other.y;
    final dz = z - other.z;
    return math.sqrt(dx * dx + dy * dy + dz * dz);
  }
}

/// 一条有向/无向路点连接。默认双向（街道可来回走）。
class WaypointEdge {
  const WaypointEdge(this.from, this.to, {this.bidirectional = true});

  final String from;
  final String to;
  final bool bidirectional;
}

/// 不可变 waypoint graph：节点表 + 邻接表。
class WaypointGraph {
  WaypointGraph._(this._nodes, this._adjacency);

  final Map<String, Waypoint> _nodes;
  final Map<String, List<String>> _adjacency;

  Waypoint? node(String id) => _nodes[id];

  /// 邻居按 id 升序，保证 A* 在同代价时结果确定。
  List<String> neighbors(String id) => _adjacency[id] ?? const <String>[];

  /// 校验并构建图。重复节点、悬空边、自环、非法坐标一律 invalidArgument。
  static Result<WaypointGraph> build({
    required List<Waypoint> nodes,
    List<WaypointEdge> edges = const <WaypointEdge>[],
  }) {
    final byId = <String, Waypoint>{};
    for (final node in nodes) {
      if (node.id.isEmpty || node.id.length > 64) {
        return err(FailureCode.invalidArgument, 'bad waypoint id');
      }
      if (byId.containsKey(node.id)) {
        return err(FailureCode.invalidArgument, 'duplicate waypoint id');
      }
      if (!node.x.isFinite || !node.y.isFinite || !node.z.isFinite) {
        return err(FailureCode.invalidArgument, 'non-finite coordinate');
      }
      byId[node.id] = node;
    }
    final adjacency = <String, List<String>>{
      for (final id in byId.keys) id: <String>[],
    };
    for (final edge in edges) {
      if (edge.from == edge.to) {
        return err(FailureCode.invalidArgument, 'self loop edge');
      }
      if (!byId.containsKey(edge.from) || !byId.containsKey(edge.to)) {
        return err(FailureCode.invalidArgument, 'dangling edge');
      }
      adjacency[edge.from]!.add(edge.to);
      if (edge.bidirectional) adjacency[edge.to]!.add(edge.from);
    }
    for (final id in adjacency.keys.toList()) {
      final sorted = adjacency[id]!..sort();
      final seen = <String>{};
      adjacency[id] = [
        for (final neighbor in sorted)
          if (seen.add(neighbor)) neighbor,
      ];
    }
    return Ok(WaypointGraph._(byId, adjacency));
  }
}

/// 一条路径：路点序列 + 累计代价。起点等于终点时为单点、代价 0。
class Path {
  const Path(this.waypointIds, this.cost);

  final List<String> waypointIds;
  final double cost;

  bool get isEmpty => waypointIds.isEmpty;
}

/// A* 寻路。未知端点或不可达返回 notFound。
Result<Path> findPath(
  WaypointGraph graph, {
  required String from,
  required String to,
}) {
  final start = graph.node(from);
  final goal = graph.node(to);
  if (start == null || goal == null) {
    return err(FailureCode.notFound, 'waypoint not found');
  }
  if (from == to) return Ok(Path(<String>[from], 0));

  final gScore = <String, double>{from: 0};
  final fScore = <String, double>{from: start.distanceTo(goal)};
  final cameFrom = <String, String>{};
  final open = <String>{from};
  final closed = <String>{};

  while (open.isNotEmpty) {
    String? current;
    for (final id in open) {
      if (current == null) {
        current = id;
        continue;
      }
      final f = fScore[id] ?? double.infinity;
      final best = fScore[current] ?? double.infinity;
      final better = f < best - 1e-12;
      final tie = (f - best).abs() <= 1e-12 && id.compareTo(current) < 0;
      if (better || tie) current = id;
    }
    final node = current!;
    if (node == to) {
      final ids = <String>[node];
      var walk = node;
      while (cameFrom.containsKey(walk)) {
        walk = cameFrom[walk]!;
        ids.add(walk);
      }
      return Ok(Path(ids.reversed.toList(), gScore[to] ?? 0));
    }
    open.remove(node);
    closed.add(node);
    final currentWp = graph.node(node)!;
    for (final neighborId in graph.neighbors(node)) {
      if (closed.contains(neighborId)) continue;
      final neighborWp = graph.node(neighborId)!;
      final tentative =
          (gScore[node] ?? double.infinity) + currentWp.distanceTo(neighborWp);
      final known = gScore[neighborId];
      if (known == null || tentative < known - 1e-12) {
        cameFrom[neighborId] = node;
        gScore[neighborId] = tentative;
        fScore[neighborId] = tentative + neighborWp.distanceTo(goal);
        open.add(neighborId);
      }
    }
  }
  return err(FailureCode.notFound, 'no path');
}
