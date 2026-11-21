# M10 · world：3D 街区、房间、形象、Live2D

> 依据：v4.2 FR-35～40、AC-22～26、NFR-04；口径 A-5、C-5、C-12、C-13。依赖：social、ai_core。
> 素材与许可：先读 `docs/plugins/02-assets.md`。

## 宿主侧

```text
apps/host/lib/src/world/
  world_module.dart     name 'world'
  layout_store.dart     space_layout：房间布局 + 版本号
  pathfinding.dart      waypoint graph + A*；位置权威在宿主
  presence.dart         2–5Hz 位置同步、拜访会话、门锁
  avatars.dart          VRM/设备本地 Live2D 选择，按设备隔离；不含模型字节
```

## 客户端侧

- 3D 页面是独立模块，不嵌进聊天页面（FR-12）：Android 用 WebView，Windows 用 WebView2，加载 feiyu-room-template 的 Three.js 房间。
- 内置插件 `jingyu.room.generator` 由 client kit 的 `FeiyuRoomGenerator` 实现 `RoomGenerator`，按 `02-assets.md` §2 做"按提示词/对话建屋"：五个风格预设 + `RoomBrief`→`RoomLayout`，只产出布局数据，不下载或执行代码；`briefFromConversation` 把对话文本映射为 brief。
- 本地 profile 元数据校验位于 `packages/jingyu_client_kit/lib/src/live2d_profile.dart`，只在设备本地校验配置，不检查数据库或参数名是否真实存在。
- `validateLive2DPackage` 是本地字节预检，不是解包器。它拒绝常见不安全的 ZIP 路径与可执行扩展名；检查识别到的 model3 引用是否使用规范相对路径及对应后缀（例如 `avatar.physics3.json`，不接受 `./` 路径别名）。清单、MOC3 和纹理的选定条目按声明长度限制解压输出，并检查 ZIP 校验和；PNG 检查首块 IHDR 与累计像素数。预检不覆盖完整 ZIP/DEFLATE 语法、所有可选载荷或图片解码，也不能作为安全落盘或渲染的依据。
- 静态预览准备与暂存接口：从通过检查的 ZIP 仅选取 MOC3 与引用的 PNG，以固定文件名重建清单，写入设备私有临时目录。暂存失败时清理本次文件，清理失败可重试。
- 渲染桥接与首帧状态机：client kit 的 `Live2DRendererBridge` 定义 Flutter↔WebView 的 `load`/`setParam`/`setExpression`/`setMotion`/`dispose` 与 `ready`/`error` 协议；`Live2DPreviewController` 把桥接接到平台 WebView 宿主，负责 loading→ready/error、首帧超时、重试与释放。只有查看器报告“渲染器已 prepare 且首帧 draw 未抛错”才算 ready；核心 `update()` 不算已绘制。
- WebView 查看器资源：`packages/jingyu_live2d_web` 提供 `live2d_viewer.html/js`（与实际桥接一致的协议层）、`live2d_renderer_webgl.js`（WebGL2/WebGL 绘制适配器；单层 stencil 掩码近似、部分混合，物理/动作/表情/眨眼不驱动）与 `tool/fetch_purismcore.ps1`（固定版本与 SHA-256 拉取 MIT 运行时，不入库）。Node 行为测试覆盖首帧成功才 ready、首帧失败/缺适配器/缺 core 只报 error、重复 load 拒绝与 dispose 释放；Dart 资产测试覆盖无远程模型 URL、运行时不入库。
- 客户端的“世界与形象”页已接入本机选包入口：Android 用系统文档选择器、Windows 用系统打开对话框选取 `.zip`，随后在后台 isolate 里按 160 MiB 上限流式读取、预检并暂存；界面只声明“已准备临时预览文件”，可手工清理。Android 会把所选内容流式复制进应用私有缓存（同样 160 MiB 上限，超出即拒绝并删除半成品），Windows 只读取用户自己的文件、不复制。应用锁开启时该入口禁用，避免切走系统选择器触发上锁后结果被丢弃。
- 上述链路的验证边界：Flutter 侧单测与控件测试覆盖取消、重复点击占用、准备失败与清理路径；原生选择器仅做过 Windows 原生通道契约与 Android Kotlin 编译/流式拷贝检查，**未在真机或真实桌面会话上人工点选**。它不证明 PNG 可完整解码、模型可绘制或设备能承受纹理开销；应用内渲染预览、持久化、热切换和回退尚未接入。Android WebView / Windows WebView2 宿主与本地资源投递仍未实现：`webview_flutter` 可离线接入 Android，Windows 仍需 WebView2 SDK 或自研宿主。
- Live2D 选择/导入由每位用户在自己的设备执行；不使用 `hostOnly` 插件门控。各设备独立保存模型文件与 profile，**不做跨端同步、不广播单一 model_id/profile_rev**；同一账号的手机与电脑可各自使用不同模型（如手机 B、电脑 C）。设备缺少本地模型或有效映射时回退 VRM，不下载他端模型。

## 规则

1. 每个设备独立选取用户自行取得的 Live2D 模型；默认目录/模型包不由应用提供。VRM 保持默认 fallback。形象选择按设备隔离，不做双端一致；同账号各设备互不影响。
2. profile 只保存相对 model3 manifest 路径、稳定 model_id、profile_rev 与语义 param_map，不保存模型字节、绝对路径、URL、API key 或 Cubism/Core 文件；模型字节不得进入服务端附件、同步、导出或共享备份。
3. 模型包与档案分别做预检；应用接入前仍须实现受限解包和资源隔离，不能把预检结果当作安全落盘许可。缺口型、左右眨眼、表情或动作映射禁止启用，不许猜参数；档案检查不证明映射目标存在于模型。
4. 热切换须离屏预载 → 句边界/口型≈0 的一帧原子替换 → 新模型首帧成功后销毁旧实例；不中断音频；失败回滚。当前仅有 profile metadata、查看器协议与首帧状态机；热切换尚未实现。
5. 拜访：好友可进小院；室内需邀请；单户访客 ≤4；被拉黑方无法拜访（口径 C-5）。
6. 宿主离线时位置冻结，恢复后继续，不补造路上经历（FR-36）。
7. 性能：同屏 ≤8 人，中端安卓室内目标 30fps，空闲降帧（NFR-04）。形象/Live2D 渲染以骁龙 888 稳定 30–60fps 为目标；暂无真机时先实现，整体完成后再实测，不把估算当实测。

## 授权与复用边界

- 朋友端模型由用户自行取得并承担其对模型素材的授权责任；本项目不提供、内置、上传或向他人分发任何 `.moc3`/模型包。
- **个人自用授权口径**：Live2D 上传即可使用，不做事前授权校验，使用人自负；应用仍不捆绑或分发模型或 Cubism SDK/Core 资产。
- Live2D 官方：[SDK 发行许可](https://www.live2d.com/zh-CHS/sdk/license/)、[Cubism Core 专有软件协议](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html)。此处仅记录风险，不构成法律意见。
- Coopanion 仅作为架构参考：其仓库采用 AGPL-3.0-or-later，figure-pack/分离部件 rig 不是 `.moc3` renderer，也非 Flutter Android/Windows drop-in；本项目未复制代码或资产。
- PurismCore `v1.1.0` 为 MIT 的可行候选；已在本地用发布 WASM v5/v6 core 对提供的模型完成 MOC3 一致性校验、模型构造与一次 update（详见 `docs/research/purismcore-model-compatibility.md`）。这证明该文件可由该 core 读取，不证明真实图像、Flutter WebView 集成、物理/动作、性能或生产安全。
- 最快渲染原型方向是评估/适配 PurismCore 自带的 Raylib WebGL2 viewer 到受控本地 WebView；viewer 文档明确称其不完整、没有 physics 和完整 JSON parser。不得直接采用其 ZIP loader 作为安全导入器；必须单独实现并测试路径/条目/体积/JSON/纹理上限。尚未将该候选接入应用或作最终选型。
- 提供的某张纹理为 8192×8192；所有五张 RGBA8 base texture 合计约 592 MiB，尚未计入副本、WASM、mask/offscreen 缓冲。WebView 设备必须验证 `MAX_TEXTURE_SIZE >= 8192` 或经批准的降采样方案，并做真实中端安卓内存/帧率测试；当前没有这些证据。
- 开源 core 的 MIT 许可不等于素材许可或格式/商标法律结论。保留已提供素材来源署名，并不得把模型或整个资源包放进安装包/公开产物。

## 验收

- [ ] AC-22 AI 从自家走到好友家，路径由宿主计算；门锁、被拒、超时回家都有日志。
- [ ] AC-23 室内需邀请；第 5 位访客被拒；被拉黑方拜访被拒。
- [ ] AC-25 合法 Live2D 包导入成功；缺映射不能启用；恶意包（Zip Slip、含 .js、超大解压）被拒。
- [ ] AC-25 模型与映射只存本设备、不跨端同步；服务端不广播单一 model_id/profile_rev。
- [ ] AC-26 同一账号手机与电脑可各用不同模型（B/C）互不影响；缺本地模型/映射时回退 VRM；不捆绑或分发模型/Cubism 资产。通用 `hostOnly` 插件机制不受此变更影响。
- [ ] C-13 房间生成器对五个风格预设都能产出合法 `RoomLayout`；生成结果不含可执行代码。
