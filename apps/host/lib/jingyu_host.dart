/// 鲸言鲸语宿主应用装配。
///
/// [buildHost] 是唯一的装配入口：测试与 `bin/server.dart` 都从这里取，
/// 新模块只需在 [defaultModules] 里追加一行（或由插件清单注入）。
library;

import 'package:jingyu_core/jingyu_core.dart';
import 'package:jingyu_host_kit/jingyu_host_kit.dart';

import 'src/auth/token_authenticator.dart';
import 'src/config.dart';
import 'src/messages/messages_module.dart';
import 'src/system/system_module.dart';
import 'src/storage/storage_module.dart';

export 'src/audit/audit_log.dart';
export 'src/auth/token_authenticator.dart';
export 'src/config.dart';
export 'src/http_server.dart';
export 'src/messages/message_store.dart';
export 'src/messages/messages_module.dart';
export 'src/security/url_guard.dart';
export 'src/system/system_module.dart';

/// 已装配好的宿主。
class Host {
  Host._(this.registry, this.pipeline, this.auth);

  final Registry registry;
  final Pipeline pipeline;
  final StaticTokenAuthenticator auth;

  Future<List<Object>> shutdown() => registry.shutdown();
}

/// 框架阶段默认模块。后续模块按 docs/modules 的编号追加。
List<HostModule> defaultModules(HostConfig config, Clock clock) {
  final storage = StorageModule(databasePath: '${config.dataDir}/host.sqlite');
  return [
    SystemModule(config: config, clock: clock, audit: storage.auditLog),
    storage,
    MessagesModule(),
  ];
}

/// 装配并启动宿主（不监听端口）。
Future<Host> buildHost({
  HostConfig config = const HostConfig(),
  Clock clock = const SystemClock(),
  List<HostModule>? modules,
  void Function(Object error, StackTrace stack)? onError,
}) async {
  final registry = Registry();
  final list = modules ?? defaultModules(config, clock);
  for (final module in list) {
    registry.register(module);
  }
  for (final module in list.whereType<SystemModule>()) {
    module.moduleNames = () => registry.moduleNames;
  }
  await registry.boot();

  final auth = StaticTokenAuthenticator();
  final pipeline = Pipeline(
    router: registry.router,
    authenticate: auth.call,
    onError: (error, stack, _) => onError?.call(error, stack),
  );
  return Host._(registry, pipeline, auth);
}
