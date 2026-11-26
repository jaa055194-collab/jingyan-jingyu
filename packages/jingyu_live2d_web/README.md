# jingyu_live2d_web

自包含 WebView Live2D 查看器资源包。它**不包含**任何模型、纹理、私有资产或 PurismCore 二进制；模型由用户在本机导入，运行时由脚本拉取。

## 内容

- `web/live2d_viewer.html` / `web/live2d_viewer.js`：WebView 页面与 Flutter↔JS 消息协议层。协议与 `jingyu_client_kit` 的 `Live2DRendererBridge` 对齐：
  - Flutter→viewer：`load`（model3 URL、纹理 URL、modelId、profileRev）、`setParam`、`setExpression`、`setMotion`、`dispose`。
  - viewer→Flutter：`boot`（脚本加载后先发一次，早于其他事件）、`ready`（modelId、profileRev）、`error`（`code` 与 `message`；`code` 取 `load_failed`、`render_failed`、`webgl_context_lost` 或 `bad_command`）。
  - 页面用 PurismCore 建立 Moc/Model 并逐帧 `update()`；像素绘制委托给 `window.Live2DRenderer` 适配器。缺少适配器或首帧绘制失败时只发 `error`，不发 `ready`；核心 `update()` 不算已绘制。
  - 就绪后某帧更新或绘制抛错（`render_failed`）、画布丢失 WebGL 上下文（`webgl_context_lost`）时同样发 `error`，并释放模型、停止帧循环。上下文恢复前，之后的 `load` 都以 `webgl_context_lost` 失败；`dispose` 之后不再加载。
  - 传输：页面→Flutter 依次尝试 `Live2DBridge.postMessage`（Android 的 WebMessageListener 或 webview_flutter 的 JavaScript channel）、flutter_inappwebview 的 `live2d` handler、`parent.postMessage`；Flutter→页面经 `Live2DBridge` 的 `message` 事件（Android 回复代理，页面发出第一条消息后才可用）、`window` 的 `message` 事件或 `window.__live2dReceive`。
- `web/live2d_renderer_webgl.js`：`window.Live2DRenderer` WebGL 适配器（WebGL2 优先，`webgl` 回退）。实现 `prepare(canvas, model, textureUrls, options)`、`draw(model)`、`setExpression(name)`、`setMotion(group,index)`、`dispose()`；编译简单纹理四边形着色器、按显存预算加载纹理（见下方 `live2d_texture_budget.js`），并把 `model.drawables` 的顶点位置/UV/索引/纹理索引/透明度/乘算与屏幕颜色/常量标志/`model.renderOrders` 映射为绘制调用。**尽力而为、非视觉对齐承诺**：
  - 掩码用单层 stencil 近似；嵌套掩码、通道打包的多掩码组与离屏掩码未还原。
  - v5 常量标志的加算/乘算混合为近似；v6 扩展颜色+Alpha 混合模式与离屏合成未实现。
  - 物理、动作、表情、呼吸/眨眼与 model3 运动管线不在范围内；`setExpression`/`setMotion` 仅记录意图，不实际驱动。
  - 纹理色彩空间、预乘 Alpha 细节与稳定帧率均**需要真机验证**；大图集会按设备 `MAX_TEXTURE_SIZE` 与显存预算统一缩小，但这两个数值尚未在我们的设备上实测（见下方）。
  - 防御式：任一 PurismCore getter/数组缺失时跳过该 drawable；`draw()` 不向动画循环抛异常，问题通过返回诊断对象与 `console` 报告。
  - 来源：相机计算（`updateProjection()`、`computeFit()`）与基础片元着色器的乘算色、屏幕色、预乘步骤改编自 PurismCore v1.1.0 的 viewer 示例（MIT，`src/samples/viewer/graphics.c` 与 `shaders/draw.frag`）。文件头保留原版权与许可声明，登记见仓库根目录的 `THIRD_PARTY_NOTICES.md`。
- `web/live2d_texture_budget.js`：纹理显存预算，浏览器全局 `window.Live2DTextureBudget`，并以 CommonJS 导出供 node 测试。`live2d_viewer.html` 在渲染器之前加载它；缺少它时 `prepare()` 不加载纹理，返回 `{ok: false, reason: 'texture-budget-unavailable'}`。
  - `readPngSize(bytes)` 从 IHDR 块读取宽高，非 PNG 数据直接抛错。
  - `planUniformScale(sizes, maxTextureSize, budgetBytes)` 返回一个 ≤ 1 的统一缩放：每张纹理不超过 `maxTextureSize`，且按 RGBA8 加完整 mipmap 估算的总量（每张 `w*h*4*4/3` 字节）不超过 `budgetBytes`；尺寸向下取整、最小为 1，全部放得下时为 1。`planTextureSizes` 参数相同，另返回取整后的尺寸与字节数，渲染器按这些尺寸解码。
  - 渲染器先 `fetch` 全部纹理并从文件头读出尺寸，只规划一次，再逐张 `createImageBitmap(blob, {resizeWidth, resizeHeight, resizeQuality: 'high'})`（缩放为 1 时不传缩放参数）、上传、`generateMipmap`（WebGL1 只对 2 的幂尺寸），并在解码下一张前 `close()` 位图。下载失败、非 PNG 或解码尺寸与规划不符的纹理被跳过并告警。
  - 默认值：`maxTextureSize` 取 `gl.getParameter(MAX_TEXTURE_SIZE)`，预算 256 MiB（Mochi2D 的手机/平板默认值）。`prepare()` 的 `options.maxTextureSize` 只能调低上限，`options.textureBudgetBytes` 替换预算。**这两个数值与 4/3 的 mipmap 估算都尚未在我们的设备上实测。**
  - `prepare()` 结果与 `diagnostics()` 增加 `textureScale`、`maxTextureSize`、`textureBytes`（估算显存）、`textureCount`（成功上传的纹理数）与 `textureBudgetBytes`。
- `tool/fetch_purismcore.ps1`：按固定版本下载 PurismCore v1.1.0 Web 运行时（MIT），校验 SHA-256 后只复制 `purismcore.js` 与 `LICENSE` 到 `web/runtime/purismcore/`。运行时不进仓库。
- `test/viewer_behavior.test.cjs`：在 VM 沙箱里运行真实 `live2d_viewer.js`（stub PurismCore/渲染器），覆盖首帧成功才 `ready`、首帧失败/缺适配器/缺 core 只报 `error`、重复 `load` 拒绝、参数校验、`dispose` 释放、`webview_flutter` 消息通道，以及 `boot` 先于其他事件且只发一次、宿主命令经 `Live2DBridge` 的 `message` 事件到达、各类错误的 `code`、就绪后上下文丢失只报一次并释放模型、上下文恢复前 `load` 失败、加载中丢失上下文与就绪后某帧失败时停止帧循环。`test/asset_manifest_test.dart` 检查无远程 URL、脚本加载顺序（预算脚本在渲染器之前）、运行时不入库与拉取脚本的版本/校验和。
- `test/texture_budget.test.cjs`：预算模块的单元测试（PNG 头解析、非 PNG 拒绝、最大尺寸钳制、显存预算、全部放得下时不缩放），以及在 VM 沙箱里用假 GL、`fetch` 与 `createImageBitmap` 运行真实渲染器的测试（先读全部尺寸再逐张解码/上传/关闭、统一缩放、失败纹理跳过、WebGL1 非 2 的幂不建 mipmap、加载中 `dispose`、解码尺寸不符）。`tool/check.ps1` 用 node 运行这两个 `.cjs` 测试。

## 未完成 / 待真机验证

- Android 外壳只接入了导入后的临时预览：`apps/client_flutter` 的原生平台视图用 `WebViewAssetLoader` 在 `https://appassets.androidplatform.net` 下提供本包的查看器文件与暂存模型，查看器文件在构建时由 Gradle 复制进安装包。构建前没有运行 `tool/fetch_purismcore.ps1` 时，构建只告警，安装包里没有运行时，预览会报错。持久化启用、热切换与 VRM 回退均未实现；Windows 客户端不再开发。
- WebGL 适配器已提供骨架与基本绘制路径，但尚未做真实设备上的视觉、掩码/混合正确性、显存与帧率验证。
- 纹理预算的 256 MiB 默认值、4/3 mipmap 估算与各设备 `MAX_TEXTURE_SIZE` 的实际取值都还没有在我们的 Android 设备上测量；缩小后的画质（直通 Alpha 缩放时的透明边缘）与逐张解码的加载时间也待真机检查。纹理与 model3/moc3 一样用 `fetch` 读取，必须来自同一个可 `fetch` 的来源（Chromium 的 `fetch` 不支持 `file://`）。
- 不随包分发模型或 Cubism SDK/Core；使用前请阅读第三方许可。
