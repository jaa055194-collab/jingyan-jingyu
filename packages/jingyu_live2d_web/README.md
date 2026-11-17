# jingyu_live2d_web

自包含 WebView Live2D 查看器资源包。它**不包含**任何模型、纹理、私有资产或 PurismCore 二进制；模型由用户在本机导入，运行时由脚本拉取。

## 内容

- `web/live2d_viewer.html` / `web/live2d_viewer.js`：WebView 页面与 Flutter↔JS 消息协议层。协议与 `jingyu_client_kit` 的 `Live2DRendererBridge` 对齐：
  - Flutter→viewer：`load`（model3 URL、纹理 URL、modelId、profileRev）、`setParam`、`setExpression`、`setMotion`、`dispose`。
  - viewer→Flutter：`ready`（modelId、profileRev）、`error`（message）。
  - 页面用 PurismCore 建立 Moc/Model 并逐帧 `update()`；像素绘制委托给可选的 `window.Live2DRenderer` 适配器（由外壳提供的 WebGL 渲染器）。未安装适配器时只做核心更新，不宣称已绘制图像。
- `tool/fetch_purismcore.ps1`：按固定版本下载 PurismCore v1.1.0 Web 运行时（MIT），校验 SHA-256 后只复制 `purismcore.js` 与 `LICENSE` 到 `web/runtime/purismcore/`。运行时不进仓库。

## 未完成

- WebGL 绘制适配器、真实渲染、热切换、VRM 回退、外壳接入与真机显存/帧率验证尚未实现；本包目前提供资源与协议骨架。
- 不随包分发模型或 Cubism SDK/Core；使用前请阅读第三方许可。
