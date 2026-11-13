/// 路由常量。
///
/// 所有 HTTP 路径集中在此处，客户端与服务端都从这里取，禁止各写字符串字面量。
/// 版本前缀 `/api/v1`：破坏性变更必须抬版本，不允许原地改语义。
library;

/// HTTP/WS 路由表。
abstract final class Routes {
  /// 版本前缀。
  static const String prefix = '/api/v1';

  /// 存活探测（不需要认证）。
  static const String health = '$prefix/health';

  /// 宿主能力与版本。
  static const String hostInfo = '$prefix/host';

  /// 登录（换取设备 token）。
  static const String authLogin = '$prefix/auth/login';

  /// 刷新设备 token。
  static const String authRefresh = '$prefix/auth/refresh';

  /// 当前账号的设备列表。
  static const String authDevices = '$prefix/auth/devices';

  /// 远程下线某设备：`/auth/devices/{deviceId}/revoke`。
  static const String authDeviceRevoke = '$prefix/auth/devices/{deviceId}/revoke';

  /// 会话列表。
  static const String conversations = '$prefix/conversations';

  /// 会话内消息：`/conversations/{conversationId}/messages`。
  static const String messages = '$prefix/conversations/{conversationId}/messages';

  /// 单会话差集同步：`/conversations/{conversationId}/sync`。
  static const String sync = '$prefix/conversations/{conversationId}/sync';

  /// 附件上传。
  static const String attachments = '$prefix/attachments';

  /// 记忆管理。
  static const String memories = '$prefix/memories';

  /// 模型接入配置。
  static const String modelProviders = '$prefix/model-providers';

  /// WebSocket 长连接（通知与实时事件）。
  static const String stream = '$prefix/stream';
}
