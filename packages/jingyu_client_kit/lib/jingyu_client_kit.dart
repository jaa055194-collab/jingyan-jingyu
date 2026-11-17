/// 客户端内核。
///
/// 只放与 UI 无关、可纯 Dart 测试的逻辑：插件体系、发件箱、同步游标。
/// Flutter 外壳（apps/client_flutter，见 docs/modules/M11-client-shell.md）
/// 依赖本包，把插件声明的扩展点渲染成界面。
library;

export 'src/client_session.dart';
export 'src/draft_store.dart';
export 'src/local_search_index.dart';
export 'src/live2d_package.dart';
export 'src/live2d_profile.dart';
export 'src/local_message_cache.dart';
export 'src/outbox.dart';
export 'src/plugin.dart';
export 'src/plugin_bundle.dart';
export 'src/plugin_host.dart';
export 'src/plugin_package.dart';
export 'src/plugin_package_builder.dart';
export 'src/sync_cursor.dart';
