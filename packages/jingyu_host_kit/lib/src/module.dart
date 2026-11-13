/// 模块契约。
library;

import 'host_services.dart';
import 'router.dart';

/// 一个宿主模块。
///
/// 生命周期（由 `Registry` 驱动，顺序固定）：
/// 1. [configure]：把本模块提供的服务登记到 [HostServices]，可从其中取依赖；
/// 2. [mount]：声明本模块的 HTTP 路由；
/// 3. [start]：启动后台任务（心跳、清理、调度）；
/// 4. [stop]：按逆序停止，必须幂等。
///
/// 实现要点：
/// * [configure] 里**不要**做阻塞 IO 或发起网络请求；
/// * 依赖必须声明在 [dependsOn]，注册表据此排序并检测循环；
/// * 模块之间不要互相 import 实现文件，只能通过服务接口交互。
abstract class HostModule {
  /// 模块唯一名，用于依赖声明与日志。建议用英文短横线名，例如 `messages`。
  String get name;

  /// 依赖的模块名。必须是其他已注册模块的名字。
  List<String> get dependsOn => const <String>[];

  /// 登记服务、读取依赖。
  Future<void> configure(HostServices services) async {}

  /// 声明路由。
  void mount(Router router) {}

  /// 启动后台任务。
  Future<void> start() async {}

  /// 停止后台任务，需幂等。
  Future<void> stop() async {}
}
