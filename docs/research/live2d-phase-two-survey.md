# Live2D 二期调研：开源实现与公开资料汇总（Android）

> 调研日期 2026-11-25（Asia/Shanghai），部分条目于 2026-11-26 复核（见 6.3 与第 7 节）；仓库基线 HEAD `913a1072b1df`。本文只整理调研笔记中有据可查的事实（笔记与源码副本不入库）；第 5 节中 5.3、5.4、5.5 是本 PR 已实现的部分（增量 A 与增量 B 的 B1、B2），其余是计划。
> 外部事实均给出仓库 URL、版本 / 标签或提交（短 SHA）、许可（SPDX id；非 SPDX 许可写原名）；未另注明时，截至日期为 2026-11-25。
> 标注：**自报** = 项目自己公布、未独立复现；**未核实** = 笔记未能证实；**矛盾** = 来源说法不一致；**推论** = 由笔记事实推出、尚未验证；**建议** = 本文提出的我方设计，不是上游事实。

## 0. 结论摘要

- **运行时**：采用 PurismCore v1.1.0（MIT）。它用 C99 编写，与 Cubism Core 的 API / ABI 兼容（自报），并有 Emscripten Web 构建（2.2）。本应用要加载用户导入的不定数量模型，按 Live2D 许可属于 Expandable Application，所以不使用官方 Cubism Framework / Core，也不移植其代码（2.1）。运行时按固定版本与 SHA-256 在本地拉取，不入库。
- **Android 承载**：自建 Kotlin PlatformView，通过 androidx.webkit（Apache-2.0）承载系统 WebView（3.6）：
  - `WebViewAssetLoader` 只提供查看器页面、运行时与暂存的模型文件，其余请求一律拒绝；
  - 消息走 `addWebMessageListener`；
  - 处理 `onRenderProcessGone`。
  - 否决 `webview_flutter_android`、`flutter_inappwebview` 与回环 HTTP 服务。
- **资源上限**：Android 上 Chromium 同时最多保留 8 个活跃 WebGL 上下文，WebGL 的 `MAX_TEXTURE_SIZE` 最大为 8192（3.4）。因此整页只用一个 WebGL 上下文。全部纹理按同一比例缩放，同时满足 `MAX_TEXTURE_SIZE` 与 256 MiB 预算。预算取自 Mochi2D 的手机默认值，是估计值，需要实测（2.3）。
- **故障处理**：预览就绪后，渲染进程退出、WebGL 上下文丢失和绘制失败都转为失败状态，用户可以重试。正式启用为形象后，改为回退到默认 VRM（增量 D）。
- **行为层**：眨眼、呼吸、视线、口型、表情、动作、物理与空闲调度，参考 MIT / Apache-2.0 项目的实现改编，并保留原许可声明。官方 SDK、GPL 与无许可证的代码只作行为基准，或直接排除（4.0）。
- **落地顺序**：
  - 增量 A 与本文在同一 PR 实现（5.3），包括运行时打包、Android 承载、纹理预算和就绪后的故障处理。
  - 增量 B 的第一步 B1 也在本 PR 实现（5.4）：查看器回报模型的参数与 part ID，client kit 据此与 model3 `Groups` 建议口型与眨眼参数，不保存、不启用。
  - 增量 B 的第二步 B2 也在本 PR 实现（5.5，仅 Android）：把预览过的模型保留到本机，用映射向导设置口型、眨眼、表情与动作，保存并启用；启用的形象暂不在聊天或世界场景中显示。
  - 后续计划（5.2）：C 行为层（含表情与动作的播放），D 热切换与 VRM 回退，E 真机验证与性能测量。
- **未决**（第 6 节）：
  - 实现来源与专利的法律评估；
  - 真机性能数据；
  - 3D 房间与 Live2D 预览同时打开时的上下文占用。

## 1. 约束与评估标准

### 1.1 产品约束（硬性）

- 维护者要求：每项 Live2D 改进先查找现有开源代码和公开技术文章，再适配到本应用。本文汇总二期调研，第 5 节是适配计划（尚未实现）。
- 只针对 **Android 客户端**。Windows 客户端已不再开发，文中的 Windows 内容（`webview_windows`、Windows 插件 symlink 等）只作背景。
- 模型按设备本地导入、本地暂存（每台设备各自一份），**不做跨设备同步**，服务端也不保存参数映射。需求要求可随时热切换（包括通话中），每个模型的参数映射启用前先校验，失败时回退到默认 VRM 形象。
- 仓库和安装包都**不包含**模型文件，也不包含 Cubism SDK / Cubism Core 文件。PurismCore 运行时同样不入库：`packages/jingyu_live2d_web/tool/fetch_purismcore.ps1` 按固定版本下载、校验 SHA-256 后只复制 `purismcore.js` 与 `LICENSE`（见 `packages/jingyu_live2d_web/README.md`）。
- 永不打包或再分发用户的模型及其 zip（安装包、日志、测试夹具、文档都不含）；模型只留在导入它的设备上。
- PurismCore 为 MIT 许可：随运行时保留其 `LICENSE` 全文（含版权声明）与署名；运行时按上述脚本在本地获取，从不提交。
- 导入预检（precheck）只是检查，**不等于允许持久化或渲染**：保存、启用、渲染各自需要单独的校验与用户确认。
- GPL / AGPL 代码不作为复用候选（会传染到客户端），文中只以「排除」出现并写明原因；无许可证或许可不明的代码不复制。

### 1.2 评估标准

| 维度 | 判断依据 |
|---|---|
| 许可 | 进入客户端的代码只接受 MIT / BSD / Apache-2.0 / CC0 等宽松许可；Live2D 专有或 Live2D Open Software License 代码、GPL / AGPL、无许可证代码均不复制 |
| 是否依赖官方 Core | 运行时离不开 Cubism Core（`live2dcubismcore*.js`、`.aar`、动态库）即排除 |
| 活跃度 | 最近提交 / 标签日期、维护者人数、open issue / PR 状态 |
| 能力 | moc3 版本、遮罩 / 混合 / offscreen，physics / motion / expression / pose 覆盖面 |
| 成熟度 / 风险 | 自报还是独立验证、来源（provenance）风险、API 稳定性 |
| 可适配性 | 能否在 Android System WebView（WebGL2 / WebGL1）中运行，能否接入现有 viewer 与 Dart 桥 |

### 1.3 调研方法

| 来源类型 | 内容 | 访问时间 |
|---|---|---|
| GitHub API / 代码搜索 | 仓库元数据（许可、star、最近推送）、标签与提交 SHA、issue / PR 状态、PurismCore 下游使用 | 2026-11-25 |
| 包注册表 | pub.dev API（Flutter WebView 插件、live2d_flutter）、npm | 2026-11-25 |
| 官方文档 | Android Developers（androidx.webkit、WebView 渲染进程、TTS）、MDN | 2026-11-25 |
| 浏览器源码 | Chromium 的 WebGL 上下文代码与 GPU 驱动缺陷列表 | 2026-11-25 |
| 项目文件 | README、LICENSE / LICENSING、来源声明、源码（只在核实具体事实时打开） | 2026-11-25 |
| Live2D 许可页面 | OSL、SDK 许可、Expandable Application、Framework `LICENSE.md` | 2026-11-25 |
| 本仓库 | HEAD `913a1072b1dfecf53ccb64dc14b9f292f32efcc6`（2026-11-25）的构建配置、查看器与原生代码 | 2026-11-25 |
| 第三方调研 | miaotouy/aio-hub `docs/Plan/live2d-integration-investigation-20261030.md`（Apache-2.0） | 文档日期 2026-10-30；其中 npm 与官方 SDK 数据为当时记录，本次未逐项复核 |

- developer.android.com 无法访问（curl 返回 000），Android 文档改从镜像 developer.android.google.cn 读取。
- 测试数量、一致性、性能等由项目自己公布的数据一律标「自报」。
- GPL 或未声明许可的仓库只读取事实，不复制代码。

## 2. 运行时 / 渲染器调研

已有的 PurismCore 模型兼容性测试见 `docs/research/purismcore-model-compatibility.md`，本节不重复。

| 项目 | URL | 许可（SPDX） | 活跃度（版本 / 提交 / 日期） | 能力 | 成熟度 / 风险 | 结论 |
|---|---|---|---|---|---|---|
| PurismCore | https://github.com/SakuraMotion/PurismCore | MIT；测试数据 CC0（`LICENSE_TESTDATA`，moc3 来自 RavioliMavioli/archlive2d） | v1.1.0 `1069334965522df5d0b791e97f01e26b19c45456`（2026-08-21）；v1.0.1 `166785bb1d188bcf11c2dbf1b2476dd31f76a24f`（2026-06-06）；v1.1.0 后无新提交；56 star | C99 的 Cubism Core 兼容实现（API/ABI drop-in），默认 v6 ABI（对应 Cubism 5.3 SDK / Core 6.0），可选 v5 ABI（`0x05010000L`）；Emscripten wasm32 Web 构建，全局对象 `PurismCore` | contributors API 只有一人（Ronsor）；">10,000 项内部测试 + ASAN/UBSAN fuzz"为自报；2 个 open issue；v1.1.0 有 dynamic flags 问题（issue #3，见 2.2），修复在未合并的 PR #4 | 采用 |
| PurismCore PR #4 | https://github.com/SakuraMotion/PurismCore/pull/4 | 随上游 MIT（未单独声明） | head `57b488f3fbb6c12a71a7382bf1ee09c17ef7ab5a`（`970205011:port/downstream-fixes`，基于 v1.1.0 rebase）；5 个提交，+866/−261，16 个文件 | `dc245c3a92a3` reset 不再清除变化位；`50eeaae960c5` dirty skipping；`ae2117f8593a` 只在网格变化时置 `VERTEX_CHANGED`；`b7671dd079ec` 父 part 不透明度；`57b488f3fbb6` glue 双端 dirty 传播（手臂遮罩闪烁）；MinGW gcc13 -O3 下 402 项单元测试通过（自报） | open、未合并、无 review；第 4、5 个提交修的是第 2 个提交引入的回归；唯一评论（TremblingMoeNew，2026-09-03）认为"update 之后 reset"是 Cubism Core/Framework 的 bug | 参考 |
| PurismCore fork | https://github.com/pakholeung37/PurismCore | 笔记未记录 | head `ad5127666ccffb34552d8e660852995858bee437`（2026-09-21），领先上游 5 个提交 | 一致性（conformance）文档、deformer 修复 | 未进入上游 | 参考 |
| Mochi2D | https://github.com/waifucave/Mochi2D | MIT | head `4378a87535b0b55101615e05892957b311cc2c5a`（2026-11-22）；npm `mochi2d` 0.24.1；仓库 2026-11-15 创建，1 star | TypeScript 运行时 + WebGL2 渲染器：moc3 v1–6、model3/motion3/exp3/physics3/pose3、眨眼/呼吸/注视/口型（含麦克风）/motionsync3、PixiJS v8；一致性 604/604、54/54（RMS 0.057）、104/104（自报，README 注明"not a certification"） | 来源风险：由 AI 代理（Claude）以"clean-room"方式开发，但研究侧读过 Cubism Framework 源码、运行过 Cubism Core；README 称"Copyright may not subsist in every part"，并提及 glue / blend shapes 专利；CLEANROOM.md L29-32 称 inbox 为完整记录，但仓库中没有 `cleanroom/` 目录（API 404）；只支持 WebGL2 | 参考（仅作对比，不复制代码） |
| ayagami | https://github.com/AyagamiDev/ayagami | MIT OR Apache-2.0（仓库同时附 `LICENSE-MIT` 与 `LICENSE-APACHE`；GitHub 许可 API 只返回其中的 `LICENSE-APACHE`，所以显示 Apache-2.0） | `0d1d7aa3efe57b1b363b72e672e353c52a9c15d6`（2026-09-14）；407 star | Rust 黑盒逆向实现；moc3 到 SDK 5.0，另支持 5.3 blend / offscreen；有物理；表情、pose、motion 未实现；wgpu（WebGL / WebGPU） | API 不稳定、可能 panic；不接受 PR；README 称可免费使用，包括加载用户模型的 expandable 类应用 | 参考 |
| ayatsuri_2d | https://github.com/Ayatsuri2D/ayatsuri_2d | 仓库 LICENSE 为 GPL-3.0；LICENSING.md：openmoc3 / core / format / import 为 MIT，capi 为 Apache-2.0，`crates/render`（wgpu）与 editor / app 为 GPL-3.0 | head `170d889986ede267ace09ee388bca05c8788f9b7`（2026-11-22），v0.6.3；12 star | Rust；openmoc3 源自 PurismCore、moc3ingbird hexpat（FDPL 1.0-US）与 CubismSpecs；桌面端 eframe / wgpu，无 Web/WASM 目标 | 渲染 crate 为 GPL-3.0；physics.rs 称"own integrator"、docs/physics.md 称"bit-faithful"（两句说的是同一个导入用摆锤求解器：前者讲实现是自写的，后者是对行为一致的自报，未核实；并不矛盾）；provenance.md L3-19 自述未反汇编、未用 SDK 源码、未接受许可 | 排除 |
| Mocari | https://github.com/Eatgrapes/Mocari | MIT | `29a4792f93b7075049cee080ba11a3c834efd01c`；54 star | Rust 运行时（TR0MXI/LunaMate 在用） | 功能列表未提物理 | 参考 |
| live2d_flutter | pub.dev `live2d_flutter`（pubspec 仓库 hunmer/flutter_live2d） | BSD-3-Clause | 1.0.3（2026-09-04） | Flutter 插件（android / ios / macos / web / windows），Android 包名 `com.linh18nd.flutter_live2d`，在 `android/src/main/cpp` 内置 CubismFramework C++ | 基于官方 CubismFramework，需要 Cubism Core | 排除 |
| pixi-live2d-display | https://github.com/guansss/pixi-live2d-display | MIT；子模块 guansss/CubismWebFramework（API NOASSERTION，`LICENSE.md` 称其属于 Live2D Cubism Components） | `31317b37d5e22955a44d5b11f37f421e94a11269`（2023-12-15）；npm 0.4.0（2022-09-04，Pixi 6，据 aio-hub）；1518 star | PixiJS 上的 Live2D 显示层；派生：RaSan147 fork（`6c2645fb566cc7a48aa6865daa77a5cffb726db4`，"with lip-sync from audio"）、`pixi-live2d-display-lipsyncpatch`、`@naari3/pixi-live2d-display`（Pixi 8）等 | 需要 `live2dcubismcore.min.js`；构建中打包了 OSL 的 Cubism Web Framework | 排除 |
| live2d-web | https://github.com/Heonys/live2d-web | 自有代码 MIT；Framework 与着色器为 Live2D OSL；Core 专有（由使用方提供） | `1960370fb06d3fdd58c41921d6d0a2c81d76cfd2`；npm 0.9.0（2026-09-01，据 aio-hub） | `createLive2D`；Cubism Framework 5-r.5 适配层 | 需要 Cubism Core；含 OSL 代码 | 排除 |
| 其他依赖官方 Core 的封装 | Moebytes/live2d-renderer；Evergaster/l2d-viewer | live2d-renderer：MIT；l2d-viewer：MIT OR Apache-2.0（`Cargo.toml` 的 `license` 字段；附 `LICENSE-MIT` 与 `LICENSE-APACHE`，GitHub 许可 API 只返回后者） | `68d9556686657ff2c221eac679b41633f20f7b13`；`1b1aae0be8fb13699f548b9030061957bdfe2a11` | live2d-renderer：官方 Framework 封装，需 `live2dcubismcore.min.js`；l2d-viewer：moc3 读取 + CPU 光栅化，WebGL2 查看器以官方 Core 为"oracle"做变形 | 离不开 Core | 排除 |
| Ren'Py | https://github.com/renpy/renpy | API 许可字段为空；文件头为 MIT 式许可文本 | `24be485cfff87a4a8ca374b64204953df0521744` | `renpy/gl2/live2d.py` 加载官方 Core 动态库或 `live2dcubismcore.js`，要求 Cubism 5.3 及以上；motion / pose / blend / physics 有 Python 重写（见第 4 节） | 运行时需要官方 Core（由用户在 Ren'Py 启动器中安装，不随附） | 排除（运行时） |
| Live2D Cubism SDK for Web | https://github.com/Live2D/CubismWebFramework ；https://github.com/Live2D/CubismWebSamples | Framework：Live2D OSL v1.4；Core：Live2D Proprietary Software License v2.1（2025-02-03 修订） | Web SDK 5-r.5；Framework `LICENSE.md` @ `d4da0aa07e47d2c1e4f5fa7ea6047861ea5e5d0b`（2026-04-02） | 官方实现；R5 改用 `WebGL2RenderingContext`，着色器拆为独立 .vert/.frag，新增 `CubismUpdateScheduler`（据 aio-hub） | 许可约束见 2.1 | 排除 |
| Inochi2D / inox2d | https://github.com/Inochi2D/inochi2d | BSD-2-Clause（inox2d 文本为 BSD-2，API 显示 NOASSERTION） | inochi2d `cc48d37d1353ff43cb3b61ec69ed65002cf7c32f`；inox2d `d4dd9dd7f16b775042cbda44370570abf9a8cf81` | 自有 INP/INX 格式 | 不能替代 MOC3 | 排除 |
| 其他（仅记录） | OpenL2D/PurismCore_Old；OpenL2D/moc3ingbird；zeikar/iki；levinkin/hikari-aio | PurismCore_Old、moc3ingbird：FDPL 1.0-US（均已归档）；iki：MIT | — | moc3ingbird 描述为"MOC3ingbird Exploit for Live2D (CVE-2023-27566)"；iki 用自有 .iki 格式；hikari-aio 无 WebGL | — | 排除 |

- 表中 star、最近提交、issue / PR 状态均为 2026-11-25 的 GitHub API 数据。
- GPL-3.0 项目（MF-Dust/Nori.Desktop、getzipzi/zipzi-2d，见 2.2 下游使用；ayatsuri_2d 的 render / editor / app）与 PolyForm Noncommercial 1.0.0 的 ARVTubeLink 都不作复用候选：前者会传染到客户端，后者限非商业用途；只引用其公开的事实与评估数据。

### 2.1 Cubism SDK 许可约束

- OSL v1.4：第 1.5 条把可加载不定数量模型的应用归为 Expandable Application；第 2.2.1 条要求 Framework 只能与 Live2D Runtime Software 一起分发；另有第 2.3 条 Publication License、第 5.1 条禁止移植（port）、竞品软件限制、第 5.6 条（excluded licences）、第 14.2 条（东京管辖）。
- SDK 许可页：小规模事业者豁免**不适用于** Expandable Application。
- Expandable Application 页：需审查（约 5–6 天）；完全免费的应用一般不符合条件；费用为每笔销售 USD 1.88 / JPY 300 或 20%（aio-hub 记为取较高者）。aio-hub 的判断是：免费导入模型的应用很可能属于 Expandable Application。
- Framework `LICENSE.md`：营收超过门槛（JPY 10,000,000）的事业者需要 Release License；Core 为专有许可。门槛以 `LICENSE.md` L13 原文为准（`Live2D/CubismWebFramework@8ac72d40bc0a`，该文件最后一次修改为 2021-05-13）：上一财年年度总收入 more than ten million (10,000,000) JPY，即严格大于 1000 万日元；早先一份笔记写成"≥ 10M"，有误。
- 本应用要加载用户导入的不定数量模型，因此不使用官方 Framework / Core，也不移植其代码（见 5.2、第 6 节）。

### 2.2 PurismCore：与适配相关的细节

- Web 构建：`emcc -O3 -sSINGLE_FILE=1 -sMODULARIZE=1 -sEXPORT_NAME=_em_module -sWASM_ASYNC_COMPILATION=0 -sALLOW_MEMORY_GROWTH=1`（v5 构建输出 `purismcore-v5.js`）；v1.1.0 的 `Web.zip` 为 353307 字节。
- `core_js.js` 暴露全局 `PurismCore`（`Version`、`Logging`、`Moc`、`Model`、`CanvasInfo`、`Parameters`、`Parts`、`Drawables`、`Offscreens`（v6）、`Utils`、`Memory`），结构对应 `Live2DCubismCore`，标志位取值与官方一致；v1.1.0 中查不到 `Live2DCubismCore` 别名，本仓库 viewer 在基线 `913a107` 的 `live2d_viewer.js` 第 14 行直接使用 `window.PurismCore`。只有需要超过 16 MiB 内存时才需调用 `Memory.initializeAmountOfMemory`。
- dynamic flags（issue #3，open，2026-09-02，0 条评论）：v1.1.0 `update.c` 的 `psm__update_flags`（L75-164）每次 update 都给所有启用的网格置 `VERTEX_CHANGED`（L138-139），`csmResetDrawableDynamicFlags`（L250-257）就地清除变化位；按"先 update 后 reset"调用时（issue 在官方 Framework 下复现），遮罩管线读不到变化位。Nori.Desktop 改用"先 reset 再 update"规避。issue 作者另报告 dirty skipping 使 `csmUpdateModel` 从 5.88 ms 降到 1.27 ms（−79%，自报），并指出官方 Core 对超出范围的参数继续施加差值而不是截断。
- 后端识别（Nori.Desktop 原生评估）：官方 Core 与 PurismCore 的 `csmGetVersion` 都是 `0x06000001`，PurismCore 的 `csmGetTrueVersion` 为 `0x01010000`；Web 构建是否有对应接口未核实。
- 参考渲染器（MIT）：PurismCore raylib viewer 的 `render.c` 把遮罩按 RGBA 通道打包（每个缓冲 4 个 clip group），支持 multiply / screen 和 offscreen 渲染目标，特殊混合用 `glCopyTexSubImage2D` 复制背景后走 `blend.frag`；`viewer.h`：`GROUPS_PER_BUF 4`、`MAX_CLIP_GROUPS 64`、`MAX_OFFSCREENS 256`，`BuildClipGroups` 溢出时退化为不加遮罩。`docs/VIEWER.md`：该 viewer 无物理、无完整 JSON 解析器，`--maskscale` 默认 0.5。
- Nori.Desktop 评估（GPL-3.0 仓库，只取事实）：固定使用 v1.1.0 / v6 ABI 原生库，校验完整 release 包 `PurismCore-v1.1.0.zip`（不是 `Web.zip`）的 SHA-256 `ae1b32af28a06b27f47cda61f8b5f5d4caa047dc856cdde1d6d839b850b6a70c`，原生库旁附 MIT 全文；纯 Core 更新比官方慢 9–11%（0.017–0.024 ms/帧），整帧差 0.01–0.08 ms、无稳定提速（自报；Windows、Ryzen 1600X + RX 580、ANGLE D3D11 GLES 3.0）；截图差异 <0.054% 像素，并非逐像素一致；同一 GL 上下文内销毁并重建模型时两种 Core 都报 `GL_INVALID_VALUE`（1281），未归因于 PurismCore；换 Core 不会让其 C# 渲染器获得 Cubism 5.3 offscreen / 新混合模式；Linux/macOS 原生、长时间运行、功耗与内存未验证。
- 下游使用（GitHub 代码搜索 164 条，2026-11-25）：MF-Dust/Nori.Desktop（GPL-3.0，`0880605716254a55345d7518844afe0f8ae8b771`）、getzipzi/zipzi-2d（GPL-3.0，`bd8379679577591e3d2d50c151a91697402fdb26`）、Kalyn-Voris/ARVTubeLink（PolyForm Noncommercial 1.0.0，API 显示 NOASSERTION；Kotlin/Android；`3110a142dc53fa18a269f07383fdc5fd417312ed`）、miaotouy/aio-hub（Apache-2.0，`0d01665790f836c079c6ba774ffe28a76b24af68`）、ActorF/Elysia_AI（MIT，`ccaf955aa5804d574743222350c6dd77849f8217`）。

### 2.3 Mochi2D（仅作对比）

- viewer 默认用近似 mask atlas；手机/平板纹理预算 256 MiB；空闲时不重绘；需要 WebGL2。
- `effects.ts` 实现眨眼、呼吸、注视；pose 默认淡入淡出 0.5 s。
- waifucave/Mochi2D-Native（`ad108ba6be6638bcff99c789c91426e136fe81d8`，2026-11-24，MIT）：Mochi2D 的 C++ 移植，来源情况相同；README L38-43：OpenGL 后端为 OpenGL ES 3.0 或桌面 GL 3.3 core，另有 Vulkan 1.1（SPIR-V）与 Metal 后端；早先笔记只记了 OpenGL 后端，与仓库描述并不矛盾。仓库描述里的 D3D11 与 GitHub API 给出的主语言 TypeScript 未核实。

## 3. Android 承载方案调研

### 3.1 方案对比

| 方案 | 版本 / 提交 | 许可 | 笔记记录的事实 | 评估 |
|---|---|---|---|---|
| webview_flutter（+ `webview_flutter_android`） | 4.14.1（2026-07-07）/ 4.14.1（2026-08-28）；标签 `webview_flutter-v4.14.1` → `b79b35409f67bcbd14e66760fb64380328bd4a0a`，`webview_flutter_android-v4.14.1` → `9854cd5607da4001f2dd3cbdcd6903202d28958c` | BSD-3-Clause | `loadFile` 走 `file://` 并 `setAllowFileAccess(true)`；WebViewClient 回调里没有 `shouldInterceptRequest`，也没有 `onRenderProcessGone`；JS 通道只有 `@JavascriptInterface postMessage(String)`（仅字符串）；Dart→JS 只有 `runJavaScript` / `runJavaScriptReturningResult`；`WebViewFlutterAndroidExternalApi.getWebView`（4.13.0 起）能拿到原生 WebView，但 Dart 每次设置导航委托都会替换原生 WebViewClient（`android_webview_controller.dart` L506-514），ExternalApi 注明其余原生代码不遵循破坏性变更约定；`WebViewProxyApi.dispose()` 为空；默认 TLHC；依赖 androidx.webkit 1.15.0，minSdk 24 | 不采用 |
| flutter_inappwebview | 6.1.5（2024-10-08，`v6.1.5` = `f67ae1f34868c7660c16a2473f53a7a7bfb6f784`）；6.2.0-beta.3（2026-02-04）；`_android` 1.1.3、`_windows` 0.6.0 | Apache-2.0 | 自带 `webview_asset_loader.dart`（`InternalStoragePathHandler`）、`in_app_localhost_server.dart`、`onRenderProcessGone`；CHANGELOG 提到 `JavaScriptReplyProxy.postMessage`，并修复"Unexpected addWebMessageListener behaviour"（#1422）；依赖 `flutter_inappwebview_windows`（default_package）；`_android` 构建配置为 AGP 7.3.0/8.0.1、Kotlin 1.7.10、compileSdk 34、minSdk 19、androidx.webkit 1.12.0；3795 star、234 个 open issue，仓库最后推送 2026-02-10 | 不采用 |
| RcTool 回环 HTTP 服务 | richuff/RcTool HEAD `93d573ead82ae5aa1c2e664d7fc21216ceb00aab`（2026-11-09）；许可核对于 `5511dcdf67a889f61478db44b873fce7ebc7a59b` | MIT（`vendor/live2dcubismcore.min.js` 为 Live2D 专有，`vendor/pixi.min.js` 为 MIT） | `Live2DAssetServer`：`HttpServer.bind(loopbackIPv4, 0)`（L40）；rootBundle 资源返回 `Access-Control-Allow-Origin: *`（L72、L103）；`/ext/<相对路径>` 读外部目录并用 `p.isWithin` 校验；`Cache-Control: no-store`；无 token、无 Host 校验。WebView 用 webview_flutter（移动端）/ webview_windows（Windows）；运行时为官方 Cubism Web SDK + Core | 不采用（目录扫描、路径校验思路可参考） |
| 自建 Kotlin PlatformView + androidx.webkit | androidx.webkit（`WebViewAssetLoader`、`WebViewCompat`） | Apache-2.0（androidx/androidx） | 见 3.2、3.3 | 采用（见 3.6） |

### 3.2 androidx.webkit

- `WebViewAssetLoader`（`WebViewAssetLoader.java` @ `30e32ec1d335483120660f5a9136c384dcb49c1a`，`AssetHelper.java` @ `72ed4c1a36360c83c3399f8311e53ad7cbbcfcce`）：
  - 默认域名 `appassets.androidplatform.net`（L106）。文档：可用自有域名或这个保留域名，示例 `https://appassets.androidplatform.net/assets/www/index.html`；以 HTTP(S) URL 加载，因而遵循同源策略；接法是在 `WebViewClientCompat.shouldInterceptRequest` 中转交 `assetLoader.shouldInterceptRequest`。
  - `InternalStoragePathHandler`（L280）服务应用内部存储下的目录，目录不允许时抛 `IllegalArgumentException`（L317-322），禁止 `app_webview/`、`databases/`、`lib/`、`shared_prefs/`、`code_cache/`；`getCanonicalFileIfChild`（L372）把访问限制在目录内；文件不存在时返回空的 `WebResourceResponse(null, null, null)`（L386）；`Builder.setHttpAllowed`（L511）。
  - Android 文档：`setAllowFileAccessFromFileURLs` / `setAllowUniversalAccessFromFileURLs` 自 API 30 废弃，理由是不安全，建议改用 `androidx.webkit.WebViewAssetLoader`。
- `WebViewCompat.addWebMessageListener(webView, jsObjectName, allowedOriginRules, listener)`：`@UiThread`，需要 `WEB_MESSAGE_LISTENER`（先用 `WebViewFeature.isFeatureSupported` 检查）；向每个匹配 `allowedOriginRules` 的 frame 注入名为 `jsObjectName` 的 JS 对象，可用 `removeWebMessageListener` 移除。应用在 `onPostMessage(view, message, sourceOrigin, isMainFrame, replyProxy)` 收到消息；要经这条通道回发，页面必须先发过一条消息，应用才拿得到 `JavaScriptReplyProxy`。
- `WebViewCompat.postWebMessage(webView, WebMessageCompat, targetOrigin)`（1.1.0 起，需 `POST_WEB_MESSAGE`）：向主 frame 发消息，可限定目标 origin（允许 `*`，但不推荐）；`TYPE_ARRAY_BUFFER` 需另做特性检查。另有 `createWebMessageChannel`（1.1.0）、`addDocumentStartJavaScript`（`DOCUMENT_START_SCRIPT`）。
- 与现有查看器的衔接（实现时确认）：查看器 `post()` 依次尝试 `window.Live2DBridge.postMessage`、`flutter_inappwebview.callHandler('live2d')`、`parent.postMessage`，`jsObjectName` 取 `Live2DBridge` 即可沿用页面→应用路径；应用→页面目前是 `runJavaScript` 调用 `window.__live2dReceive`，改用 `postWebMessage` 后页面需改为监听 `message` 事件。

### 3.3 渲染进程与优先级（Android 文档）

- `onRenderProcessGone`（API 26）：多个 WebView 可能共用一个渲染进程；只清理传入的 WebView 并把它移出视图层级；返回 true 表示已处理，否则应用会崩溃或被杀；可用 `chrome://crash` 测试。`RenderProcessGoneDetail.didCrash()` 为 false 表示被系统杀掉（多半因内存不足）；另有 `rendererPriorityAtExit()`（API 26）。
- `onRenderProcessUnresponsive`（API 29）：最短 5 秒回调一次，WebView 自己不做处理；`WebViewRenderProcess.terminate()`（API 29）若没有被所有 WebView 处理，应用也会被终止。
- `setRendererPriorityPolicy(RENDERER_PRIORITY_BOUND, true)`：不可见时放弃优先级；文档建议除非使用了终止处理 API，否则不要改优先级。
- 本仓库 minSdk 26，`onRenderProcessGone` 在所有受支持版本上可用；webview_flutter 不暴露该回调（flutter/flutter#130297 仍 open）。

### 3.4 Chromium WebGL 限制

- 活跃上下文上限：`content/renderer/webgraphicscontext3d_provider_impl.cc` L122-128 —— Android 为 8，其他平台 16，worker 4，可用 `switches::kMaxActiveWebGLContexts` 命令行开关覆盖（L130-134）；核对提交 `chromium/chromium@9fb3a21ed95c`（2026-11-24）。
- 超限行为：`webgl_rendering_context_base.cc` @ `78b637f4dc5e99665428bdc73f3ef51359b8095c` 的上限取自 `webgl_preferences.max_active_webgl_contexts`（L481-491）、`CurrentMaxGLContexts`（L494-499）；激活超过上限的新上下文时，`ForciblyLoseOldestContext`（L501-513）以 `kSyntheticLostContext` 强制丢失最旧的上下文（按最后一次 flush id 判断，L515-532）。上限按页面还是按渲染进程计数，笔记未记录（未核实）。
- 纹理尺寸：`gpu_driver_bug_list.json` 条目 456（L2662-2669）"Limit max texure size to 8192 on Android."适用于全部 Android，即使 GL 报告 16384，WebGL 的 `MAX_TEXTURE_SIZE` 也只有 8192；条目 147（L347-357）"Limit max texure size to 4096 on older Android devices."（适用版本笔记未确认）。WebGL 的 `GL_MAX_TEXTURE_SIZE` 查询在 `webgl_rendering_context_base.cc` L1598-1599。
- WebGL2：`gpu_util.cc` 的 `GetWebGLFeatureStatus` 与 WebGL2 黑名单（`GPU_FEATURE_TYPE_ACCELERATED_WEBGL2`）说明 WebGL2 可能按设备被禁用；"因此保留 WebGL1 回退"是推论，未核实。
- 现有渲染器：先 `webgl2` 后 `webgl` 回退，`premultipliedAlpha: true`，已监听 `webglcontextlost` / `webglcontextrestored`；L21 注释把 `MAX_TEXTURE_SIZE` 列为未处理项。
- 推论（实现时确认）：整页只保留一个 WebGL 上下文，热切换时复用，避免触发"丢失最旧上下文"（另见 4.10）。

### 3.5 本仓库现状（HEAD `913a1072b1df`）

- 构建：minSdk 26；compileSdk / targetSdk 36（Flutter 3.50.0 / Dart 3.14.0）；AGP 9.3.1；Kotlin 2.4.20。`apps/client_flutter/pubspec.yaml`、`jingyu_client_kit`、`jingyu_live2d_web` 都没有 WebView 依赖。
- `apps/client_flutter/windows/` 仍在（25 个受跟踪文件）。flutter_tools 在项目有 `windows/` 且启用 Windows 时为带 Windows 实现的插件创建 symlink，无 symlink 支持时报错 1314"Building with plugins requires symlink support"。
- `MainActivity.kt`：MethodChannel `jingyu/platform`；`getLive2DPreviewDirectory` → `cacheDir/live2d-preview`；`pickLive2DZip`；声明 INTERNET 权限。`Live2DZipCache.kt`：`MAX_BYTES` 160 MiB，目录 `cacheDir/live2d-preview`，24 小时清理过期内容，带上限的流式复制。
- 查看器页面以相对路径加载 `runtime/purismcore/purismcore.js`、`live2d_renderer_webgl.js`、`live2d_viewer.js`；`fetch` 用 `no-store`；按 model3 → moc → 纹理（`Live2DRenderer.prepare`）顺序加载；`requestAnimationFrame` 驱动；`setParam` 线性查找参数。
- 提交 `029aaf95ff0bd139f8cb0684b19c137107e24a91`（2026-11-21）在 README 写入"Android 可用缓存中的 `webview_flutter` 接本地资源服务"；该方案已被本文 3.6 的选型取代，README 需另行更新（本次不改）。
- 本地 AVD `Flutter_API_36`（x86_64）为 `hw.gpu.enabled=no`，对 WebGL 测试的影响未核实。

### 3.6 结论：选定与否决

- **选定：自建 Kotlin PlatformView + androidx.webkit（Apache-2.0）**，承载系统 `android.webkit.WebView`（建议，尚未实现）：
  - 资源：`WebViewAssetLoader` 以 `https://appassets.androidplatform.net/` 提供查看器页面与 PurismCore 运行时，用 `InternalStoragePathHandler` 只暴露本设备的模型目录；不开放 `file://` 访问（file URL 跨域设置已因不安全被废弃，见 3.2）。
  - 消息：`WebViewCompat.addWebMessageListener`，`jsObjectName` 取 `Live2DBridge`，`allowedOriginRules` 只含 `https://appassets.androidplatform.net`；页面先发就绪消息，应用再经 `JavaScriptReplyProxy` 回发（或用 `postWebMessage`，需特性检查）。
  - 稳定性：实现 `onRenderProcessGone`，只销毁出事的 WebView、回退到 VRM 并返回 true；`onRenderProcessUnresponsive`（API 29+）只记日志。
  - 理由：所需能力都来自官方库，minSdk 26 全部可用；不引入第三方 WebView 插件，构建链（AGP 9.3.1、Kotlin 2.4.20、compileSdk 36）由仓库自己掌控。
- **否决 `webview_flutter_android`**：拿不到 `shouldInterceptRequest` 与 `onRenderProcessGone`；JS 通道只收字符串；经 ExternalApi 改原生 `WebViewClient` 会被 Dart 侧的导航委托覆盖，且这部分不受破坏性变更约定保护；`loadFile` 依赖 `file://` 与 `setAllowFileAccess(true)`，与 Android 推荐的 `WebViewAssetLoader` 方向相反。
- **否决 `flutter_inappwebview`**：功能齐全，但稳定版 6.1.5 发布于 2024-10-08，6.2.0 仍是 beta（2026-02-04），仓库最后推送 2026-02-10、234 个 open issue；`_android` 的构建配置（AGP 7.3.0/8.0.1、Kotlin 1.7.10、compileSdk 34）与本仓库差距大，能否在 AGP 9 下构建未验证（推论）；还会带入 `flutter_inappwebview_windows`。
- **否决回环 HTTP 服务（RcTool 做法）**：本机其他应用同样能连 `127.0.0.1` 上的端口，而 RcTool 既无 token 也不校验 Host，还返回 `Access-Control-Allow-Origin: *`，模型文件可能被本机其他进程读到（推论）；端口与生命周期要自管；其运行时是官方 Core。只借鉴目录扫描与 `p.isWithin` 路径校验思路。

## 4. 陪伴行为层调研

> 来源：行为层调研笔记。许可均用 GitHub API `GET /repos/{owner}/{repo}/license` 读取（2026-11-25），源码在固定提交读取，行号对应该提交。上游大多运行在 pixi-live2d-display + 官方 Core 之上：**本应用只改编算法与常数，不引入它们的运行时**；改编时保留原版权与许可声明。

### 4.0 来源与许可

| 项目 | 许可 | 提交 | 可改编的内容 |
|---|---|---|---|
| [moeru-ai/airi](https://github.com/moeru-ai/airi) | MIT | `68b35a7b4e7f` | 口型插件（更新间隔、lerp 窗口、200 ms 释放 + 500 ms 交接）、乘法式自动眨眼、非对称呼吸曲线、眼球扫视概率表、参数弹簧、情绪标记 → motion 组 |
| [morettt/my-neuro](https://github.com/morettt/my-neuro) | MIT；`runtime.js` 注明改编自 N.E.K.O（Apache-2.0），两份声明都要保留 | `c9ec73f81492` | 渲染前最后写入钩子、motion 驱动嘴 / 眼时让位（差分阈值 0.001）、眨眼状态机常数、呼吸兜底、空闲微动作调度、面部微动（屏蔽眼 / 嘴参数）、无音频时的文本口型、带 load token 与回滚的换模 |
| [Project-N-E-K-O/N.E.K.O](https://github.com/Project-N-E-K-O/N.E.K.O) | Apache-2.0（保留版权 / NOTICE 并标注修改） | `4f7c2d698538` | EyeBlink 组校验 + 正则自动扫描、`LIPSYNC_PARAMS`（MouthForm 不参与振幅）、按模型 token 安装嘴部覆盖、逐参数滑条编辑器 |
| [guansss/pixi-live2d-display](https://github.com/guansss/pixi-live2d-display) | MIT | `31317b37d5e2` | `FocusController`（加速度受限的视线跟随）、`MotionState` 优先级规则、每帧更新顺序、销毁顺序 |
| [RaSan147/pixi-live2d-display](https://github.com/RaSan147/pixi-live2d-display)（带口型的 fork） | MIT | `6c2645fb566c` | `SoundManager` 的 Analyser 常数、`mouthSync` 权重（不采用其 0.4 下限） |
| [chyinan/Kokoro-Engine](https://github.com/chyinan/Kokoro-Engine) | MIT（仓库内 `public/live2dcubismcore.min.js` 是专有 Core，不得复制） | `0272b2f00901` | `LipSyncProcessor`：gain 2.0、门限 0.01、帧率无关 EMA，同时输出 MouthOpenY 与 MouthForm |
| [pixiv/ChatVRM](https://github.com/pixiv/ChatVRM) | MIT | `b542aa00e19d` | `lipSync.ts` 的 sigmoid 音量映射 |
| [mrxz/wLipSync](https://github.com/mrxz/wLipSync) | MIT | `177f3ac4095d` | AudioWorklet + WASM 的 MFCC 元音识别（uLipSync 移植）；profile 需在 Unity 的 uLipSync 中制作 |
| [hecomi/uLipSync](https://github.com/hecomi/uLipSync) | MIT | `060587907655` | MFCC 管线常数、对数音量归一化 |
| [renpy/renpy](https://github.com/renpy/renpy) | API 未识别仓库许可；`renpy/gl2/live2d*.py`、`gl2physics.pxd` 文件头为 MIT 许可文本 | `24be485cfff8` | motion3 曲线求值（Linear / Bezier / Step / InverseStep + 余弦淡入淡出）、pose3 交叉淡化（缺省 0.5 s）、exp3、physics3 摆锤物理；`live2dpose.py` 注释称「参照 CubismPose 的行为」，改编前须人工确认不是逐行翻译（未核实） |
| [Open-LLM-VTuber/Open-LLM-VTuber](https://github.com/Open-LLM-VTuber/Open-LLM-VTuber) | LICENSE 写明后端代码 MIT（API 为 NOASSERTION）；自带示例模型另受 `LICENSE-Live2D.md` 约束 | `992309c0aa19` | 后端按 20 ms 切片计算 RMS、随音频下发 `volumes` 数组的协议；`emotionMap` + `[keyword]` 提示词（只取思路，示例模型不分发） |
| 格式与映射资料 | [Live2D/CubismSpecs](https://github.com/Live2D/CubismSpecs)：无 LICENSE 文件；[DenchiSoft/VTubeStudio](https://github.com/DenchiSoft/VTubeStudio)：MIT（仅 API 文档，应用闭源）；[erodozer/open-vt](https://github.com/erodozer/open-vt)、[moonrailgun/vtubeleaf](https://github.com/moonrailgun/vtubeleaf)：MIT | `e2de04dd4514`；`edc695a39ebc`；`8ca92ac4b335`；`44efb840b6cf` | model3 / motion3 / exp3 / physics3 / pose3 / cdi3 / motionsync3 格式说明（当公开文档读，schema 不放进仓库，建议）；`.vtube.json` 的输入参数名与映射概念、open-vt 的 Godot 加载器、vtubeleaf 的 `docs/VTS-COMPATIBILITY.md` |

只作行为基准或排除（不复制代码）：

- [Live2D/CubismWebFramework](https://github.com/Live2D/CubismWebFramework)（`d4da0aa07e47`）、[Live2D/CubismWebSamples](https://github.com/Live2D/CubismWebSamples)（`b1de66b0b1f1`）：Live2D Open Software License（非 SPDX，API 为 NOASSERTION）。只描述其眨眼、呼吸、视线、淡入淡出、优先级、表情混合、物理常数与更新顺序作为行为基准，**不复制、不打包**；示例代码与示例模型同样不用。
- [Open-LLM-VTuber/Open-LLM-VTuber-Web](https://github.com/Open-LLM-VTuber/Open-LLM-VTuber-Web)（`d176e7df2366`）：「Open-LLM-VTuber License 1.0」= Apache-2.0 + 附加条件（部分商用需另行授权，API 为 NOASSERTION），且 `WebSDK/src/lapp*.ts` 是 Live2D 示例代码。只参考行为：句首随机播 `Talk` motion、LipSync 组为空时回退 `ParamMouthOpenY`（`lappmodel.ts` L374-398）、整套 SDK 重建式换模。
- [Voine/ChatWaifu_Mobile](https://github.com/Voine/ChatWaifu_Mobile)（`14092ac66c2a`）：仓库 MIT（文件名 `LICENCE`），但内含 OVRLipSync（Oculus Audio SDK License 3.3）与 Live2D 原生示例（Live2D Open Software License），这两部分不复制；可参考 Kotlin 胶水与「每 10 ms 一帧 viseme → `ParamMouthForm` / `ParamMouthOpenY`，口型权重 0.8」。
- [ltarcher/flutter_live2d_lipsync](https://github.com/ltarcher/flutter_live2d_lipsync)（`c5d69ed5403c`）：LICENSE 是未填写的模板（未授予任何权利），且打包 `Live2DCubismCore.aar`；只参考 MethodChannel 接口形状（`initializeModel / updateLipSync(audioLevel) / renderModel / setParameter`）。
- [elevenyellow/handcrafted-persona-engine](https://github.com/elevenyellow/handcrafted-persona-engine)（`a709b18b235c`）：无许可证，不复制。
- [Zao-chen/ZcChat](https://github.com/Zao-chen/ZcChat)（`fce55035d7b0`）：GPL-3.0，排除（会传染客户端），不阅读、不借鉴代码。
- [TEN-framework/ten-framework](https://github.com/TEN-framework/ten-framework)（NOASSERTION，`2d27237b5929`）：只用公开样本 `memu_cat.vtube.json` 核对 `.vtube.json` 格式。
- 许可已核实、代码未分析（未核实）：[DD-MASTERT/AI-Girlfriend-Desktop-Pet](https://github.com/DD-MASTERT/AI-Girlfriend-Desktop-Pet)（MIT，`3a5e04e5928a`）、[kiyotakali/Miru](https://github.com/kiyotakali/Miru)（Apache-2.0，`cbea20b436a2`）、[InariNGT-Ofiicial/jingyu-live2d-agent](https://github.com/InariNGT-Ofiicial/jingyu-live2d-agent)（MIT，`b5a64a1ab5c6`，其 `vts_adapter.py` 读取 VTS 映射）。

### 4.1 每帧分层与让位（建议）

- 每帧从默认值重算：motion（含淡入淡出）→ expression（Add / Multiply / Overwrite）→ 视线、呼吸、微动（叠加）→ 眨眼（乘法）→ 口型（说话时覆盖张嘴参数）→ physics → pose。
- motion 曲线自己在驱动眼或嘴时，程序化眨眼与口型让位：沿用 my-neuro 的差分检测（`LIPSYNC_OVERRIDE_THRESHOLD = 0.001`）。
- 所有程序化写入集中到「渲染前最后写入」一个钩子（my-neuro / N.E.K.O）；每帧顺序参照 pixi-live2d-display。
- 上游顺序（仅作参照）：Cubism 官方示例（OLV-Web 中的 `lappmodel.ts` 副本 L556-637）为 loadParameters → motion / idle → saveParameters → 眨眼（本帧无 motion 更新时）→ expression → 拖拽 → 呼吸 → physics → 口型 → pose → `model.update`；pixi-live2d-display（`Cubism4InternalModel.ts` L195-237）为 motion → saveParameters → expression → 眨眼 → focus → 呼吸 → physics → pose → `model.update` → loadParameters。
- airi 按插件阶段排序（`Model.vue` L479-507）：pre（beatSync、idleDisable）→ post（idleFocus）→ final（expression、眨眼、lightSquint、手动、beat、口型、呼吸、触摸）。
- my-neuro `runtime.js`：钩子 1 包住 `motionManager.update`，前后快照嘴 / 眼参数，差值 > 0.001 即判定 motion 在驱动（L121-175）；钩子 2 包住 `coreModel.update`，作为渲染前最后写入（L177-223）；帧间隔上限 100 ms。

### 4.2 眨眼

- 基准（Cubism Framework `cubismeyeblink.ts` L165-171、L190-193，仅描述）：间隔 4.0 s，闭眼 0.1 s、闭合 0.05 s、睁眼 0.15 s，线性；下次 = now + r·(2·间隔 − 1)，即 U(0, 7) s。
- airi（`motion-manager.ts` L317-410）：间隔 U(3, 8) s，闭眼 75 ms（easeOutQuad），睁眼 U(150, 300) ms（easeInQuad）；结果乘到眨眼前的值上（保留表情造成的眯眼），排在 expression 之后。
- my-neuro（`runtime.js` L28-33、L353-396）：间隔 2–6 s，闭 70 / 合 50 / 睁 110 ms 的线性状态机；只在模型没有 SDK 眨眼时启用（L96-97）。
- N.E.K.O（`live2d-model.js`）：先校验 model3 `Groups` 中 `Target = Parameter`、`Name = EyeBlink` 的 `Ids`（L1659-1720）；为空时按正则扫描参数 ID（排除 mouth / eyeball / angle 等，含日文写法，L1877-1926），按参数 min / max 定睁 / 闭值（L1789-1800），仍找不到就禁用眨眼；状态机保持 2–6 s、闭 0.08 s（easeInCubic）、睁 0.15 s（easeOutCubic）。
- 改编（建议）：EyeBlink 组优先，扫描结果只作提议、由用户确认；采用 airi 的乘法写入；motion 曲线驱动眼睛时让位（4.1）。

### 4.3 呼吸

- 基准（Cubism `cubismbreath.ts` L56-65，仅描述）：参数 += offset + peak·sin(2πt / cycle)，再乘 weight；官方示例表（OLV-Web `lappmodel.ts` L286-314）让 AngleX / Y / Z、BodyAngleX、Breath 以 3.2–15.5 s 的不同周期同时摆动。
- pixi-live2d-display（`Cubism4InternalModel.ts` L87-92）只登记 ParamBreath：offset 0、peak 0.5、周期 3.2345 s、weight 0.5。
- airi（`motion-control.ts` L99-213 `sampleLive2DBreath`）：周期 2 s、呼气后停留 1.2 s、范围 0–0.5、吸气占 0.4，半余弦吸 / 呼；同时删除 SDK 自带呼吸（`Model.vue` L403），避免叠加。
- my-neuro（`runtime.js`）兜底：ParamBreath = 0.5 + 0.5·sin(2πt / 3.2 s)，仅在模型无 SDK 呼吸时启用。
- 改编（建议）：同一时刻只有一个呼吸源；ParamBreath 用 airi 曲线或 pixi 正弦；头身角度的慢摆单独开关，幅度按模型取值范围缩放，Cubism 示例表只作量级参考。

### 4.4 视线与拖拽

- 基准（Cubism `cubismtargetpoint.ts` L42-116、`cubismlook.ts` L64-68，仅描述）：faceParamMaxV = 40 / 10，按 30 fps 换算每帧最大速度，0.15 s 加速到最大并带制动；参数增量 = factorX·dragX + factorY·dragY + factorXY·dragX·dragY。
- pixi-live2d-display（`FocusController.ts` L4-77）：EPSILON 0.01、MAX_SPEED = 40 / 7.5（每秒）、加速时间 0.15 s、制动速度 maxV = 0.5·(√(maxA² + 8·maxA·d) − maxA)；`Cubism4InternalModel.ts` L240-248 把焦点写成 EyeBall += f、Angle += f·30、AngleZ += fx·fy·(−30)、BodyAngleX += fx·10。MIT，可直接改编。
- airi：空闲扫视间隔 800–4400 ms（步长 400 ms 另加 U(0, 400)，各档概率 7.5 / 11 / 12.5 / 14 / 12.5 / 5 / 4 / 3 / 2 / 28.5 %，`eye-motions.ts` L1-32）；把 idle motion 里的 EyeBall 曲线改名交给视线插件（`Model.vue` L451-463）；只在 idle motion 且无跟踪输入时扫视（`motion-manager.ts` L304-315）；参数弹簧 k = 30 + follow·190、m = 0.75 + inertia·2.25、ζ = 1 − inertia·0.75、单步上限 1/120 s（`motion-control-spring.ts` L23-83）。
- my-neuro（`runtime.js` L400-428）：指针 → rAF → `model.focus(anchor + (pointer − anchor)·0.3)`，anchor = (模型中心 x, y + 0.3·高度)。
- 改编（建议）：Android 上以触摸拖拽代替鼠标跟随，松手后回中；无交互时用 airi 扫视表；焦点平滑用 FocusController。

### 4.5 口型

- 输入（建议）：TTS 由 Flutter 播放，WebView 接触不到这路音频；主路径是 Flutter 侧按 20 ms 一帧计算 RMS 包络（与 Open-LLM-VTuber 后端的 20 ms 切片一致），批量经 JS 通道送入 WebView，并附播放位置用于对齐。
- WebView 侧：attack / release 平滑、门限、gamma，说话结束后 200 ms 平滑释放（airi）；可参考 Kokoro-Engine 的帧率无关 EMA、ChatVRM 的 sigmoid 映射。
- Web Audio（`AnalyserNode` / `AudioWorklet` + wLipSync）只在音频本身由 WebView 播放时才划算。
- airi（`model-driver-lipsync/src/live2d/index.ts`）：wLipSync AudioWorklet，AEIOUS 合并为 AEIOU（S 记作 I），amp = min(volume·0.9, 1)^0.7、上限 0.7，取最大元音权重为张嘴值；库缺省更新间隔 40 ms、lerp 窗口 120 ms，`Stage.vue` L207 改为 50 / 50；说话时写 ParamMouthOpenY，停止后 200 ms smoothstep 混回 motion 值，随后 500 ms 交接期强制为 0（`motion-manager.ts` L791-840）。
- Kokoro-Engine（`LipSyncProcessor.ts` L3-15、L49-58、L79-102）：gain 2.0、门限 0.01、smoothing 0.25，factor = 1 − exp(−smoothing·dt·60) 的帧率无关 EMA，< 0.001 归零并叠加微小正弦；同时输出 MouthOpenY 与 MouthForm（−1 宽 … +1 圆）。
- ChatVRM（`lipSync.ts` L3-31）：时域 2048 点取峰值 v，v = 1 / (1 + e^(−45v + 5))，< 0.1 归零。
- my-neuro：`AnalyserNode` fftSize 256，张嘴 = (频谱均值 / 256)^0.8（`tts-playback-engine.js` L55-57、L261-282）；`setMouth` 限幅 0–1.5、EMA 系数 0.5、< 0.01 归零（`runtime.js` L343-349）；无音频时由文本驱动：时长 min(3000, 字符数·90 + 180) ms，每 50 ms 张嘴 = 0.12 + 0.5·|sin(7πt)|（`text-mouth-driver.js` L10-32）。
- RaSan147 fork（`SoundManager.ts` L107-142、`Cubism4InternalModel.ts` L229-242）：fftSize 256、minDecibels −90、maxDecibels −10、smoothingTimeConstant 0.85，权重 0.8；其 0.4 下限使有声时嘴至少半张，不采用。uLipSync 的对数归一化 clamp((log10(RMS) + 2.5) / 1.0, 0, 1)（`uLipSync.cs` L248-253，RMS 0.00316 → 0、0.0316 → 1）可直接用于 RMS 包络。
- Open-LLM-VTuber 后端（`stream_audio.py` L8-24、L27-82）：20 ms 切片求 RMS，按整句峰值归一化到 0–1，以 `volumes` + `slice_length: 20` 随音频下发；其 Web 前端实际在 JS 里重解码 WAV 求 RMS，不跟随 `audio.currentTime`（可能漂移），后端 `volumes` 似乎没有用上（未核实）。
- 平台：MDN browser-compat-data v4.1.13 将 `webview_android` 列为支持 `AudioWorkletProcessor`；AudioWorklet 需要安全上下文（wLipSync README L52），`https://appassets.androidplatform.net` 应满足（推论）。音素级口型（Azure TTS 的 22 个 viseme，0 为静音；edge-tts `WordBoundary` 以 100 ns 为单位的 offset / duration）列为后续选项，未评估。

### 4.6 表情

- exp3 的 Add / Multiply / Overwrite 混合，参考 Ren'Py 的 exp3 实现；情绪 → 表情 / motion：airi 的情绪标记 → motion 组、Open-LLM-VTuber 的 `emotionMap` + `[keyword]`。
- 基准（Cubism `cubismexpressionmotion.ts` L16-34、L267-284，仅描述）：缺省淡入 / 淡出 1.0 s；`Blend` 缺省为 Add（中性值 0），Multiply 中性值 1，Overwrite 直接覆盖；字段见 CubismSpecs 的 exp3 说明。
- airi（`expressions.ts` L205-256）：每帧在 motion 之后应用：Add → 默认值 + value，Multiply → 当前值·value，Overwrite → value；本帧未激活的参数恢复默认；`duration`（秒）到期复位；没有淡入淡出（未核实）。
- airi 情绪协议：LLM 输出 `<|ACT {json}|>`，规整为 `{emotion: {name, intensity}, expression: {name, duration} 或 null, motion}`（`act.ts`、`payloads.ts`）；显式 motion 优先，否则情绪落到同名 motion 组（Happy、Sad、Angry、Think、Surprise、Awkward、Question、Curious，neutral → Idle；`emotions.ts`、`Stage.vue` L319-355）；`<|DELAY n|>` 控制停顿。
- Open-LLM-VTuber：`model_dict.json` 的 `emotionMap`（情绪 → 表情索引）配合提示词中的 `[keyword]` 标签；Web 前端复位时回到 `defaultEmotion`，否则表情 0（`use-live2d-expression.ts` L43-75，只参考行为）。
- 改编（建议）：LLM 只输出受控的情绪标签；每个模型的「情绪 → 表情 / motion」映射在向导中由用户确认、存在本设备；淡入淡出读 exp3 的 `FadeInTime` / `FadeOutTime`。

### 4.7 动作

- Ren'Py 的 motion3 曲线求值与余弦淡入淡出；pixi-live2d-display 的 `MotionState` 优先级；Open-LLM-VTuber-Web 句首随机播 `Talk` motion（只参考行为）。
- 基准（Cubism，仅描述）：motion3 的 `FadeInTime` / `FadeOutTime` 缺失或 < 0 时取 1.0 s，并可逐曲线覆盖（`cubismmotion.ts` L533-561、L883-893）；混合权重 = weight·sineEase(淡入)·sineEase(淡出)（`acubismmotion.ts` L134-168）；优先级 None 0 / Idle 1 / Normal 2 / Force 3，优先级不高于当前或已预约者时预约失败（`cubismmotionmanager.ts` L62-111）。
- pixi-live2d-display（`MotionState.ts`）：同样四级；有 motion 在播或已预约 idle 时不启动新 idle —— 可直接改编。
- OLV-Web（只参考行为）：句首随机播 `Talk` 组、优先级 Normal（`use-audio-task.ts` L138-147）；motion 结束后随机播 Idle 组（`lappmodel.ts` L558-563）。

### 4.8 物理

- Ren'Py 的 physics3 摆锤实现（`gl2physics.pxd`，MIT 文件头）；CubismWebFramework 的物理常数与更新顺序只作基准；PurismCore raylib viewer 不含物理（见 2.2）。
- 基准（Cubism `cubismphysics.ts`，仅描述）：空气阻力 5.0、最大权重 100、移动阈值 0.001、最大 dt 5.0（L30-39）；固定步长 1 / Fps，余量累积并插值输出（L509-552）；载入后先 `stabilization()`（L281）。

### 4.9 空闲调度

- my-neuro（`idle-action-scheduler.js`）：带冷却的加权微动作（slow_nod 14 s、head_tilt 16 s、glance_side 10 s、weight_shift 18 s、lean_in 20 s、settle_back 20 s、sigh 26 s、slow_blink 9 s），间隔 U(7, 19) s，`avoid_repeat_window` 4，并按情绪 VAD（valence / arousal / dominance）调整权重。
- my-neuro（`face-micro-motion.js`）：永不写 ParamEyeLOpen / ParamEyeROpen / ParamMouthOpenY；空闲时以 0.86 / 1.34 / 0.47 rad/s 的正弦叠加极小偏移（MouthForm 0.026、Brow 0.024、EyeSmile 0.02），外加 0.45–1.05 s 正弦包络的脉冲；说话时缩小 MouthForm 偏移，让位口型。
- airi（`motion-manager.ts` L280-315）：关闭 idle 动画时停掉全部 motion、SDK 眨眼与 idle 视线（IdleDisable）；IdleFocus 见 4.4。
- 改编（建议）：模型有 Idle 组时按 Idle 优先级循环播放，否则只用程序化呼吸、眨眼、扫视与微动作；应用进入后台或页面不可见时暂停 rAF。

### 4.10 热切换（建议）

- 单 WebGL 上下文 + 单 WASM 实例：Chromium 在活跃上下文超限时强制丢弃最旧的上下文（见 3.4），WASM 线性内存只增不减。
- 新模型在后台解析、逐张上传纹理，旧模型照常渲染；在语音停顿处用 200–300 ms 淡出 / 淡入完成交换，随后立即释放旧纹理与旧 moc / model 内存；任一步失败都保留旧模型（my-neuro 的 load token 与回滚）。
- airi（`Model.vue` L311、L315-396）：加载互斥；先销毁旧模型（连同纹理）再加载新模型，加载期间空白，但内存峰值只有一份；src 已过期或组件卸载时销毁新模型；整个会话复用同一个 PIXI Application（`Canvas.vue` L79-89）。
- my-neuro（`model-loader.js` L31-110）：加载锁 + load token；新模型接好后才销毁旧模型（可回滚，但峰值两份内存）；失败时销毁候选、恢复旧模型，并只尝试一次 fallbackPath。
- N.E.K.O（`installMouthOverride`，L3000-3046）：先恢复上一个模型的钩子，再按模型 token 安装覆盖，绝不把旧模型的方法绑到新模型。
- 改编（建议）：纹理预算容得下两份时用 my-neuro 式（可回滚）；否则用 airi 式，先卸载旧模型、期间显示 VRM 或占位；释放顺序参考 pixi-live2d-display（先 renderer 后 core model，`Cubism4InternalModel.ts` L272-276）。WASM 线性内存只增不减（[WebAssembly memory-control 提案](https://github.com/WebAssembly/memory-control/blob/main/proposals/memory-control/Overview.md)），多次换模后的内存问题见第 6 节。

### 4.11 参数映射

- 自动提议顺序（建议）：用户确认 > model3 `Groups` > `.vtube.json` 映射行 > 标准 ID > `cdi3.json` 显示名 > 取值范围启发式。LipSync 组为空时，上游通行做法是回退 `ParamMouthOpenY`（见 4.0 Open-LLM-VTuber-Web）；若模型附带 VTube Studio 的 `.vtube.json`，其中 `Input = MouthOpen` 一行的 `OutputLive2D` 是张嘴参数的有力线索。
- 向导（建议）：按 ID、`cdi3.json` 显示名（中 / 日 / 英正则）、取值范围三路打分，识别嘴、眼、头部角度、眼球、眉、呼吸参数；用户可改，配实时滑条与「测试眨眼 / 测试说话 / 测试表情」；逐项校验通过才启用对应行为，某项失败只禁用该项；模型无法加载时回退默认 VRM。逐参数滑条参考 N.E.K.O。
- 依据：model3 `Groups` 中 `Name` 为 `EyeBlink` / `LipSync` 的 `Ids`（Cubism `cubismmodelsettingjson.ts` L408-515；CubismSpecs 规定 `Target`、`Name`、`Ids` 必填）；标准 ID（`cubismdefaultparameterid.ts` L23-62）；[Live2D 标准参数表](https://docs.live2d.com/en/cubism-editor-manual/standard-parametor-list/) 给出范围：AngleX / Y / Z −30…30，EyeL/ROpen 0…1（上限可放到 1.5 或 2），EyeBallX / Y −1…1，Brow −1…1，MouthForm −1…1，MouthOpenY 0…1（上限可到 1.5），BodyAngleX / Y / Z −10…10，Breath 0…1；`cdi3.json` 提供参数与参数组的 `{Id, GroupId, Name}` 显示名。
- 上游做法：airi 硬编码 ParamMouthOpenY，并按模型把参数存进 localStorage（`Model.vue` L404、`model-parameters.ts` L68）；my-neuro 也不读 `Groups`，用硬编码 ID 列表，以 `getParameterIndex` 缓存索引并回查 `getParameterId(idx) === id`（`runtime.js` L277-339）；N.E.K.O 的口型参数为 MouthOpenY、MouthForm、MouthOpen、A、I、U、E、O，振幅不驱动 MouthForm（`live2d-core.js` L34-46）；LAPLACE 导入 `.vtube.json` 时把 `UseBlinking` 映射到 `RandomPulse1`（[laplace.live 文档](https://laplace.live/persona/live2d/bindings)）。

## 5. 适配到本应用的方案

> 5.1 是仓库基线 HEAD `913a1072b1df` 的现状；5.3 是本 PR 实现的增量 A，5.4、5.5 是增量 B 的 B1、B2；5.2 中的增量 C–E 是计划，尚未实现。

### 5.1 现有模块

- 查看器包已存在但尚未接入 Flutter 外壳，应用内预览、热切换、VRM 回退均未实现（`packages/jingyu_live2d_web/README.md`）；查看器只有 load / setParameters / dispose，模型静止，没有物理、动作、表情、眨眼、呼吸。
- 协议与状态机（`packages/jingyu_client_kit`）：`Live2DRendererBridge` 处理查看器的 `ready` / `error` / `frame` 事件（`live2d_renderer_bridge.dart` 的 `handleEvent`，L123 起）；`Live2DRendererHost` 只有 `events` 与 `send`（`live2d_renderer_controller.dart` L25-28）；`Live2DPreviewController` 只在 loading 状态处理查看器事件与宿主错误（L148-149、L166-167），预览就绪后渲染进程退出或 WebGL 上下文丢失都会被忽略。
- 查看器页面：`post()` 依次尝试 `Live2DBridge.postMessage`、`flutter_inappwebview.callHandler`、`parent.postMessage`（`live2d_viewer.js` L27-48）；应用→页面经 `window` 的 `message` 事件或 `window.__live2dReceive`（L206、L214）；每帧先 `model.update()` 再绘制（L129-139）。
- 渲染器：每帧为每个可见 drawable 重传顶点（`live2d_renderer_webgl.js` L621-636），`dynamicFlags` 只读可见位（L625-626），不调用 reset 类接口；纹理经 `Image` + `texImage2D` 上传，`LINEAR`、无 mipmap，不检查 `MAX_TEXTURE_SIZE`（L21 注释列为未处理）。
- 导入链路（Android）：`MainActivity.kt` 的 `jingyu/platform` 通道提供 `getLive2DPreviewDirectory`（返回 `cacheDir/live2d-preview`，L81）与 `pickLive2DZip`（L82）；`Live2DZipCache.kt` 限 160 MiB 并清理 24 小时前的内容；`validateLive2DPackage` 只做字节预检，`Live2DPreviewBundle` 是检查过的渲染输入，不是可渲染信号（`live2d_package.dart` L21-23）；`Live2DPreviewStage` 写出 `model.model3.json`、`model.moc3`、`texture-N.png`。导入完成后面板只显示「已准备临时预览文件，未显示或启用形象。」（`live2d_import_panel.dart` L119）。
- 设备本地数据：`Live2DModelStore` 的快照只含引用与映射，同一 modelId 只能用更大的 profileRev 覆盖（`live2d_store.dart` L1-5、L27-29）；`Live2DParamMap` 启用前要求传入运行时枚举出的完整 ID 集合（`live2d_profile.dart` L26-31），但查看器目前不回报任何 ID。
- 文档与证据：`docs/modules/M10-world.md` 记录桥接与查看器现状（L24-25），AC-25 / AC-26 未勾选（L55-57），性能目标（骁龙 888 稳定 30–60 fps）尚未实测（L38）；`apps/client_flutter/evidence/live2d-world-comparison.md` 只覆盖导入入口，不含真实渲染。

### 5.2 调研结论的落地方式

| 调研结论 | 适配到本应用 | 增量 / 状态 |
|---|---|---|
| 运行时用 PurismCore v1.1.0 Web（第 2 节） | 继续固定 v1.1.0 与 `Web.zip` 的 SHA-256（`fetch_purismcore.ps1`），运行时与 `LICENSE` 只在本地获取，Android 构建时一并复制进 APK 资源。不改用 PR #4 构建：未合并、无 review，第 4、5 个提交修的是第 2 个提交引入的回归 | 运行时已有；APK 打包属增量 A（本 PR，5.3） |
| dynamic flags 问题（2.2，issue #3） | 现有渲染器每帧重传顶点、只读可见位、不做 reset（5.1），因此不受影响（推论，依据代码阅读）。以后若按 `VERTEX_CHANGED` 跳过上传（PR #4 的 dirty skipping 思路），须等上游修复，或改用「先 reset 再 update」（Nori.Desktop 的做法） | 暂不需要改动 |
| 承载：自建 PlatformView + androidx.webkit（3.6） | 见 5.3 | 增量 A（本 PR） |
| 纹理上限（3.4）与 Mochi2D 的手机预算 256 MiB（2.3） | 全部纹理共用一个缩放比例，同时满足 `MAX_TEXTURE_SIZE` 与 256 MiB 预算（按含 mipmap 的 4/3 估算）；逐张解码、缩放、上传后立即释放。只借鉴 Mochi2D 的预算数值，不复制其代码；数值是估计，实机测量后再调整 | 增量 A（本 PR，5.3） |
| 渲染进程可能被系统杀掉（3.3），WebGL 上下文可能被强制丢失（3.4） | 预览就绪后，渲染进程退出、上下文丢失、绘制失败都转为失败状态，用户可重试；正式启用为形象后改为回退默认 VRM（增量 D） | 增量 A（本 PR，5.3） |
| 行为层与每帧分层（4.1–4.9） | 在查看器内按 4.1 的顺序实现；motion3 / exp3 / pose3 / physics3 求值优先改编 renpy 中 MIT 许可的代码（改编前人工确认不是 Cubism Framework 的逐行翻译，见 4.0）；眨眼、呼吸、视线、口型改编 airi、my-neuro、N.E.K.O、pixi-live2d-display、Kokoro-Engine。改编文件保留原版权与许可声明，README 列出来源 | 增量 C（建议） |
| 参数映射与持久化（4.11） | 查看器加载模型后回报参数 / part ID，供 `Live2DParamMap` 校验；向导按 4.11 打分，逐项校验通过才启用对应行为；模型改存到应用私有的持久目录，保存与启用各需用户确认 | 增量 B：回报 ID 与口型 / 眨眼建议（B1，5.4），本机保存、向导与启用（B2，5.5，仅 Android）已实现；B2 按 D1-B 整体核对，任一映射目标缺失即不启用；4.11 的打分与 `cdi3.json` 显示名未做 |
| 热切换（4.10） | 整页只保留一个 WebGL 上下文并复用；预算容得下两份时可回滚（my-neuro 式），否则先卸载旧模型（airi 式）；任何失败都回退默认 VRM | 增量 D（建议） |
| 验证（3.5、M10 性能目标） | 本地 AVD 关闭了 GPU，WebGL 结果须在开启 GPU 的模拟器或真机上复核；帧率与显存按 M10 目标在真机实测，测前文档只写估计 | 增量 E |

### 5.3 增量 A：本 PR 的实现

> 以下内容已在本 PR 实现；验证范围见本节末尾，均未在真机上运行。

- **查看器页面**（`packages/jingyu_live2d_web/web/live2d_viewer.js`）：
  - 脚本加载后先发一次 `boot`：Android 宿主收到页面的第一条消息后才有回复代理，宿主命令随后经 `Live2DBridge` 的 `message` 事件到达。
  - `error` 事件带 `code`：`load_failed`、`render_failed`、`webgl_context_lost`、`bad_command`。
  - 就绪后某帧更新或绘制抛错、画布丢失 WebGL 上下文时，释放模型、停止帧循环并报错。`webglcontextlost` 中调用 `preventDefault()`，否则浏览器不会恢复上下文（Khronos WebGL wiki「HandlingContextLost」）；上下文恢复前，新的 `load` 都以 `webgl_context_lost` 失败。
- **纹理预算**（`live2d_texture_budget.js`、`live2d_renderer_webgl.js`）：按 5.2 的设计实现；`prepare()` 回报 `textureScale`、`maxTextureSize`、`textureBytes`（估算值）与 `textureCount`；WebGL1 只对 2 的幂尺寸生成 mipmap。
- **Android 承载**（`apps/client_flutter/android`）：
  - `Live2DViewPlugin` 在 `MainActivity.configureFlutterEngine` 中注册平台视图 `jingyu/live2d_view`。每个视图是一个 `Live2DPlatformView`，内含一个 WebView，经 `MethodChannel('jingyu/live2d_view/<id>')` 与 Dart 通信。
  - 资源经 `WebViewAssetLoader` 在 `https://appassets.androidplatform.net` 下提供，不开文件访问（3.6）。`/live2d/viewer/` 只提供白名单内的查看器文件（来自安装包资源）；`/live2d/model/<令牌>/` 只提供 `serve` 登记过的暂存目录中的文件。令牌为 128 位随机数，目录必须在 `cacheDir/live2d-preview` 之内；路径规范化后再检查，`..`、绝对路径与指向目录外的符号链接都返回 403。未匹配的请求一律 403，不会落到网络。路由规则放在不依赖 Android 的 `Live2DViewerRoutes` 中，用 JVM 单元测试覆盖。
  - 页面→宿主用 `WebViewCompat.addWebMessageListener`，只接受查看器源的主框架消息；宿主→页面用页面消息带来的 `JavaScriptReplyProxy`。页面重新加载后、新页面发出第一条消息前，`post` 返回 `not_ready`，Dart 侧保留命令，等页面再次 `boot` 后发送。
  - 原生发往 Dart 的调用（页面消息、`pageError`、`renderProcessGone`）都等 Dart 第一次调用之后才发出，避免 Dart 尚未设置处理器时丢失。
  - `onRenderProcessGone` 返回 `true`，销毁该 WebView 并通知 Dart；宿主进入终态，预览转为失败，重试时新建平台视图（3.3）。系统 WebView 不可用或不支持 WebMessageListener 时报 `pageError`。
  - 构建时 Gradle 任务 `syncLive2DViewerAssets<变体>`（`app/build.gradle.kts`，用 AGP Sources API 的 `addGeneratedSourceDirectory`）把查看器文件与本地已拉取的运行时复制进安装包的 `live2d/viewer/`。缺少页面文件时构建失败；缺少运行时只告警，此时预览会报错。依赖 `androidx.webkit:webkit:1.18.0`。
- **Flutter 侧**（`apps/client_flutter/lib/features/world`、`packages/jingyu_client_kit`）：
  - `AndroidLive2DRendererHost`：每个平台视图一个 `MethodChannel('jingyu/live2d_view/<id>')`；`serve` 为暂存目录换取页面可访问的 URL，`post` 发送命令，并接收 `message`、`pageError` 与 `renderProcessGone`。
  - `Live2DPreviewView`：用 `AndroidView` 显示查看器，带加载与失败遮罩，失败后可重试。
  - `Live2DPreviewController`：就绪后收到查看器的 `error` 或宿主通道出错时转为失败状态，补上 5.1 所述的缺口。
  - 导入面板：Android 上暂存完成后显示预览卡片，文案改为「仅本机临时预览，未启用形象。」；其他平台不显示预览，文案不变。
- **验证范围**：
  - 查看器与纹理预算在 Node 的 VM 沙箱中用假 PurismCore、假 GL 测试（`test/viewer_behavior.test.cjs`、`test/texture_budget.test.cjs`）。
  - Flutter 侧用模拟平台通道测试（`apps/client_flutter/test/android_live2d_renderer_host_test.dart`、`live2d_preview_view_test.dart` 与控制器测试）。
  - Android 端：路由规则用 JVM 单元测试覆盖（`app/src/test/kotlin/com/jingyu/client_flutter/Live2DViewerRoutesTest.kt`，8 项；符号链接逃逸一项需要能创建符号链接的系统，在 Windows 上跳过）。`flutter build apk --debug` 通过，安装包的 `assets/live2d/viewer/` 含 4 个页面文件和本地拉取的运行时及其 `LICENSE`。
  - 帧率、显存、画质，以及与 3D 房间同时打开时的上下文占用，都未在真机上测量（增量 E、6.2）。

### 5.4 增量 B 第一步（B1）：模型信息与映射建议

> 以下内容已在本 PR 实现；B1 本身没有界面，不构建、不保存、也不启用映射（这些见 5.5）。验证范围见本节末尾，均未在真机上运行。

- **查看器回报模型信息**（`live2d_viewer.js`）：首帧成功后，`ready` 事件附带运行时枚举的 `parameters`（运行时顺序，每项 `{id, min, max, default}`，取值只在是有限数时给出）与 `parts`（part ID）。每个列表要么完整，要么省略：来源缺失、格式不对或超过 4096 项时省略该字段。列表在首帧之后读取，读取出错只省略字段，不会让加载失败，也不改变 `ready` 的时机。
- **client kit 解析**（`Live2DModelInfo`）：`Live2DRendererBridge` 收到 `ready` 时解析，`Live2DPreviewController.modelInfo` 只在就绪状态下有值。字段格式不对时（不是列表、超过 4096 项、ID 为空或超过 256 个字符、ID 重复、取值不是有限数、最小值大于最大值）只记录 `modelInfoError`：预览照常就绪，但没有 ID 集合，映射也就无法启用。5.1 所说的缺口由此补上：`Live2DParamMap` 启用前要求的完整 ID 集合现在来自运行时（启用流程见 5.5）。
- **读取 model3 `Groups`**（`validateLive2DPackage`）：预检通过时，把清单的 `Groups` 按文件顺序读进 `Live2DPackageValidation.groups`，再随 `Live2DPreviewBundle` 交给预览；生成的清单不写出它们。`Groups` 只供建议，不会让预检失败：不是对象、或 `Name` 为空或超过 256 个字符的条目跳过，不合格的 ID 也跳过；`Groups` 不是列表，或条目总数、ID 总数超过 4096 时，整体不读。不保留 `Target`：Cubism Framework 查找 `EyeBlink` / `LipSync` 组时只比较 `Name`、取第一个同名组，不读取 `Target`（CubismWebFramework @ `d4da0aa07e47` 的 `cubismmodelsettingjson.ts` L408-517）。
- **映射建议**（`Live2DParamProposal.forModel`）：为 `Live2DParamMap` 的 `mouthOpen`、`blinkLeft`、`blinkRight` 三个槽给出建议，候选只来自运行时回报的参数 ID，按原样精确匹配。证据由强到弱：
  1. 第一个名为 `LipSync` / `EyeBlink` 的组，查找方式与 Cubism Framework 相同；只算运行时回报过的 ID，组里没有这样的 ID 时忽略该组。
  2. 标准 ID `ParamMouthOpenY`、`ParamEyeLOpen`、`ParamEyeROpen`（4.11）。
  3. 它们的 Cubism 2 写法 `PARAM_MOUTH_OPEN_Y`、`PARAM_EYE_L_OPEN`、`PARAM_EYE_R_OPEN`。官方示例 Wanko 的参数就用这种写法（CubismWebSamples @ `b1de66b0b1f1` 的 `Wanko.model3.json`，`Groups` 在 L32-48）；hacxy/l2d-widget（MIT）@ `6a7b63d414d5` 也以 `PARAM_MOUTH_OPEN_Y` 作口型参数的示例（`src/types.ts` L52、L55）。
- **取舍**：
  - 组优先于组外的标准 ID。口型取 `LipSync` 组里的标准 ID（含 Cubism 2 写法），没有就取组里第一个 ID。
  - `EyeBlink` 组不标明哪个 ID 属于哪只眼：组里某个 ID 是该眼的标准 ID（含 Cubism 2 写法），或者去掉另一只眼的标准 ID 后只剩一个 ID 时，才给该眼建议；否则不给，由用户选。
  - 没有可用的组时回退标准 ID；LipSync 组为空时回退 `ParamMouthOpenY` 也是上游的通行做法（4.11）。
  - 4.11 中的 `.vtube.json`、`cdi3.json` 显示名与取值范围启发式未做，5.5 的映射向导只用这里的建议作预选；表情与动作不在建议之列。
- **验证范围**：
  - 查看器：`node --test` 跑 `test/viewer_behavior.test.cjs` 24 项（含 `ready` 附带的列表）、`test/texture_budget.test.cjs` 16 项。
  - client kit：`live2d_model_info_test` 9 项、`live2d_renderer_bridge_test` 16 项、`live2d_renderer_controller_test` 19 项、`live2d_package_test` 37 项、`live2d_param_proposal_test` 14 项；全套 375 项通过，`flutter analyze` 无问题。
  - 应用：Live2D 相关的 4 个测试文件 35 项通过，`flutter analyze` 无问题。
  - 没有用真实模型在设备上核对回报的 ID 与建议。

### 5.5 增量 B 第二步（B2）：本机保存、映射向导与启用

> 以下内容已在本 PR 实现，仅限 Android。负责人 2026-11-26 同意 D1-B：口型与左右眨眼必填；表情、动作可以为空，但须用户确认「此模型没有」。表情键按默认方案 D2-A，用 VRM 1.0 情绪预设加 `neutral`。验证范围见本节末尾，均未在真机上运行。

- **暂存表情与动作**（`live2d_package.dart`、`live2d_preview_stage.dart`）：
  - model3 `FileReferences.Expressions` 与 `Motions` 引用的 exp3 / motion3 文件按固定名 `expression-N.exp3.json`、`motion-N.motion3.json` 暂存，重建的 model3 只引用暂存成功的条目。
  - 只涉及一个条目的问题只去掉该条目，并记入 `Live2DPackageValidation.warnings`（含代码、条目序号与文件名）。这类问题包括：缺文件、表情超过 1 MiB 或动作超过 8 MiB、JSON 无效或嵌套超过 64 层、校验和不符，以及 `Name` 或组名为空、超过 256 个字符或重复、超出数量上限。去空的动作组整组去掉。MOC3、纹理与 model3 的问题仍然致命。
  - 开源查看器也这样做：逐个加载表情与动作，失败的只告警并跳过，模型照常显示（pixi-live2d-display @ `31317b37d5e2`，MIT，`src/cubism-common/ExpressionManager.ts` L75-106、`MotionManager.ts` L159-195；只参考行为，未复制代码）。
- **查看器回报**（`live2d_viewer.js`）：
  - `ready` 另附 `expressions`（加载成功的表情 `Name`，按 model3 顺序）与 `motions`（每组的 `{group, count}`）。model3 没有对应键时为空列表；格式不对或超过上限时整项省略，不影响预览。
  - 映射按 `Name` 指定表情，按组名加序号指定动作，不用文件路径。
- **本机存储**（client kit `Live2DFileStore`）：
  - 根目录是 Android 的 `noBackupFilesDir/live2d`，经 Live2D 自有的方法通道 `jingyu/live2d_store` 获取。不放 `cacheDir`，因为系统空间不足时会清理它。也不放 `filesDir`：API 31 起，部分厂商设备上 `allowBackup="false"` 挡不住设备间传输（文档结论，未实测）。
  - 布局：`models/<id>/` 存模型文件，`profiles/<id>.json` 存映射，`models.json` 列出模型与当前启用的模型。
  - 写入：模型目录先写成 `<id>.pending` 再改名，JSON 先写 `.pending` 再改名，`models.json` 是提交点；打开时清理或回滚中断的操作。
  - 删除模型时连带删除其映射。删除或替换启用中的模型，或重新保存其映射，都会清除启用。
  - `setActive` 在存储内用 `validateTargets` 对照预览回报逐项核对；有缺项时全部列出，启用状态不变。
- **Android 路由**（`Live2DViewerRoutes`）：`serve` 除临时预览目录外，只接受 `noBackupFilesDir/live2d/models/<id>` 下 ID 合法、不以 `.pending` / `.old` 结尾的目录。文件只提供 `.model3.json`、`.moc3`、`.png`、`.exp3.json`、`.motion3.json`；规范化后越界的路径仍然返回 403。
- **界面**（`apps/client_flutter/lib/features/world`）：
  - 临时预览就绪后出现「保留此模型」。它只读回暂存时写出的文件，存为新模型（显示名取 ZIP 文件名去掉扩展名），删除临时文件，再从本机目录打开预览；同一时间只显示一个预览。
  - 「本机保存的模型」列出每个模型及其状态（未设置映射 / 已保存映射 / 已启用），可设置映射、启用或停用、删除（先确认）。
  - 映射向导分三步：口型与眨眼（必填）、表情、动作。
    - 候选只来自该预览的回报。B1 的建议只作预选；保存过的选择只在预览仍回报时预选。
    - 参数滑条按回报的范围，经 `Live2DPreviewController.setParameter` 在预览里试动，松开后恢复默认值。
    - 表情与动作每个语义键一行。回报列表为空时才出现「此模型没有表情 / 动作」；模型未回报该列表时说明原因，不能保存。
    - 「确认并保存」是唯一的写入，`profileRev` 每次加一。
  - 「启用此形象」与列表里的「启用」都等该模型本机副本的预览就绪，再用它的回报核对；未通过时逐条列出缺项，模型保持未启用。
  - 文案说明启用的形象暂不在聊天或世界场景中显示。
- **桥接**：查看器按原值写入参数，`setParam` 的 0..1 限制因此改为按参数自身的单位检查。值须为有限数；模型回报了参数 ID 与范围时，ID 须在其中、值须在范围内，否则不发送。
- **验证范围**：
  - 查看器：`node --test` 跑 viewer_behavior 30 项、texture_budget 16 项。
  - client kit：全套 463 项（file_store 10、store 9、profile 93、model_info 35、package 45、bridge 19、controller 20），`dart analyze --fatal-infos` 无问题。
  - 应用：`flutter analyze` 无问题；Live2D 相关测试文件逐个运行通过（kept_models 11、mapping_wizard 9、preview_view 11、preview_stage 13、import_panel 6、store_directory 9）。
  - Android：`Live2DViewerRoutesTest` 14 项，其中 13 项通过，符号链接逃逸一项在 Windows 上跳过；`flutter build apk --debug` 通过。
  - 没有在真机上运行。
- **未做**：
  - 在聊天与世界场景中显示启用的形象。
  - 表情与动作的播放和试看（增量 C）。
  - 启动时重新核对。
  - 替换或重新导入模型、改名。
  - 热切换与 VRM 回退（增量 D）。

## 6. 风险与未决问题

### 6.1 风险

| 风险 | 依据 | 应对 |
|---|---|---|
| 应用要加载用户导入的不定数量模型，按 OSL 第 1.5 条属于 Expandable Application：使用官方 Framework / Core 需经审查并按销售付费，完全免费的应用一般不符合条件 | 2.1 | 只用 PurismCore（MIT）运行时；不使用、不移植官方 SDK 代码；运行时按固定版本与 SHA-256 拉取，不入库 |
| PurismCore 只有一名贡献者，测试规模为自报；dynamic flags 问题（issue #3）的修复尚未合并 | 2 节表格、2.2 | 固定 v1.1.0；现有渲染器不依赖变化位（5.2，推论）；升级前复核 issue #3 与 PR #4 |
| 实现来源与专利：Mochi2D 的 clean-room 记录未公开，README 提及专利；各 Core 兼容实现均未做法律评估 | 2 节表格、6.3 第 7 条 | Mochi2D 只借鉴预算数值，不复制代码；发布前需要法务确认（未决） |
| 系统杀掉渲染进程，或 WebGL 上下文被强制丢弃 | 3.3、3.4 | 预览就绪后转为失败状态，用户可重试（增量 A）；正式启用为形象后回退默认 VRM（增量 D） |
| 同一应用的多个 WebView 可能共用一个渲染进程；M10 规划的 3D 房间页面在 Android 上也用 WebView（`docs/modules/M10-world.md` L19） | 3.3 | 只清理出事的 WebView；整页只保留一个 WebGL 上下文（3.4）。两个页面同时存在时是否共用 Android 的 8 个上下文上限：推论，未核实 |
| 手机纹理预算 256 MiB 取自 Mochi2D 的默认值，是估计值；`MAX_TEXTURE_SIZE` 因设备而异（Android 上 Chromium 最多给 8192） | 2.3、3.4 | 全部纹理统一缩放，同时满足两项上限（增量 A）；实机测量后再调整预算（增量 E） |
| 部分设备禁用 WebGL2 | 3.4 | 现有渲染器先试 `webgl2`，失败再回退 `webgl`（3.4）；WebGL1 路径未在真机上验证 |
| WASM 线性内存只增不减，热切换时内存峰值可能翻倍 | 4.10 | 复用单个实例，在语音停顿处交换（建议，增量 D） |
| PurismCore 的性能数据、Mochi2D 的一致性数据、ayatsuri_2d 的 "bit-faithful" 都是自报 | 2 节表格、2.2 | 只作参考，不作为验收依据；以本应用的实机测量为准（增量 E） |

### 6.2 未决问题

1. 3D 房间页面与 Live2D 预览同时存在时，是否共用渲染进程与 Android 的 8 个 WebGL 上下文上限（见 6.1）：需要在真机上验证。
2. 专利与实现来源的法律评估（见 6.1）。
3. 纹理预算、帧率、内存、功耗都没有真机数据（增量 E）。
4. 用户导入的模型各有许可（例如 Live2D Free Material License），这些许可是否允许在本应用中显示：应用不分发模型，但未做法律评估。
5. `AndroidView` 平台视图的合成方式对 WebGL 帧率的影响未测量。

### 6.3 来源矛盾的核对结果

调研过程中记录的 8 处来源矛盾已于 2026-11-26 复核：

1. Cubism Framework 收入门槛：以 `LICENSE.md` L13 为准，严格大于 JPY 10,000,000；早先笔记写成"≥"有误（已改 2.1）。
2. PurismCore v1.1.0 没有 `Live2DCubismCore` 别名：`purismcore.js` 中这个名字只出现在 L697 的注释标题里，全局对象是 `PurismCore`（L690、L711）。所谓"兼容"指结构与标志位取值一致，不是全局名相同（2.2）。
3. WebGL 上下文上限：`chromium@9fb3a21ed95c` 的 L122-128 确认 Android 为 8、其他平台 16、worker 4（已改 3.4）。
4. ayatsuri_2d 的物理求解器：两种说法指同一个求解器，并不矛盾（2 节表格）；该项目仍因 GPL-3.0 排除。
5. Mochi2D-Native 的后端：README L38-43 与仓库描述并不矛盾；描述里的 D3D11 与 API 给出的主语言 TypeScript 未核实（2.3）。
6. ayagami 与 l2d-viewer 的许可：二者都是 MIT OR Apache-2.0 双许可，GitHub 许可 API 只返回其中一个文件（2 节表格）。
7. Mochi2D 的 clean-room 记录：仓库确实没有 `cleanroom/` 目录，记录没有公开；这是来源风险（6.1），不是笔记错误。
8. `jingyu_live2d_web` README 与 3.6 的选型不一致：本 PR 同步更新 README 与 `docs/modules/M10-world.md` 的承载说明。

## 7. 参考来源

下列链接按正文首次引用的章节分组；版本 / 提交与许可见正文对应位置（2 节表格、3.2–3.4、4.0）。截至日期为 2026-11-25；标“复核 2026-11-26”的条目已在定稿时重新核对。

**第 2 节：运行时与许可**

- PurismCore：<https://github.com/SakuraMotion/PurismCore>；PR #4：<https://github.com/SakuraMotion/PurismCore/pull/4>；fork：<https://github.com/pakholeung37/PurismCore>
- Mochi2D：<https://github.com/waifucave/Mochi2D>；Mochi2D-Native：<https://github.com/waifucave/Mochi2D-Native>（MIT，复核 2026-11-26）
- ayagami：<https://github.com/AyagamiDev/ayagami>（复核 2026-11-26）；ayatsuri_2d：<https://github.com/Ayatsuri2D/ayatsuri_2d>；Mocari：<https://github.com/Eatgrapes/Mocari>
- 依赖官方 SDK 的封装：<https://github.com/guansss/pixi-live2d-display>、<https://github.com/Heonys/live2d-web>、<https://github.com/Moebytes/live2d-renderer>、<https://github.com/Evergaster/l2d-viewer>（后两项复核 2026-11-26）
- 其他：<https://github.com/renpy/renpy>、<https://github.com/Inochi2D/inochi2d>；复核 2026-11-26：<https://github.com/Inochi2D/inox2d>、<https://github.com/MF-Dust/Nori.Desktop>（GPL-3.0，只取事实）、<https://github.com/OpenL2D/moc3ingbird>（已归档）
- Cubism SDK：<https://github.com/Live2D/CubismWebFramework>（`LICENSE.md` L13：<https://github.com/Live2D/CubismWebFramework/blob/8ac72d40bc0a22eb06742c7062614457589bc822/LICENSE.md#L13>，复核 2026-11-26）；<https://github.com/Live2D/CubismWebSamples>
- Live2D 许可页面：SDK 许可 <https://www.live2d.com/en/sdk/license/>；Expandable Application <https://www.live2d.com/en/sdk/license/expandable/>；Release License <https://www.live2d.com/en/download/cubism-sdk/release-license/>；Open Software License <https://www.live2d.com/eula/live2d-open-software-license-agreement_en.html>；Proprietary Software License <https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html>

**第 3 节：Android 承载**

- androidx.webkit 源码：`WebViewAssetLoader.java` <https://github.com/androidx/androidx/blob/30e32ec1d335483120660f5a9136c384dcb49c1a/webkit/webkit/src/main/java/androidx/webkit/WebViewAssetLoader.java>；`AssetHelper.java` <https://github.com/androidx/androidx/blob/72ed4c1a36360c83c3399f8311e53ad7cbbcfcce/webkit/webkit/src/main/java/androidx/webkit/internal/AssetHelper.java>（均复核 2026-11-26）
- androidx.webkit API 参考：<https://developer.android.com/reference/androidx/webkit/package-summary>
- Android WebView 管理文档（渲染进程、优先级，3.3）：<https://developer.android.com/develop/ui/views/layout/webapps/managing-webview>
- Flutter Android 平台视图文档（3.6）：<https://docs.flutter.dev/platform-integration/android/platform-views>
- Chromium 活跃 WebGL 上下文上限（3.4）：<https://github.com/chromium/chromium/blob/9fb3a21ed95c1ba078807591a09718b81c1d46cf/content/renderer/webgraphicscontext3d_provider_impl.cc#L122-L134>（复核 2026-11-26）
- 否决的方案（3.6）：<https://pub.dev/packages/webview_flutter_android>；flutter/flutter#130297 <https://github.com/flutter/flutter/issues/130297>（复核 2026-11-26 仍 open）；<https://github.com/pichillilorenzo/flutter_inappwebview>；RcTool <https://github.com/richuff/RcTool>（MIT，复核 2026-11-26）

**第 4 节：陪伴行为层（按正文出现顺序）**

- <https://github.com/moeru-ai/airi>、<https://github.com/morettt/my-neuro>、<https://github.com/Project-N-E-K-O/N.E.K.O>、<https://github.com/RaSan147/pixi-live2d-display>、<https://github.com/chyinan/Kokoro-Engine>、<https://github.com/pixiv/ChatVRM>、<https://github.com/mrxz/wLipSync>、<https://github.com/hecomi/uLipSync>
- <https://github.com/Open-LLM-VTuber/Open-LLM-VTuber>、<https://github.com/Live2D/CubismSpecs>、<https://github.com/DenchiSoft/VTubeStudio>、<https://github.com/erodozer/open-vt>、<https://github.com/moonrailgun/vtubeleaf>、<https://github.com/Open-LLM-VTuber/Open-LLM-VTuber-Web>、<https://github.com/Voine/ChatWaifu_Mobile>、<https://github.com/ltarcher/flutter_live2d_lipsync>
- <https://github.com/elevenyellow/handcrafted-persona-engine>、<https://github.com/Zao-chen/ZcChat>、<https://github.com/TEN-framework/ten-framework>、<https://github.com/DD-MASTERT/AI-Girlfriend-Desktop-Pet>、<https://github.com/kiyotakali/Miru>、<https://github.com/InariNGT-Ofiicial/jingyu-live2d-agent>
- WebAssembly memory-control 提案：<https://github.com/WebAssembly/memory-control/blob/main/proposals/memory-control/Overview.md>；Cubism 标准参数表：<https://docs.live2d.com/en/cubism-editor-manual/standard-parametor-list/>；<https://laplace.live/persona/live2d/bindings>

**第 5 节：本 PR 的实现（5.3、5.4）**

- WebGL 上下文丢失：Khronos WebGL wiki「HandlingContextLost」<https://wikis.khronos.org/webgl/index.php?title=HandlingContextLost>。只有 `webglcontextlost` 的处理函数调用 `preventDefault()`，浏览器才会发出 `webglcontextrestored`（复核 2026-11-26）
- Flutter 测试中的通道替身：`TestDefaultBinaryMessenger.handlePlatformMessage` <https://api.flutter.dev/flutter/flutter_test/TestDefaultBinaryMessenger/handlePlatformMessage.html>
- Cubism Framework 的组查找（5.4）：`cubismmodelsettingjson.ts` L408-517 <https://github.com/Live2D/CubismWebFramework/blob/d4da0aa07e47d2c1e4f5fa7ea6047861ea5e5d0b/src/cubismmodelsettingjson.ts#L408-L517>（复核 2026-11-26）
- 官方示例 Wanko 的 `Groups`（5.4）：<https://github.com/Live2D/CubismWebSamples/blob/b1de66b0b1f1cb881d95fb6158622aeb6a2827bd/Samples/Resources/Wanko/Wanko.model3.json#L32-L48>（复核 2026-11-26）
- hacxy/l2d-widget（MIT）的口型参数示例（5.4）：<https://github.com/hacxy/l2d-widget/blob/6a7b63d414d5046a357e163582d6f6b7000d5f5a/src/types.ts#L52-L55>（复核 2026-11-26）
