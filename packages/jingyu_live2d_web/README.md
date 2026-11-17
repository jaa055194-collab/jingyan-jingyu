# jingyu_live2d_web

自包含 WebView Live2D 查看器资源包。它**不包含**任何模型、纹理、私有资产或 PurismCore 二进制；模型由用户在本机导入，运行时由脚本拉取。

## 内容

- `web/live2d_viewer.html` / `web/live2d_viewer.js`：WebView 页面与 Flutter↔JS 消息协议层。协议与 `jingyu_client_kit` 的 `Live2DRendererBridge` 对齐：
  - Flutter→viewer：`load`（model3 URL、纹理 URL、modelId、profileRev）、`setParam`、`setExpression`、`setMotion`、`dispose`。
  - viewer→Flutter：`ready`（modelId、profileRev）、`error`（message）。
  - 页面用 PurismCore 建立 Moc/Model 并逐帧 `update()`；像素绘制委托给 `window.Live2DRenderer` 适配器。未安装适配器时只做核心更新，不宣称已绘制图像。
- `web/live2d_renderer_webgl.js`：`window.Live2DRenderer` WebGL 适配器（WebGL2 优先，`webgl` 回退）。实现 `prepare(canvas, model, textureUrls)`、`draw(model)`、`setExpression(name)`、`setMotion(group,index)`、`dispose()`；编译简单纹理四边形着色器、从 URL 加载纹理，并把 `model.drawables` 的顶点位置/UV/索引/纹理索引/透明度/乘算与屏幕颜色/常量标志/`model.renderOrders` 映射为绘制调用。**尽力而为、非视觉对齐承诺**：
  - 掩码用单层 stencil 近似；嵌套掩码、通道打包的多掩码组与离屏掩码未还原。
  - v5 常量标志的加算/乘算混合为近似；v6 扩展颜色+Alpha 混合模式与离屏合成未实现。
  - 物理、动作、表情、呼吸/眨眼与 model3 运动管线不在范围内；`setExpression`/`setMotion` 仅记录意图，不实际驱动。
  - 纹理色彩空间、预乘 Alpha 细节、设备 `MAX_TEXTURE_SIZE`、显存压力（参考模型使用大图集）与稳定帧率均**需要真机验证**。
  - 防御式：任一 PurismCore getter/数组缺失时跳过该 drawable；`draw()` 不向动画循环抛异常，问题通过返回诊断对象与 `console` 报告。
- `tool/fetch_purismcore.ps1`：按固定版本下载 PurismCore v1.1.0 Web 运行时（MIT），校验 SHA-256 后只复制 `purismcore.js` 与 `LICENSE` 到 `web/runtime/purismcore/`。运行时不进仓库。

## 未完成 / 待真机验证

- WebGL 适配器已提供骨架与基本绘制路径，但尚未做真实设备上的视觉、掩码/混合正确性、显存与帧率验证；也未实现热切换、VRM 回退与外层 Flutter 接入。
- 不随包分发模型或 Cubism SDK/Core；使用前请阅读第三方许可。
