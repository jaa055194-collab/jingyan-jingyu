/// 宿主侧模块框架。
///
/// 一个模块 = 一段可独立启停的业务能力（账号、消息、记忆、模型接入……）。
/// 模块之间只通过 [HostServices] 暴露的接口与模块自身声明的路由通信，
/// 禁止互相 import 对方的内部实现。这条约束是"新增功能不大改软件"的实现前提
/// （需求方 2026-11-13 答复第 14 条：插件化、规范插件模式）。
library;

export 'src/host_services.dart';
export 'src/http_pipeline.dart';
export 'src/module.dart';
export 'src/registry.dart';
export 'src/router.dart';
