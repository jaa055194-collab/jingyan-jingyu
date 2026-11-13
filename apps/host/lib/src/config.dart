/// 宿主配置。
///
/// 来源优先级：环境变量 > 默认值。密钥类配置只能来自环境变量或系统凭据库，
/// 不得写进仓库（NFR-06）。
library;

/// 宿主配置。
class HostConfig {
  const HostConfig({
    this.bindAddress = '127.0.0.1',
    this.port = 8787,
    this.dataDir = 'data',
    this.hostVersion = '0.1.0',
  });

  /// 监听地址。部署时改为 LAN/tailnet 地址；不得监听公网（FR-10）。
  final String bindAddress;

  final int port;

  /// 数据目录（数据库、媒体、备份暂存）。
  final String dataDir;

  final String hostVersion;

  /// 从环境变量读取：`JINGYU_BIND`、`JINGYU_PORT`、`JINGYU_DATA_DIR`。
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
    );
  }
}
