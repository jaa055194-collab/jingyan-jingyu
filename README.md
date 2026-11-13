# 鲸言鲸语

自托管、Android + Windows 双端的 AI 聊天软件，自用与朋友小圈子。需求见 [鲸言鲸语-需求规格-v4.2.md](鲸言鲸语-需求规格-v4.2.md)。

## 当前状态

程序框架已搭好：领域原语、线协议、宿主模块框架、客户端插件框架，以及作为参考实现的消息内核。具体功能按 [docs/modules](docs/modules/README.md) 的编写指令分模块实现。

## 目录

```text
packages/jingyu_core        领域原语（标识、Result、时钟、可见性、记忆分层、预算分层）
packages/jingyu_protocol    线协议（帧、路由、错误码、严格编解码）
packages/jingyu_host_kit    宿主模块框架（模块、注册表、路由、管线）
packages/jingyu_client_kit  客户端内核（插件、发件箱、同步游标）
apps/host                   宿主服务
docs/architecture           分层规则与需求口径
docs/modules                给实现模型的逐模块编写指令（M01–M13）
docs/plugins                插件规范与素材许可
tool/check.ps1              全仓分析与测试
```

## 运行

需要 Dart 3.9 及以上（本机 Flutter 3.50 自带 Dart 3.14）。

```powershell
powershell -ExecutionPolicy Bypass -File tool/check.ps1                       # 全部包：pub get + analyze + test
cd apps/host; dart run bin/server.dart    # 启动宿主，默认 127.0.0.1:8787
```

## 给实现模型

先读 [docs/modules/README.md](docs/modules/README.md)，再读你领到的模块文件。不要改 `packages/*` 的框架接口。
