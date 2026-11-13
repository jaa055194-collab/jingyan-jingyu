/// 模块间共享服务的登记处（类型键的依赖容器）。
library;

/// 服务容器。
///
/// 规则：
/// * 一个接口类型只能登记一次，重复登记直接抛错（避免两个模块悄悄覆盖对方）；
/// * 取不到服务时抛 [StateError]，并提示应在 `dependsOn` 里声明依赖；
/// * 登记的应当是**接口**（abstract class），不是实现类，
///   这样插件可以替换实现而调用方无感。
class HostServices {
  final Map<Type, Object> _services = <Type, Object>{};
  final Map<Type, String> _owners = <Type, String>{};

  /// 登记服务。[owner] 为登记它的模块名，用于报错与诊断。
  void provide<T extends Object>(T service, {required String owner}) {
    if (_services.containsKey(T)) {
      throw StateError('服务 $T 已由模块 ${_owners[T]} 登记，$owner 不能重复登记');
    }
    _services[T] = service;
    _owners[T] = owner;
  }

  /// 取服务。
  T get<T extends Object>() {
    final service = _services[T];
    if (service == null) {
      throw StateError('服务 $T 未登记：请确认提供它的模块已注册，且已写进 dependsOn');
    }
    return service as T;
  }

  /// 可选取服务（插件型能力，缺席时调用方自行降级）。
  T? maybeGet<T extends Object>() => _services[T] as T?;

  /// 已登记的服务及其提供者，用于 `/host` 诊断输出。
  Map<String, String> describe() => {
        for (final entry in _owners.entries) '${entry.key}': entry.value,
      };
}
