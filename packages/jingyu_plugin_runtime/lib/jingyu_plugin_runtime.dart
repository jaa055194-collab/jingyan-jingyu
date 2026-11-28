/// 插件运行时（纯 Dart）。
///
/// 三块能力：
/// - 加载：把通过校验的插件 bundle 字节解析成运行期描述（运行时、入口、权限、slot）；
/// - 管理器：安装/更新/启停/卸载、权限审批、依赖检查与状态持久化；
/// - 沙箱：WebView/JS 插件的策略（独立 origin / CSP / 禁网）与 JSON-RPC 能力桥。
///
/// 不依赖 Flutter，也不直接做 IO；平台适配器（WebView、文件系统）由调用方注入。
library;

export 'src/plugin_loader.dart';
export 'src/plugin_manager.dart';
export 'src/plugin_sandbox.dart';
