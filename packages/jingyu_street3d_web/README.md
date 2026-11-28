# jingyu_street3d_web

鲸言鲸语「世界」页的 3D 街区网页。页面运行在 Android WebView 里，用 three.js 0.160.0 画一条双车道街道：两侧共 12 块地，宿主发来的每个空间占一块地、建一栋别墅（5 种风格）；居民显示为 Q 版小人，最多同时显示 8 个；点别墅或居民会通知宿主。页面只负责渲染和点击，布局和居民位置都由宿主提供。

这是纯资源包，没有 Dart 代码，`pubspec.yaml` 只打包 `web/`、`web/vendor/`、`web/src/` 和 `LICENSE-feiyu-room-template.txt`。页面不加载任何外部资源：three.js 在 `web/vendor/` 里，文字只用系统字体，页面的 CSP 也不允许外部 origin。

| 路径 | 内容 |
|---|---|
| [PROTOCOL.md](PROTOCOL.md) | 宿主和页面之间的桥接协议 |
| `web/index.html`、`web/src/` | 页面入口和各模块 |
| `web/vendor/` | three.js r160 的原样副本 |
| `scripts/` | 本地静态服务 `serve.mjs`、冒烟截图 `smoke.mjs` |
| `test_node/` | node:test 测试 |
| [CREDITS.md](CREDITS.md) | 代码来源、`web/vendor/` 文件的哈希和许可证 |

## Android 宿主怎么加载

- 宿主用 `WebViewAssetLoader` 从 origin `https://appassets.androidplatform.net` 加载 `web/index.html`，因为页面用的是 ES 模块，不能从 `file://` 加载。页面文件随 Flutter 打包在 flutter_assets 的 `packages/jingyu_street3d_web/` 下；比如 `AssetsPathHandler` 挂在 `/assets/` 时，地址是 `https://appassets.androidplatform.net/assets/flutter_assets/packages/jingyu_street3d_web/web/index.html`。
- 宿主用 `WebViewCompat.addWebMessageListener` 注入名为 `Street3DBridge` 的 JS 对象，`allowedOriginRules` 只放上面这个 origin。页面用 `Street3DBridge.postMessage(json)` 发消息；宿主用回调里拿到的 `JavaScriptReplyProxy.postMessage(json)` 回消息，页面从 `Street3DBridge.onmessage` 收到。
- 握手、消息类型、上限和错误码见 [PROTOCOL.md](PROTOCOL.md)。

## 本地预览

```sh
node scripts/serve.mjs    # 或 npm run serve；端口默认 8765，可用参数或 PORT 环境变量修改
```

然后在浏览器打开 <http://127.0.0.1:8765/web/index.html?demo=1>。普通浏览器里没有 `Street3DBridge`，`?demo=1` 让页面改用内置的 demo 宿主（`web/src/demo-host.js`），街区和居民都是合成数据；不带 `?demo=1` 时页面停在“等待宿主”提示。不能直接双击打开 HTML 文件，因为 ES 模块不能从 `file://` 加载。

## 冒烟截图

```sh
node scripts/smoke.mjs <输出.png> [宽=1080] [高=2400]
```

脚本在 127.0.0.1 的随机端口起服务，用无头 Microsoft Edge（SwiftShader 软件渲染）打开 `web/index.html?demo=1` 并截图；不给输出路径时写到当前目录的 `smoke.png`。退出码只跟随浏览器（0 为成功），脚本不检查截图内容。环境变量：`EDGE` 浏览器路径（默认 `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe`，也可以换成别的 Chromium），`BUDGET_MS` 虚拟时间预算（默认 6000），`TIMEOUT_MS` 超时（默认 90000）。脚本会在输出文件旁建 `edge-profile/` 目录，所以输出路径最好放在包外。

## 测试

```sh
node --test test_node/    # 或 npm test
```

测试用 `node:test` 和 `node:assert` 写成，只用 Node 自带的模块，不用安装依赖。测试覆盖不依赖 DOM 的 protocol.js、bridge.js、lots.js、interp.js 和 demo-host.js，并对照 PROTOCOL.md 检查信封和错误码、`hello-ack` 之前的排队、地块上限和插值。在 Node 22 上，`node --test test_node/` 会把这个目录当作一个入口文件来运行，所以由 `test_node/index.js` 导入全部 `*.test.mjs`；单个文件也可以单独运行，比如 `node --test test_node/bridge.test.mjs`。

## 来源与许可证

见 [CREDITS.md](CREDITS.md)。three.js 是 MIT 许可（`web/vendor/LICENSE-three.txt`）。角色、相机取景、实例化批处理、渲染器和灯光的部分代码改编自 feiyu 房间模板，也是 MIT 许可（`LICENSE-feiyu-room-template.txt`）。
