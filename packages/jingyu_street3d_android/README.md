# jingyu_street3d_android

「世界 → 3D 街区」的 Android 宿主：一个 Flutter PlatformView（`jingyu/street3d_view`），用 WebView 显示 [`jingyu_street3d_web`](../jingyu_street3d_web) 的页面，并在页面和 Dart 之间传递 [PROTOCOL.md](../jingyu_street3d_web/PROTOCOL.md) 规定的 JSON 消息。只支持 Android。

## 行为

- 页面从 APK 内的 Flutter 资源加载。`WebViewAssetLoader` 把入口页所在的文件夹挂到 `https://appassets.androidplatform.net/assets/flutter_assets/…`，只提供这个文件夹里的文件。
- 其它请求都不加载：同一 origin 的其它路径返回 404，别的地址返回 403，`data:` 和 `blob:` 除外。页面也不能跳转出这个文件夹。文件和 content 访问都已关闭。
- 消息桥：`WebViewCompat.addWebMessageListener` 注入 `Street3DBridge`，只对上面这个 origin 生效。页面先发 `hello`，宿主用最新一条页面消息的 reply proxy 回复。页面发出第一条消息之前，Dart 发来的消息先存着，最多 64 条。
- 每个视图一个 MethodChannel：`jingyu/street3d_view_<id>`。Dart 调用 `start`、`send`、`pause`、`resume`；视图回调 `message` 和 `failure`。
- `failure` 的种类：`loadFailed`（主页面没加载出来）、`crashed`（渲染进程退出）、`unsupported`（系统 WebView 不支持 WebMessageListener）。
- 渲染进程退出时应用不会崩溃：这个 WebView 被销毁，Dart 收到 `crashed`，重新创建视图即可重试。
- 创建参数：`entry`（默认 `web/index.html`）、`assetPackage`（默认 `jingyu_street3d_web`，空字符串表示应用自己的资源）、`bridgeName`（默认 `Street3DBridge`）。

## Dart 用法

```dart
Street3DAndroidView(
  onCreated: (controller) {
    controller.messages.listen(onPageMessage);
    controller.failures.listen(onFailure);
  },
)
```

视图创建后立即开始加载页面。应用里由 `Street3DAndroidSurface`（`apps/client_flutter/lib/features/world/`）把它接到 `Street3DScreen`。

## 要求

- Android 8.0（API 26）及以上，和应用的 minSdk 一致；`onRenderProcessGone` 需要 API 26。
- 系统 WebView 要支持 `WebViewFeature.WEB_MESSAGE_LISTENER`，否则视图报告 `unsupported`，界面提示更新 Android System WebView。

## 测试

`flutter test` 用模拟的 channel 测试 controller，以及视图的类型和创建参数。WebView 本身的行为只能在设备或模拟器上验证。

## 来源和许可

- `android/build.gradle.kts`、`android/settings.gradle.kts` 和 `pubspec.yaml` 的插件声明来自 Flutter 3.50 的插件模板（`flutter create --template=plugin`）。许可是 BSD-3-Clause，见 <https://github.com/flutter/flutter/blob/master/LICENSE>。
- 唯一的第三方依赖是 `androidx.webkit:webkit:1.18.0`，许可是 Apache-2.0。
- 其余代码是本项目编写的。
