/// 模块注册表：依赖排序、循环检测、按序启动与逆序停止。
library;

import 'host_services.dart';
import 'module.dart';
import 'router.dart';

/// 模块注册表。
class Registry {
  Registry({HostServices? services, Router? router})
      : services = services ?? HostServices(),
        router = router ?? Router();

  final HostServices services;
  final Router router;

  final Map<String, HostModule> _modules = <String, HostModule>{};
  List<HostModule>? _order;
  final List<HostModule> _started = <HostModule>[];

  /// 注册模块。必须在 [boot] 之前调用。
  void register(HostModule module) {
    if (_order != null) {
      throw StateError('注册表已启动，不能再注册模块 ${module.name}');
    }
    if (_modules.containsKey(module.name)) {
      throw StateError('模块名重复：${module.name}');
    }
    _modules[module.name] = module;
  }

  /// 依赖拓扑序。缺依赖或存在循环时抛 [StateError]。
  List<HostModule> resolveOrder() {
    final order = <HostModule>[];
    final state = <String, int>{}; // 0 未访问，1 访问中，2 完成

    void visit(String name, List<String> path) {
      final module = _modules[name];
      if (module == null) {
        throw StateError('模块 ${path.last} 依赖未注册的模块 $name');
      }
      final current = state[name] ?? 0;
      if (current == 2) return;
      if (current == 1) {
        throw StateError('模块依赖循环：${[...path, name].join(' -> ')}');
      }
      state[name] = 1;
      for (final dep in module.dependsOn) {
        visit(dep, [...path, name]);
      }
      state[name] = 2;
      order.add(module);
    }

    // 无依赖约束时保持注册顺序，使启动顺序可预测。
    for (final name in _modules.keys) {
      visit(name, const <String>[]);
    }
    return order;
  }

  /// 按依赖顺序 configure → mount → start。
  ///
  /// 任一模块 start 失败时，已启动的模块按逆序停止后再抛出原错误。
  Future<void> boot() async {
    final order = resolveOrder();
    _order = order;
    for (final module in order) {
      await module.configure(services);
    }
    for (final module in order) {
      router.currentOwner = module.name;
      module.mount(router);
    }
    router.currentOwner = 'host';
    try {
      for (final module in order) {
        await module.start();
        _started.add(module);
      }
    } catch (_) {
      await shutdown();
      rethrow;
    }
  }

  /// 逆序停止。单个模块停止失败不阻断其余模块。
  Future<List<Object>> shutdown() async {
    final errors = <Object>[];
    for (final module in _started.reversed.toList()) {
      try {
        await module.stop();
      } catch (error) {
        errors.add(error);
      }
    }
    _started.clear();
    return errors;
  }

  /// 已注册模块名（依赖顺序；未启动时按注册顺序）。
  List<String> get moduleNames =>
      (_order ?? _modules.values).map((m) => m.name).toList();
}
