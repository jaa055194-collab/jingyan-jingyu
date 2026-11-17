# M11 · 模块测试外壳与性能探针

> 依据：v4.2 FR-12、NFR-04；M11 客户端外壳、M10 世界/形象。依赖：Material 外壳（不可新增网络依赖）。

## 目标

让“整体程序外壳”可以先跑起来、并能在真机/桌面逐模块观察与测量，再逐步把各业务模块接入，而不是等所有模块完成后才第一次联调。当前先落地一个**依赖无关、可测试**的最小基础：

1. **模块清单（module_catalog）**：纯数据描述外壳可路由的模块与真实接入状态（已实现/占位/未接入），占位或未接入绝不伪装成功。
2. **模块测试与性能探针面板**：列出模块清单；用 `SchedulerBinding.addTimingsCallback` 采集真实帧耗时，计算 FPS、平均/P95 帧耗时、卡顿帧（>33ms≈慢于30fps）；用 `ProcessInfo.currentRss` 报告进程内存 RSS。
3. **入口**：设置→开发者→“模块测试与性能探针”。

## 边界与诚实性

- 探针是**测量工具**，不是性能保证；记录环境（设备/分辨率/场景人数），“目标 30fps、实测为准”。
- `ProcessInfo.currentRss` 是进程常驻内存的粗略代理，**不是 GPU 显存**。显存/GPU 帧率需真机原生工具（如 Android `dumpsys gfxinfo` / GPU 驱动计数器 / DevTools）单独采集，后续以平台通道接入。
- 本增量不含 3D 渲染；`world` 模块标记为“未接入”。

## 产品方向（需求方 2026-11-17 确认）

1. **房间**：沿用 feiyu-room-template（`https://github.com/sh2234113/feiyu-room-template` v3.0.0，MIT），保留“按提示词/对话生成房间”的能力（对应 `RoomGenerator`+`RoomBrief` 预设，onboarding 已具备生成→预览→确认流程）。
2. **性能基准**：暂无 Android 真机；以**骁龙888 稳定 30–60fps** 为目标，真机实测待设备可用或整体完成后进行；在那之前不冒称达标。
3. **形象**：**取消双端形象一致性**，以各终端本地上传的模型为准（手机与电脑可用不同模型）；**Live2D 上传即用、不做授权校验**（个人使用，NFR-12 官方授权不再作为前置）。

## 3D 世界 / 形象接入的前置（待后续切片）

- 按 M10-world 设计：3D 页面为独立模块（不嵌入聊天页），Android 用 WebView、Windows 用 WebView2，加载 `feiyu-room-template` 的 Three.js 房间。
- 需要：新增 WebView 依赖（需联网 `pub get`/`flutter pub add`，Windows 无现成离线包）、feiyu 模板的 Three.js 房间与模型素材（当前仓库缺失，需按固定 commit 获取并随附许可/署名；`da-feiyu.glb` 58.9MB 不入库，首运行下载并校验 sha256、过 UrlGuard）。
- 真机显存/帧率验收：接入真实渲染后，用原生工具采集同屏 ≤8、骁龙888 目标稳定 30–60fps 的实测值，并如实标注达标/未达标。

## 验收

- `flutter analyze` 无问题；`flutter test` 通过（含 module_catalog / perf_probe / 面板交互）。
- 面板能列出模块真实状态、开始/停止测量、显示 FPS/帧耗时/RSS。
- 本增量不声称完成 3D、显存或真机帧率保证；这些为后续独立切片。
