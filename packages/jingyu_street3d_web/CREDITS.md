# 来源与许可

本文件只写核对过的内容（2026-11-26 核对）。

## feiyu 房间模板

- 项目：大肥鱼房子模板（feiyu-room-template），`package.json` 里的名称是 `dafiyu-house-template`，版本 3.0.0，MIT 许可。
- 地址：<https://github.com/sh2234113/feiyu-room-template>。核对的是这个仓库的提交 `201a4ecad48e7e77cfdd6422fb8f55a77a7b9f5f`（2026-11-12），下文的行号都指这个提交里的文件。
- 许可证：[LICENSE-feiyu-room-template.txt](LICENSE-feiyu-room-template.txt) 与模板的 `LICENSE` 逐字节相同（SHA-256 `c8ba59c3ce65542fbe3311384bd8b5fa12f481d0b37cdd7e87356657e12411fa`，1128 字节），`pubspec.yaml` 把它和页面一起打包。
- 本包只改编了模板的代码，没有带上模板的素材文件。模板 `THIRD_PARTY_NOTICES.md` 单独列出许可的素材，例如 dsh-pet 的立绘、动画和音效（CC BY-NC-SA 4.0）和作者的 3D 模型 `da-feiyu.glb`、`da-feiyu.opt.glb`，这些都不在本包里。

### 各文件的来源

表里的模板文件都在模板的 `public/room/` 下。

| 本包文件 | 来源 |
|---|---|
| `web/src/actor.js` | 改编自 `actor3d.js` 的 `ChibiActor` 类（:190），对应本包的 `ResidentActor` 类。沿用了 `toon()`（:22）带 `gradientMap` 的 `MeshToonMaterial` 卡通着色、`shadowTexture()`（:64）用 canvas 画的阴影贴图，以及 `update()`（:607）里走路时的起伏 `\|sin(8t)\| × 0.025` 和手脚摆动。 |
| `web/src/camera.js` | `fitView()` 改编自 `garden-camera.js` 的 `getGardenFraming()`（:11）：在 `bounds(radius)` 上二分搜索轨道半径，让一组世界坐标点刚好放进可用的视口区域。头注释只把 `fitView()` 标为改编；`CameraRig` 驱动 three.js 的 `OrbitControls`，模板 `public/room/` 下的 .js 文件里没有用到 `OrbitControls`。 |
| `web/src/kit.js` | `geometry()`（按种类缓存单位几何体）和 `batch()`（`put`、`rod`、`flush`：同一几何体加同一材质的部件合成一个 `InstancedMesh`）改编自 `garden-world.js` 中 `createGardenWorld()` 的同名内部函数（:36、:62）；头注释只把这两个函数标为改编。 |
| `web/src/stage.js` | 渲染器设置改编自 `app.js` 顶层的 `WebGLRenderer` 初始化（:70–79：ACES 色调映射、sRGB 输出、PCF 软阴影、`shadowMap.autoUpdate = false`）；半球光加投影的太阳光改编自 `world.js` 的 `buildLights()`（:1686）。 |
| `web/src/street.js`、`web/src/villa.js` | 为本项目编写。部件经 `kit.js` 的 `batch()` 实例化，也就是 `garden-world.js` 的做法。 |
| `web/src/main.js` | 为本项目编写，负责把桥接、场景和上面这些模块串起来。 |
| `web/src/label.js` | 为本项目编写。 |
| `web/src/protocol.js`、`web/src/bridge.js`、`web/src/lots.js`、`web/src/demo-host.js` | 为本项目编写，实现 [PROTOCOL.md](PROTOCOL.md)。 |
| `web/src/interp.js` | 为本项目编写，做法见下面的“技术参考”。 |
| `web/index.html`、`scripts/serve.mjs`、`scripts/smoke.mjs`、`test_node/` | 为本项目编写。 |

“为本项目编写”的依据：这些文件的头注释都没有说文件本身改编自模板。protocol.js、bridge.js、lots.js、interp.js、demo-host.js 和 main.js 的头注释写明 Written for this package；street.js 和 villa.js 只说部件经 kit.js 的实例化批处理，即 `garden-world.js` 的做法；label.js、`web/index.html` 和两个脚本没有写来源，`test_node/` 是这次新写的测试。模板 `public/room/` 下的 .js 文件（不含 `vendor/`）里也找不到街道、别墅风格或本协议的标识符（如 `Street3DBridge`、`hello-ack`、`parseEnvelope`、`SnapshotInterpolator`）。模板也用 canvas 画文字标签（`garden-world.js` 的 `label()`、`world.js` 的 `buildLabels()`），但没有用 three.js 的 `Sprite`；模板的 `scripts/room-shot.mjs` 也做无头截图，但它通过 CDP 截图，`smoke.mjs` 用的是浏览器的 `--screenshot` 参数。

## three.js r160

- 来源：npm 包 `three@0.160.0`，MIT 许可，仓库 <https://github.com/mrdoob/three.js>。`three.module.js` 里的 `REVISION` 是 `'160'`。
- `web/vendor/` 里只有下面 3 个文件，都是原样副本：2026-11-26 从 jsDelivr 下载 `three@0.160.0` 的对应文件比对过，SHA-256 相同。

| 本包文件 | 上游路径（`three@0.160.0`） | 字节数 | SHA-256 |
|---|---|---|---|
| `web/vendor/three.module.js` | `build/three.module.js` | 1272972 | `76dea8151bc9352aef3528b4262e249b2604f62543828328db978d060d61a495` |
| `web/vendor/OrbitControls.js` | `examples/jsm/controls/OrbitControls.js` | 29868 | `5a44a9e86a2a0fb11933eed69bc2cd33c76a496854c1aed6ed776efa87d7b064` |
| `web/vendor/LICENSE-three.txt` | `LICENSE` | 1081 | `852e0e8699169bf9f6fdc6bda3e682d078dcbc738b5d33e74df594721bff271d` |

- 哈希是用 `Get-FileHash -Algorithm SHA256` 对仓库里的文件算的，这些文件都是 LF 换行；检出时如果换行被转成 CRLF，算出来的值会不同。
- `OrbitControls.js` 用裸模块名 `'three'` 导入，`web/index.html` 的 import map 把它指向 `./vendor/three.module.js`。
- 本包没有 `examples/jsm/utils/BufferGeometryUtils.js`：`web/vendor/` 里没有这个文件，代码也没有用到它。

## 许可证

- three.js：MIT，全文见 [web/vendor/LICENSE-three.txt](web/vendor/LICENSE-three.txt)（Copyright © 2010-2023 three.js authors）。
- feiyu 房间模板：MIT，全文见 [LICENSE-feiyu-room-template.txt](LICENSE-feiyu-room-template.txt)（Copyright (c) 2026 Derpyu520 and qq-bridge / QSH contributors；Copyright (c) 2026 sh2234113）。

## 技术参考

- `web/src/interp.js` 用的是缓冲实体插值（entity interpolation）：快照按页面收到的时间进缓冲，画面比当前时刻晚一个延迟（最近几次快照间隔中位数的 1.5 倍，限制在 300–750 ms），在前后两个快照之间插值。这种做法的介绍见 Gabriel Gambetta 的 [Fast-Paced Multiplayer (Part III): Entity Interpolation](https://www.gabrielgambetta.com/entity-interpolation.html)。
