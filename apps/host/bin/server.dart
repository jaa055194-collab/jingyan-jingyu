/// 宿主入口：`dart run bin/server.dart`。
///
/// 环境变量：JINGYU_BIND（默认 127.0.0.1）、JINGYU_PORT（默认 8787）、JINGYU_DATA_DIR。
/// 不要把 JINGYU_BIND 设成 0.0.0.0 暴露到公网；部署时绑定 LAN 或 tailnet 地址（FR-10）。
library;

import 'dart:io';

import 'package:jingyu_host/jingyu_host.dart';
import 'package:jingyu_host/src/models/model_runtime.dart';

Future<void> main() async {
  final config = HostConfig.forServer(
    Platform.environment,
    script: Platform.script,
    resolvedExecutable: Platform.resolvedExecutable,
    onWorkerUnavailable: (reason) =>
        stderr.writeln('Model runtime disabled: $reason'),
  );
  final host = await buildHost(
    config: config,
    onError: (error, stack) =>
        stderr.writeln('unhandled: ${error.runtimeType}'),
  );
  final server = await HttpServer.bind(config.bindAddress, config.port);
  if (host.registry.services.maybeGet<ModelRuntime>() != null) {
    stdout.writeln(
      'Model runtime registered (worker: ${config.modelWorkerPath})',
    );
  }
  stdout.writeln(
    'jingyu host ${config.hostVersion} listening on ${config.bindAddress}:${config.port}',
  );

  ProcessSignal.sigint.watch().listen((_) async {
    await server.close();
    await host.shutdown();
    exit(0);
  });

  await serve(server, host.pipeline);
}
