# jingyu_live2d_web

自包含 WebView Live2D 查看器资源包。它**不包含**任何模型、纹理、私有资产或 PurismCore 二进制；模型由用户在本机导入，运行时由脚本拉取。

## 内容

- `web/live2d_viewer.html` / `web/live2d_viewer.js`：WebView 页面与 Flutter↔JS 消息协议层。协议与 `jingyu_client_kit` 的 `Live2DRendererBridge` 对齐：
  - Flutter→viewer：`load`（model3 URL、纹理 URL、modelId、profileRev）、`setParam`、`clearParam`、`setExpression`、`setMotion`、`behavior`、`blink`、`speak`、`dispose`、`preload`、`swap`、`pause`、`resume`。`setParam` 的值保持到 `clearParam` 或下一次加载；`behavior` 替换眨眼和口型参数 ID，`blink` 立即眨一次，`speak` 按 10–100 ms 一步播放 0..1 口型包络。
  - viewer→Flutter：`boot`（脚本加载后先发一次，早于其他事件）、`ready`（modelId、profileRev）、`error`（`code` 与 `message`；`code` 取 `load_failed`、`render_failed`、`webgl_context_lost` 或 `bad_command`），以及热切换事件 `preloaded`、`preload_rejected`、`preload_failed`、`swapped`、`swap_failed`、`paused`、`resumed`。运行时提供时，`ready` 还附带 `parameters`（按运行时顺序列出参数 ID 及其 `min`/`max`/`default` 范围，非有限值不列出）与 `parts`（部件 ID），供应用核对映射；任一列表来源缺失、格式异常或超过 4096 项时整项省略、不截断。`ready` 也附带 `expressions`（已暂存且 exp3 加载成功的表情 `Name`，按 model3 顺序）与 `motions`（动作文件全部加载成功的各动作组的 `{group, count}`）；model3 没有对应键时为空列表，格式异常或超过上限（1024 个表情、4096 个组、每组 1024 个、共 4096 个动作）时整项省略。表情与动作加载后即可播放。
  - 热切换（D3b 查看器协议；应用层协调器与接线尚未完成）：
    - `preload {loadId, modelId?, profileRev?, model3, textureUrls?}`：在旧模型继续 tick/绘制时完成新模型的 CPU 暂存（model3、moc、Model、表情/动作/物理/姿态/动画）并调用 `createScene`；成功回 `preloaded {loadId}`。纹理预算拒绝回 `preload_rejected {loadId, code:'texture_budget'}`（旧模型不动）；其他失败回 `preload_failed {loadId, code, message}`（`code` 取 `load_failed`/`webgl_context_lost`/`bad_command`/`busy` 等）。新的 `preload` 会释放上一个尚未 swap 的场景与模型并忽略其过期回包。
    - `swap {loadId, fadeMs?}`：只接受已 `preloaded` 的 loadId，否则 `swap_failed {loadId, code:'not_preloaded'}`；`fadeMs` 默认 250，钳制 0..1000。淡化期每帧 `beginFrame()` 后旧场景 `alpha=1-t`、新场景 `alpha=t`；新场景首帧绘制在 try/catch 内，失败时释放新场景、旧场景恢复 alpha 1 并回 `swap_failed {code:'render_failed'}`（旧模型继续运行）。首帧成功后命令改绑到新动画（旧动画 `setParam` 的保持值不继承），淡化结束按场景→model→moc 释放旧对象并回 `swapped {loadId, modelId, profileRev, parameters?, parts?, expressions?, motions?}`（负载字段与 `ready` 相同）。
    - `pause {}` / `resume {}`：只停/启 rAF，不释放任何对象，幂等；暂停中允许 `preload`，`swap` 以 `code:'paused'` 失败（可 resume 后重试）。同一时刻只允许一个 preload/swap；`dispose` 在 preload 或淡化中释放全部资源且不再发任何事件。`load` 仍是原来的硬切换路径，其对外协议不变。
  - 页面用 PurismCore 建立 Moc/Model 并逐帧 `update()`；像素绘制委托给 `window.Live2DRenderer` 适配器。缺少适配器或首帧绘制失败时只发 `error`，不发 `ready`；核心 `update()` 不算已绘制。
  - 就绪后某帧更新或绘制抛错（`render_failed`）、画布丢失 WebGL 上下文（`webgl_context_lost`）时同样发 `error`，并释放模型、停止帧循环。上下文恢复前，之后的 `load` 都以 `webgl_context_lost` 失败；`dispose` 之后不再加载。
  - 传输：页面→Flutter 依次尝试 `Live2DBridge.postMessage`（Android 的 WebMessageListener 或 webview_flutter 的 JavaScript channel）、flutter_inappwebview 的 `live2d` handler、`parent.postMessage`；Flutter→页面经 `Live2DBridge` 的 `message` 事件（Android 回复代理，页面发出第一条消息后才可用）、`window` 的 `message` 事件或 `window.__live2dReceive`。
- `web/live2d_renderer_webgl.js`：`window.Live2DRenderer` WebGL 适配器（WebGL2 优先，`webgl` 回退）。实现 `prepare(canvas, model, textureUrls, options)`、`createScene(canvas, model, textureUrls, options)`（返回场景对象或 `null`，`lastError` 说明原因，纹理预算拒绝为 `texture_budget`）、`draw(scene, alpha)` / `draw(model)`、`beginFrame()` / `endFrame()`、`disposeScene(scene)`、`sceneBytes(scene)` / `totalLiveBytes()` / `diagnostics()` 与 `dispose()`；编译简单纹理四边形着色器、按显存预算加载纹理（见下方 `live2d_texture_budget.js`），并把 `model.drawables` 的顶点位置/UV/索引/纹理索引/透明度/乘算与屏幕颜色/常量标志/`model.renderOrders` 映射为绘制调用。多场景共用同一 canvas、上下文与着色器程序，每场景各自持有纹理、几何缓存、相机 fit 与字节估算；`draw(scene, alpha)` 用 `u_alpha` 乘在预乘输出上，`beginFrame()` 清一次、`endFrame()` 结束一帧。**尽力而为、非视觉对齐承诺**：
  - 掩码用单层 stencil 近似；嵌套掩码、通道打包的多掩码组与离屏掩码未还原。
  - v5 常量标志的加算/乘算混合为近似；v6 扩展颜色+Alpha 混合模式与离屏合成未实现。
  - 物理、model3 姿态、动作、表情、呼吸/眨眼与 model3 运动管线由下列模块在查看器中计算，像素适配器只负责绘制。
  - 纹理色彩空间、预乘 Alpha 细节与稳定帧率均**需要真机验证**；大图集会按设备 `MAX_TEXTURE_SIZE` 与显存预算统一缩小，但这两个数值尚未在我们的设备上实测（见下方）。
  - 防御式：任一 PurismCore getter/数组缺失时跳过该 drawable；`draw()` 不向动画循环抛异常，问题通过返回诊断对象与 `console` 报告。
  - 来源：相机计算（`updateProjection()`、`computeFit()`）与基础片元着色器的乘算色、屏幕色、预乘步骤改编自 PurismCore v1.1.0 的 viewer 示例（MIT，`src/samples/viewer/graphics.c` 与 `shaders/draw.frag`）。文件头保留原版权与许可声明，登记见仓库根目录的 `THIRD_PARTY_NOTICES.md`。
- `web/live2d_motion.js`：motion3/exp3 播放器，浏览器全局 `window.Live2DMotion`，并以 CommonJS 导出供 node 测试。解析并求值 Segment（含受限与非受限 Bezier）、淡入淡出、循环与非循环动作、动作组优先级与交叉淡化，以及表情的 Add/Multiply/Overwrite。没有 Cubism Framework，曲线求值由本模块自己完成。
- `web/live2d_behavior.js`：程序化行为层，浏览器全局 `window.Live2DBehavior`，并以 CommonJS 导出供 node 测试。眨眼、带随机扫视的视线、呼吸与口型包络；眨眼/口型参数只来自运行时回报且映射后存在的 ID，视线与呼吸只在模型具有标准参数时写入。Adapted from pixi-live2d-display、airi 与 Kokoro-Engine 的 MIT 代码，文件头保留版权与许可，登记见仓库根目录 `THIRD_PARTY_NOTICES.md`。
- `web/live2d_physics.js`：physics3 求值器，浏览器全局 `window.Live2DPhysics`，并以 CommonJS 导出供 node 测试。按设置把输入归一化后推动粒子链，按固定步长 `Fps` 更新并在帧间插值，输出写回参数；加载后 `stabilize()` 让粒子从静止开始。改编自 Mocari（MIT）与 psd2live 的一小段（MIT），见 `THIRD_PARTY_NOTICES.md`。
- `web/live2d_pose.js`：pose3 求值器，浏览器全局 `window.Live2DPose`，并以 CommonJS 导出供 node 测试。每组同一时间显示一个部件，按 `FadeInTime`（默认 0.5 s）淡入，其余部件按 0.15 背面不透明度上限压低，链接部件跟随；只写 part 不透明度，由 Core 传播到 drawable。缺失的部件同名参数放在 `extraParams` 中，可由动作或 `setParam` 驱动。
- `web/live2d_texture_budget.js`：纹理显存预算，浏览器全局 `window.Live2DTextureBudget`，并以 CommonJS 导出供 node 测试。`live2d_viewer.html` 在渲染器之前加载它；缺少它时 `prepare()` 不加载纹理，返回 `{ok: false, reason: 'texture-budget-unavailable'}`。
  - `readPngSize(bytes)` 从 IHDR 块读取宽高，非 PNG 数据直接抛错。
  - `planUniformScale(sizes, maxTextureSize, budgetBytes)` 返回一个 ≤ 1 的统一缩放：每张纹理不超过 `maxTextureSize`，且按 RGBA8 加完整 mipmap 估算的总量（每张 `w*h*4*4/3` 字节）不超过 `budgetBytes`；尺寸向下取整、最小为 1，全部放得下时为 1。`planTextureSizes` 参数相同，另返回取整后的尺寸与字节数，渲染器按这些尺寸解码。
  - 渲染器先 `fetch` 全部纹理并从文件头读出尺寸，只规划一次，再逐张 `createImageBitmap(blob, {resizeWidth, resizeHeight, resizeQuality: 'high'})`（缩放为 1 时不传缩放参数）、上传、`generateMipmap`（WebGL1 只对 2 的幂尺寸），并在解码下一张前 `close()` 位图。下载失败、非 PNG 或解码尺寸与规划不符的纹理被跳过并告警。
  - 默认值：`maxTextureSize` 取 `gl.getParameter(MAX_TEXTURE_SIZE)`，预算 256 MiB（Mochi2D 的手机/平板默认值）。`prepare()` 的 `options.maxTextureSize` 只能调低上限，`options.textureBudgetBytes` 替换预算。**这两个数值与 4/3 的 mipmap 估算都尚未在我们的设备上实测。**
  - `prepare()` 结果与 `diagnostics()` 增加 `textureScale`、`maxTextureSize`、`textureBytes`（估算显存）、`textureCount`（成功上传的纹理数）与 `textureBudgetBytes`。
- `tool/fetch_purismcore.ps1`：按固定版本下载 PurismCore v1.1.0 Web 运行时（MIT），校验 SHA-256 后只复制 `purismcore.js` 与 `LICENSE` 到 `web/runtime/purismcore/`。运行时不进仓库。
- `test/viewer_behavior.test.cjs`：在 VM 沙箱里运行真实 `live2d_viewer.js`（stub PurismCore/渲染器），覆盖首帧成功才 `ready`、首帧失败/缺适配器/缺 core 只报 `error`、重复 `load` 拒绝、参数校验、`dispose` 释放、`webview_flutter` 消息通道，以及 `boot` 先于其他事件且只发一次、宿主命令经 `Live2DBridge` 的 `message` 事件到达、各类错误的 `code`、就绪后上下文丢失只报一次并释放模型、上下文恢复前 `load` 失败、加载中丢失上下文与就绪后某帧失败时停止帧循环。`test/asset_manifest_test.dart` 检查无远程 URL、脚本加载顺序（预算脚本在渲染器之前）、运行时不入库与拉取脚本的版本/校验和。
- `test/motion.test.cjs`：motion3/exp3 解析、四种 Segment、Bezier、淡入淡出、循环与替换交叉淡化、优先级、Model EyeBlink/LipSync、PartOpacity 与表情混合的单元测试。
- `test/behavior.test.cjs`：眨眼时序与让位、视线扫视与收敛、呼吸采样、口型包络与释放、ID 校验和范围钳制的单元测试。
- `test/physics.test.cjs`：physics3 解析、输入归一化与 Reflect、角度到参数的方向包裹、固定步长与帧间插值、链路级联、`stabilize`、未知 ID 与非法输入的单元测试。
- `test/pose.test.cjs`：pose3 解析与默认淡入、可见部件阈值、淡入进度、0.15 背面规则、只降不升、链接部件、`extraParams`、`reset` 与非法输入的单元测试。
- `test/texture_budget.test.cjs`：预算模块的单元测试（PNG 头解析、非 PNG 拒绝、最大尺寸钳制、显存预算、全部放得下时不缩放），以及在 VM 沙箱里用假 GL、`fetch` 与 `createImageBitmap` 运行真实渲染器的测试（先读全部尺寸再逐张解码/上传/关闭、统一缩放、失败纹理跳过、WebGL1 非 2 的幂不建 mipmap、加载中 `dispose`、解码尺寸不符）。
- `test/hot_scene.test.cjs`：多场景渲染器测试（两场景共用一上下文/程序但纹理、几何缓存、fit 与字节数独立；`draw(scene, alpha)` 写入 `u_alpha`；`draw(model)` 兼容旧调用；预算拒绝与 `disposeScene`）。
- `test/switcher.test.cjs`：在 VM 沙箱里用假 PurismCore 与实现 D3a 多场景接口的假渲染器运行真实查看器，覆盖 preload 不释放/不停止旧模型且旧模型继续绘制、`preloaded` 回包、纹理预算拒绝、preload 失败、新 preload 抢占并释放旧场景（含 `createScene` 在途时的迟到场景）、未 preload 就 swap、淡化 alpha 序列与结束释放旧场景、`swapped` 负载、新场景首帧抛错回滚、暂停中 swap 失败与 resume 后成功、pause/resume 停启 rAF、淡化中 dispose 以及 `fadeMs` 默认/钳制。
- `tool/check.ps1` 用 node 运行全部八个 `.cjs` 测试（viewer、motion、behavior、physics、pose、texture budget、hot scene、switcher）。

## 未完成 / 待真机验证

- Android 外壳接入了导入后的临时预览与本机保存/映射/启用：`apps/client_flutter` 的原生平台视图用 `WebViewAssetLoader` 在 `https://appassets.androidplatform.net` 下提供本包的查看器文件与暂存/本机模型，查看器文件在构建时由 Gradle 复制进安装包。构建前没有运行 `tool/fetch_purismcore.ps1` 时，构建只告警，安装包里没有运行时，预览会报错。启用的形象暂不显示在聊天或世界场景中；查看器已支持 preload/swap/pause/resume 协议，但 Dart 侧切换协调器、句末门控与应用接线（D3c/D3d）尚未实现；VRM 回退未实现；Windows 客户端不再开发。
- 动作、表情、物理与姿态的求值已接入查看器，但尚未用真实模型在真机上核对与 Cubism 参考实现的数值和视觉一致性；物理参数（重力/风力）使用运行默认值，不读取 model3 的提示值。
- WebGL 适配器已提供骨架与基本绘制路径，但尚未做真实设备上的视觉、掩码/混合正确性、显存与帧率验证。
- 纹理预算的 256 MiB 默认值、4/3 mipmap 估算与各设备 `MAX_TEXTURE_SIZE` 的实际取值都还没有在我们的 Android 设备上测量；缩小后的画质（直通 Alpha 缩放时的透明边缘）与逐张解码的加载时间也待真机检查。纹理与 model3/moc3 一样用 `fetch` 读取，必须来自同一个可 `fetch` 的来源（Chromium 的 `fetch` 不支持 `file://`）。
- 不随包分发模型或 Cubism SDK/Core；使用前请阅读第三方许可。
