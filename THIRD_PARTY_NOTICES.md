# 第三方软件声明（THIRD_PARTY_NOTICES）

本文件登记本项目（鲸言鲸语）引入的第三方开源组件及其许可证：

- Dart 包依赖：通过 `pubspec.yaml` 声明、由 pub 解析后落于本地 pub 缓存，本仓库不内嵌其源码。
- Android 依赖：通过 Gradle 声明、从 Google Maven 解析，本仓库不内嵌其源码。
- 构建时拉取的运行时：由脚本按固定版本与 SHA-256 下载，不进仓库；Android 构建把它与其许可证文件一起打进安装包。
- 改编片段：改编进本仓库源码的第三方代码，在对应文件头保留原版权与许可声明。

完整许可证文本以上游仓库、本地 pub 缓存或 Gradle 缓存中的 `LICENSE` 文件为准；本文件仅作登记与归属说明。

## Dart 包依赖

### archive

- 版本：3.6.1
- 许可证：MIT
- 上游：<https://github.com/brendan-duncan/archive>
- 用途：纯 Dart 的 zip 解码与条目读取，用于插件包（bundle）安全校验（`validatePluginPackage`）。

### crypto

- 版本：3.0.x
- 许可证：BSD-3-Clause
- 上游：<https://github.com/dart-lang/crypto>
- 用途：计算插件包字节的 sha256，用于完整性比对（`validatePluginPackage`）。

### path（传递依赖）

- 版本：随依赖解析（1.9.x）
- 许可证：BSD-3-Clause
- 上游：<https://github.com/dart-lang/path>
- 用途：`archive` 的运行时传递依赖（路径处理），非本项目直接依赖。

### pub_semver

- 版本：2.2.1
- 许可证：BSD-3-Clause
- 上游：<https://github.com/dart-lang/tools/tree/main/pkgs/pub_semver>
- 用途：解析插件 bundle 的语义化版本与依赖版本区间（`PluginBundle` / `PluginDependency`）。

### collection（传递依赖）

- 版本：随依赖解析（1.19.x）
- 许可证：BSD-3-Clause
- 上游：<https://github.com/dart-lang/collection>
- 用途：`pub_semver` 的运行时传递依赖，非本项目直接依赖。

## Android 依赖

### androidx.webkit

- 版本：1.18.0
- 许可证：Apache-2.0
- 上游：<https://github.com/androidx/androidx/tree/androidx-main/webkit>
- 用途：Android 端 Live2D 预览。`WebViewAssetLoader` 只在 `https://appassets.androidplatform.net` 上按白名单提供查看器文件与暂存的模型文件；`WebViewCompat.addWebMessageListener` 承载页面与 Flutter 之间的 `Live2DBridge` 消息。

## 构建时拉取的运行时

### PurismCore Web 运行时

- 版本：v1.1.0（`PurismCore-v1.1.0-Web.zip`，SHA-256 `ee229d1b28c33a9f57f02c777f8633141042cd771e5e47bf4795ba345b3a0b39`）
- 许可证：MIT（Copyright (c) 2026 Sakura Motion Project）
- 上游：<https://github.com/SakuraMotion/PurismCore>
- 用途：Live2D 查看器中的 Cubism Core 兼容运行时 `purismcore.js`。`packages/jingyu_live2d_web/tool/fetch_purismcore.ps1` 下载并校验后，只把 `purismcore.js` 与 `LICENSE` 复制到被 git 忽略的 `web/runtime/purismcore/`；Android 构建把这两个文件一起打进安装包。
- 不分发任何模型、`.moc3` 或纹理；上游 `LICENSE_TESTDATA`（CC0）覆盖的测试数据不进仓库，也不进安装包。

## 改编片段

### PurismCore viewer 示例

- 版本：v1.1.0 的 `src/samples/viewer/graphics.c` 与 `src/samples/viewer/shaders/draw.frag`
- 许可证：MIT（Copyright (c) 2026 Sakura Motion Project）
- 上游：<https://github.com/SakuraMotion/PurismCore/tree/v1.1.0/src/samples/viewer>
- 改编位置：`packages/jingyu_live2d_web/web/live2d_renderer_webgl.js` 的相机计算（`updateProjection()`、`computeFit()`，对应上游 `WorldToScreen()`、`FitView()`），以及 `DRAW_FRAGMENT_SHADER` 的乘算色、屏幕色与预乘步骤。文件头保留原版权与许可声明。

### Flutter 平台视图测试替身

- 来源：flutter/flutter 的 `packages/flutter/test/services/fake_platform_views.dart`
- 许可证：BSD-3-Clause（Copyright 2014 The Flutter Authors）
- 上游：<https://github.com/flutter/flutter/blob/master/packages/flutter/test/services/fake_platform_views.dart>
- 改编位置：`apps/client_flutter/test/live2d_native_fake.dart`，仅为测试代码，不进安装包。文件头保留原版权与许可声明。

## 说明

- Dart 包与 Android 依赖均以依赖方式使用，未修改其源代码；PurismCore 运行时原样分发，未作修改。
- MIT、BSD-3-Clause 与 Apache-2.0 均要求再分发时保留原版权声明与许可证文本；相应全文见各上游仓库及 pub、Gradle 缓存中的 `LICENSE` 文件。PurismCore 的 `LICENSE` 随运行时一起打进安装包。
- 本清单仅登记当前已引入的组件；后续新增依赖须在此补充登记。
