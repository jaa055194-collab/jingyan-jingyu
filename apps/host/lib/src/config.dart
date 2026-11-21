/// 宿主配置。
///
/// 来源优先级：环境变量 > 默认值。密钥类配置只能来自环境变量或系统凭据库，
/// 不得写进仓库（NFR-06）。
library;

import 'dart:io';

/// 宿主配置。
class HostConfig {
  const HostConfig({
    this.bindAddress = '127.0.0.1',
    this.port = 8787,
    this.dataDir = 'data',
    this.hostVersion = '0.1.0',
    this.modelWorkerExecutable,
    this.modelWorkerPath,
    this.hostAccountId,
    this.hostDeviceId,
  });

  /// 监听地址。部署时改为 LAN/tailnet 地址；不得监听公网（FR-10）。
  final String bindAddress;

  final int port;

  /// 数据目录（数据库、媒体、备份暂存）。
  final String dataDir;

  final String hostVersion;

  /// Trusted absolute launch paths; both are required to enable model calls.
  /// No SDK or worker path is accepted from HTTP requests.
  final String? modelWorkerExecutable;
  final String? modelWorkerPath;

  /// 由部署者指定的可信宿主机账号与设备身份，必须同时匹配已认证管理员。
  /// 未配置任一项时，不授予宿主机能力；不从地址、平台或请求参数推断。
  final String? hostAccountId;
  final String? hostDeviceId;

  /// Source-server startup only. The entry point supplies [script] and
  /// [resolvedExecutable] from `Platform`; neither comes from a request.
  /// An explicit override never mixes with inferred paths. Failure to infer a
  /// usable pair is reported, but does not prevent non-model host features.
  factory HostConfig.forServer(
    Map<String, String> env, {
    required Uri script,
    required String resolvedExecutable,
    required void Function(String) onWorkerUnavailable,
  }) {
    final config = HostConfig.fromEnvironment(env);
    if (config.modelWorkerExecutable != null ||
        config.modelWorkerPath != null) {
      return config;
    }

    // Don't infer a worker for snapshots, compiled executables, or other entry
    // points. Never search the current directory or PATH for a launch target.
    if (script.scheme != 'file' || !script.path.endsWith('/bin/server.dart')) {
      onWorkerUnavailable('Default model worker requires bin/server.dart.');
      return config;
    }
    final executable = File(resolvedExecutable);
    if (!executable.isAbsolute || !executable.existsSync()) {
      onWorkerUnavailable(
        'Default model worker requires the running Dart SDK executable.',
      );
      return config;
    }
    final worker = File.fromUri(script.resolve('http_worker.dart'));
    if (!worker.isAbsolute || !worker.existsSync()) {
      onWorkerUnavailable(
        'Default model worker file not found: bin/http_worker.dart.',
      );
      return config;
    }
    return HostConfig.fromEnvironment({
      ...env,
      'JINGYU_MODEL_WORKER_EXECUTABLE': resolvedExecutable,
      'JINGYU_MODEL_WORKER_PATH': worker.path,
    });
  }

  /// 从环境变量读取：`JINGYU_BIND`、`JINGYU_PORT`、`JINGYU_DATA_DIR`，
  /// 可选的模型工作进程路径，以及 `JINGYU_HOST_ACCOUNT_ID` /
  /// `JINGYU_HOST_DEVICE_ID` 身份对。
  factory HostConfig.fromEnvironment(Map<String, String> env) {
    final portRaw = env['JINGYU_PORT'];
    final port = portRaw == null ? 8787 : int.tryParse(portRaw);
    if (port == null || port <= 0 || port > 65535) {
      throw FormatException('JINGYU_PORT 必须是 1–65535 的整数', portRaw);
    }
    return HostConfig(
      bindAddress: env['JINGYU_BIND'] ?? '127.0.0.1',
      port: port,
      dataDir: env['JINGYU_DATA_DIR'] ?? 'data',
      modelWorkerExecutable: env['JINGYU_MODEL_WORKER_EXECUTABLE'],
      modelWorkerPath: env['JINGYU_MODEL_WORKER_PATH'],
      hostAccountId: env['JINGYU_HOST_ACCOUNT_ID'],
      hostDeviceId: env['JINGYU_HOST_DEVICE_ID'],
    );
  }
}
