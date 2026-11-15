# 第三方软件声明（THIRD_PARTY_NOTICES）

本文件登记本项目（鲸言鲸语）以 **Dart 包依赖**形式引入的第三方开源组件及其许可证。这些组件通过 `pubspec.yaml` 作为依赖声明、由 pub 解析后落于本地 pub 缓存，本仓库不内嵌其源码。

完整许可证文本以上游仓库与本地 pub 缓存中的 `LICENSE` 文件为准；本文件仅作登记与归属说明。

## 组件清单

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

## 说明

- 上述组件均以 Dart package 依赖方式使用，未修改其源代码。
- MIT 与 BSD-3-Clause 均要求在再分发时保留原版权声明与许可证文本；相应全文见各上游仓库及 pub 缓存中的 `LICENSE` 文件。
- 本清单仅登记当前已引入的组件；后续新增依赖须在此补充登记。
