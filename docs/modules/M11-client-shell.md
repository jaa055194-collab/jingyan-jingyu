# M11 · client_flutter：Android / Windows 外壳

> 依据：v4.2 FR-09/11/13/18/61、AC-16/30/32。依赖：`packages/jingyu_client_kit`。
> 本机已装 Flutter 3.50 / Dart 3.14、Android SDK 36、JDK 21（见安装记录）。首次 Android 构建需要联网下载 Gradle。

## 创建方式

```powershell
flutter create --org com.jingyu --platforms android,windows apps/client_flutter
```

在 `pubspec.yaml` 里用 path 依赖 `jingyu_core`、`jingyu_protocol`、`jingyu_client_kit`。

## 目录

```text
apps/client_flutter/lib/
  main.dart
  app/            路由、主题（双端共用主题、背景、字号，FR-09）
  data/           本地库（发件箱持久化、消息镜像、草稿）
  net/            HTTP + WebSocket 客户端，帧用 jingyu_protocol 编解码
  plugins/        内置插件列表，启动时交给 PluginHost.load
  features/
    chat/  contacts/  moments/  settings/  inbox/  world/  onboarding/
  platform/
    windows/      托盘、自启、全局快捷键、AUMID 通知、悬浮宠物
    android/      前台服务、分享面板、来电界面、小组件
```

## 规则

1. 业务逻辑放 `client_kit`，外壳只做 UI 绑定。能在 `client_kit` 里纯 Dart 测试的，不要写进 Widget。
2. 发消息一律 `Outbox.enqueue` → `flush`；收消息一律经过 `SyncCursor.accept`，返回 `gap` 时发 `SyncRequestFrame` 拉差集。
3. 插件：启动时创建 `PluginHost(environment: …)`；`isHostMachine` 由宿主 `/api/v1/host` 返回的标记决定，朋友端为 false。扩展点按 `docs/plugins/01-plugin-spec.md` 渲染。
4. 首次启动走 onboarding：输入宿主地址与邀请码 → 创建人物（选形象）→ 用 `RoomGenerator` 生成房间（需求方第 13 条）。
5. 草稿按会话持久化，重启不丢（FR-13）。
6. 应用锁：PIN 或生物识别；锁屏通知可隐藏正文（AC-30）。
7. Windows 通知必须建立带显式 AUMID 的开始菜单快捷方式；Android 标注"可能漏接"，30s 转未接。

## 验收

- [ ] AC-16 Windows：托盘、自启、快捷键、原生通知、悬浮宠物可用。
- [ ] AC-16 Android：前台服务保活；分享面板能把内容分享到指定会话。
- [ ] AC-18 断网发 3 条，联网后补传不重复（集成测试，用本地宿主）。
- [ ] AC-30 应用锁生效；锁屏通知可隐藏正文。
- [ ] AC-32 首次向 AI 发图片时提示"会进入她的上下文"；草稿重启不丢。
- [ ] `flutter analyze` 无问题；`flutter test` 通过；`flutter build windows` 与 `flutter build apk --debug` 成功。
- [ ] UI 改动的 PR 附同一场景的 Before/After 截图。
