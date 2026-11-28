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
- 本地 profile 元数据校验位于 `packages/jingyu_client_kit/lib/src/live2d_profile.dart`，只在设备本地校验配置本身；映射目标是否存在于模型，由启用时的 `validateTargets` 对照预览回报的 `Live2DModelInfo` 检查。
- `validateLive2DPackage` 是本地字节预检，不是解包器。它拒绝常见不安全的 ZIP 路径与可执行扩展名；检查识别到的 model3 引用是否使用规范相对路径及对应后缀（例如 `avatar.physics3.json`，不接受 `./` 路径别名）。清单、MOC3 和纹理的选定条目按声明长度限制解压输出，并检查 ZIP 校验和；PNG 检查首块 IHDR 与累计像素数。预检不覆盖完整 ZIP/DEFLATE 语法、所有可选载荷或图片解码，也不能作为安全落盘或渲染的依据。
- 静态预览准备与暂存接口：从通过检查的 ZIP 仅选取 MOC3、引用的 PNG 与 model3 列出的表情（exp3）、动作（motion3）文件，以固定文件名（如 `expression-N.exp3.json`、`motion-N.motion3.json`）重建清单，写入设备私有临时目录。只涉及一个表情或动作的问题（缺文件、文件过大、JSON 无效或嵌套过深、校验和不符、`Name` 或组名为空、过长或重复、超出数量上限）只把该条目从重建的清单中去掉并给出非致命警告；MOC3、纹理或 model3 本身的问题仍使整包被拒。暂存失败时清理本次文件，清理失败可重试。
- 渲染桥接与首帧状态机：client kit 的 `Live2DRendererBridge` 定义 Flutter↔WebView 的 `load`/`setParam`/`setExpression`/`setMotion`/`dispose` 与 `ready`/`error` 协议；`Live2DPreviewController` 把桥接接到平台 WebView 宿主，负责 loading→ready/error、首帧超时、重试与释放。只有查看器报告“渲染器已 prepare 且首帧 draw 未抛错”才算 ready；核心 `update()` 不算已绘制。就绪后查看器报告绘制失败或 WebGL 上下文丢失，或宿主通道出错（例如 Android 渲染进程退出）时，同样转为失败状态，可以重试；正式启用为形象后的 VRM 回退尚未实现。
- WebView 查看器资源：`packages/jingyu_live2d_web` 提供 `live2d_viewer.html/js`（与实际桥接一致的协议层）、`live2d_renderer_webgl.js`（WebGL2/WebGL 绘制适配器；单层 stencil 掩码近似、部分混合，只负责像素绘制）、`tool/fetch_purismcore.ps1`（固定版本与 SHA-256 拉取 MIT 运行时，不入库），以及 `live2d_motion.js`（motion3/exp3）、`live2d_behavior.js`（眨眼/视线/呼吸/口型）、`live2d_physics.js`（physics3）与 `live2d_pose.js`（pose3）四个求值模块；查看器每帧按 动作→表情→行为→覆盖值→物理→姿态 的顺序写入参数与 part 不透明度。`live2d_texture_budget.js` 按设备的 `MAX_TEXTURE_SIZE` 与 256 MiB 预算统一缩小全部纹理（预算取自 Mochi2D 的手机默认值，未实测）。Node 行为测试覆盖首帧成功才 ready、首帧失败/缺适配器/缺 core 只报 error、重复 load 拒绝、dispose 释放、`boot` 事件与错误 `code`、就绪后的上下文丢失与绘制失败、动作/表情/物理/姿态求值与纹理预算；Dart 资产测试覆盖无远程模型 URL、运行时不入库。
- 客户端的“世界与形象”页已接入本机选包入口：Android 用系统文档选择器、Windows 用系统打开对话框选取 `.zip`，随后在后台 isolate 里按 160 MiB 上限流式读取、预检并暂存；暂存完成后，Android 在面板内显示临时预览卡片并注明“仅本机临时预览，未启用形象”，其他平台只声明“已准备临时预览文件”；均可手工清理。Android 会把所选内容流式复制进应用私有缓存（同样 160 MiB 上限，超出即拒绝并删除半成品），Windows 只读取用户自己的文件、不复制。应用锁开启时该入口禁用，避免切走系统选择器触发上锁后结果被丢弃。
- Android 预览承载（二期增量 A）：`MainActivity` 注册原生平台视图 `jingyu/live2d_view`（`Live2DViewPlugin`、`Live2DPlatformView`），视图内是系统 WebView。`WebViewAssetLoader` 在 `https://appassets.androidplatform.net` 下只提供白名单内的查看器文件（构建时由 Gradle 复制进安装包）和 `serve` 登记过的暂存目录：目录必须在 `cacheDir/live2d-preview` 之内，按 128 位随机令牌访问，越界路径与其他请求一律 403，不开文件访问。页面与 Flutter 经 `WebViewCompat.addWebMessageListener`（只认查看器源）和每个视图一条 `MethodChannel('jingyu/live2d_view/<id>')` 往返；渲染进程退出时销毁该 WebView，预览转为失败，重试时新建视图。Flutter 侧为 `AndroidLive2DRendererHost` 与 `Live2DPreviewView`。构建前未运行 `tool/fetch_purismcore.ps1` 时构建只告警、安装包不含运行时，预览会报错。方案依据见 `docs/research/live2d-phase-two-survey.md` 第 3、5 节。
- 参数映射建议（二期增量 B 第一步）：查看器的 `ready` 事件附带运行时枚举的参数与 part ID，client kit 解析为 `Live2DModelInfo`（格式不对时预览照常就绪，但不给 ID 集合）；预检把 model3 `Groups` 读进 `Live2DPackageValidation.groups`；`Live2DParamProposal` 只用运行时回报的 ID 建议口型与眨眼参数。建议只作映射向导的预选。依据见调研文档 4.11 与 5.4。
- 本机保存、映射与启用（二期增量 B 第二步，仅 Android）：临时预览就绪后，「保留此模型」把暂存时写出的文件（不是 ZIP 原始条目）存进 `noBackupFilesDir/live2d/models/<modelId>/`，删除临时文件，再从保存目录打开预览；同一时间只显示一个预览。client kit 的 `Live2DFileStore` 负责落盘：模型目录先写成 `<modelId>.pending` 再改名，JSON 先写 `.pending` 再改名，`models.json` 是提交点，打开时清理或回滚中断的操作。「本机保存的模型」列出每个模型及其状态（未设置映射 / 已保存映射 / 已启用），可设置映射、启用或停用、删除（先确认，连带删除映射）。映射向导分三步：口型与左右眨眼（必填）、表情、动作；候选只来自该预览回报的参数、表情 `Name` 与动作组和序号，不从文件名推断，B1 的建议只作预选；参数行的滑条在预览里按参数范围试动，松开后交还模型自身的动作；只有回报的列表为空时才能确认「此模型没有表情/动作」，模型未回报该列表时不能保存。「确认并保存」是唯一的写入；「启用此形象」用该模型本机副本的预览回报逐项核对映射目标，缺项逐条列出且不启用。启用的形象显示在聊天页（见下条），暂不在世界场景中显示。查看器已播放表情与动作，并运行眨眼/视线/呼吸/口型与 physics3/pose3；映射向导里选中的表情或动作可以「试看」，口型与眨眼页可以「测试眨眼」「测试说话」。依据见调研文档 5.5 与 5.6。
- 聊天页形象卡片（二期增量 D1，仅 Android）：聊天页标题栏下方、消息列表上方固定显示本机已启用的模型（不随消息滚动），是一张可折叠卡片：标题行显示模型名与「收起形象/展开形象」按钮，底部拖动条调整高度（120 dp 到窗口高度一半，默认 220 dp）。没有启用的模型、启用的模型已删除或本机模型库打不开时不显示卡片；读不到模型目录、渲染失败或超时时卡片内显示原因与「重试」。收起时卸载平台视图，展开时新建视图并重新加载模型；折叠状态与高度只在本次运行内保留，重启后恢复默认。切到其他底部标签时卡片保持常驻并暂停帧循环，回来继续，不重新加载；世界页启用或停用另一个模型后，隐藏的卡片会自动换好模型，回到聊天即可看到。世界场景暂不显示形象；可见的交叉淡化切换与口型同步未做。
- 查看器热切换基础（二期增量 D3，仅查看器）：WebGL 适配器支持同一画布/上下文里的多个场景，每个场景有自己的纹理、几何缓存与适配；片元着色器增加整场景 alpha。查看器新增 `preload`（旧模型继续画、新模型 CPU 与纹理就绪，纹理预算不足则拒绝）、`swap`（按 `fadeMs` 交叉淡化；新模型首帧失败只释放新场景并回滚，成功后淡化结束才释放旧场景）与 `pause`/`resume`（只停/启帧循环）。`load` 保持原协议，单场景适配器仍可用。Dart 侧 `Live2DSwitchCoordinator` 已接在聊天卡会话上（可见时先 preload 再 swap，失败回退重载）；句末/口型门控、聊天页内切换入口与真机「无空白」验证尚未做。
- 上述链路的验证边界：Flutter 侧单测与控件测试覆盖取消、重复点击占用、准备失败与清理路径；原生选择器仅做过 Windows 原生通道契约与 Android Kotlin 编译/流式拷贝检查，**未在真机或真实桌面会话上人工点选**。它不证明 PNG 可完整解码、模型可绘制或设备能承受纹理开销；Android 上的本机保存、映射与启用已接入（见上条，未在真机上验证），动作/表情/物理/姿态求值已接入但未在真机核对视觉与帧率，热切换和 VRM 回退尚未接入。Windows 客户端不再开发，不接 WebView2 宿主。
- Live2D 选择/导入由每位用户在自己的设备执行；不使用 `hostOnly` 插件门控。各设备独立保存模型文件与 profile，**不做跨端同步、不广播单一 model_id/profile_rev**；同一账号的手机与电脑可各自使用不同模型（如手机 B、电脑 C）。设备缺少本地模型或有效映射时回退 VRM，不下载他端模型。

## 规则

1. 每个设备独立选取用户自行取得的 Live2D 模型；默认目录/模型包不由应用提供。VRM 保持默认 fallback。形象选择按设备隔离，不做双端一致；同账号各设备互不影响。
2. profile 只保存相对 model3 manifest 路径、稳定 model_id、profile_rev 与语义 param_map，不保存模型字节、绝对路径、URL、API key 或 Cubism/Core 文件；模型字节不得进入服务端附件、同步、导出或共享备份。
3. 模型包与档案分别做预检；本机只保存暂存时按固定文件名重建、写出的文件，不能把预检结果当作直接落盘 ZIP 条目的许可。缺口型或左右眨眼映射禁止启用，不许猜参数；表情、动作映射可以为空，但只能在用户确认「此模型没有表情/动作」之后（D1-B，负责人 2026-11-26 同意）。档案检查不证明映射目标存在于模型：启用前须用该模型本机副本的预览回报逐项核对，缺项逐条列出并拒绝启用。
4. 热切换须离屏预载 → 句边界/口型≈0 的一帧原子替换 → 新模型首帧成功后销毁旧实例；不中断音频；失败回滚。当前有 profile、查看器协议、首帧状态机、Android 上的本机保存和启用，以及查看器侧的多场景预载、交叉淡化、回滚与 pause/resume；Dart 协调器与切换入口尚未接入。
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
- 提供的某张纹理为 8192×8192；所有五张 RGBA8 base texture 合计约 592 MiB，尚未计入副本、WASM、mask/offscreen 缓冲。WebView 设备必须验证 `MAX_TEXTURE_SIZE >= 8192` 或经批准的降采样方案，并做真实中端安卓内存/帧率测试；当前没有这些证据。降采样方案见 `docs/research/live2d-phase-two-survey.md` 5.2 与 5.3（全部纹理统一缩放），尚待评审批准。
- 开源 core 的 MIT 许可不等于素材许可或格式/商标法律结论。保留已提供素材来源署名，并不得把模型或整个资源包放进安装包/公开产物。

## 验收

- [ ] AC-22 AI 从自家走到好友家，路径由宿主计算；门锁、被拒、超时回家都有日志。
- [ ] AC-23 室内需邀请；第 5 位访客被拒；被拉黑方拜访被拒。
- [ ] AC-25 合法 Live2D 包导入成功；缺映射不能启用；恶意包（Zip Slip、含 .js、超大解压）被拒。
- [ ] AC-25 模型与映射只存本设备、不跨端同步；服务端不广播单一 model_id/profile_rev。
- [ ] AC-26 同一账号手机与电脑可各用不同模型（B/C）互不影响；缺本地模型/映射时回退 VRM；不捆绑或分发模型/Cubism 资产。通用 `hostOnly` 插件机制不受此变更影响。
- [ ] C-13 房间生成器对五个风格预设都能产出合法 `RoomLayout`；生成结果不含可执行代码。
