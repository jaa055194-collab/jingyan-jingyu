# jingyu_street3d_web 桥接协议 v1.0

状态：v1.0，2026-11-25。

本协议的两端：
- 宿主：Flutter 客户端里的 3D 街区页面（Dart 侧）。
- 页面：WebView 里的 three.js 页面 `web/index.html`。

页面只负责渲染和点击。位置、拜访、权限的权威都在鲸语宿主机（FR-36、FR-37），Dart 侧只转发宿主机的数据。

## 1. 传输

- Android：宿主用 `WebViewCompat.addWebMessageListener` 注入名为 `Street3DBridge` 的 JS 对象，`allowedOriginRules` 只放 `https://appassets.androidplatform.net`。页面由 `WebViewAssetLoader` 从这个 origin 加载，因为 ES 模块需要 https origin，不能用 `file://`。
  - 页面 → 宿主：`Street3DBridge.postMessage(json)`。
  - 宿主 → 页面：用回调里拿到的 `JavaScriptReplyProxy.postMessage(json)` 发送，页面从 `Street3DBridge.onmessage` 的 `event.data` 收到。
- 没有 `Street3DBridge` 时：
  - URL 带 `?demo=1`：页面启用内置 demo 宿主（`web/src/demo-host.js`）。demo 宿主按本协议回 `hello-ack`，并发送合成的 `layout` 和 4 Hz 的 `presence`。它供 Edge 冒烟截图和 node 测试使用，数据全部是合成的。
  - 否则页面停在“等待宿主”提示，不建场景。
- 每条消息是一个 JSON 对象序列化成的 UTF-8 字符串，不超过 256 KiB。桥上不传二进制。

## 2. 信封

```json
{"v":1,"type":"presence","id":"p-42","ts":1764057600000,"payload":{}}
```

| 字段 | 类型 | 规则 |
|---|---|---|
| `v` | int | 协议主版本，本文为 `1`。`v` 不是 1 的消息会被丢弃，页面回 `error`（`bad_envelope`，非致命）。 |
| `type` | string | 取值见第 4、5 节。不认识的 type 会被丢弃，页面回 `error`（`unknown_type`，非致命）。 |
| `id` | string，可选 | 由发送方自定，不超过 64 字符。`error.ref` 用它指回出错的那条消息。 |
| `ts` | int | 发送方墙钟时间，Unix 毫秒。只用于日志，页面不用它插值。 |
| `payload` | object | 缺省时按 `{}` 处理。 |

完整版本号是 `"1.0"`（major.minor）。minor 升级只增加可选字段或可选消息类型，双方都忽略不认识的字段。

## 3. 握手与生命周期

1. 页面加载完模块、建好 WebGL 上下文后发 `hello`。如果 WebGL 不可用，页面改发 `error`（`webgl_unavailable`，致命），不再发 `hello`。
2. 宿主每收到一次 `hello`，都按新会话处理：先回 `hello-ack`，再依次发 `theme`（可选）、`layout` 和最近一次 `presence`。页面重载（WebView 重建）时会再发 `hello`，宿主同样全部重发。
3. 页面在收到 `hello-ack` 之前收到的其它消息先排队，最多 64 条，超出时丢最旧的；排队中的 `presence` 只保留最新一条。收到 `hello-ack` 后，页面按到达顺序处理队列。
4. 页面处理完 `hello-ack` 和第一条 `layout`、画出首帧后发 `ready`。
5. 主版本不符：`hello-ack.payload.v` 的 major 不是 1 时，页面发 `error`（`protocol_mismatch`，致命），之后只显示错误提示，忽略后续消息。宿主不支持 `hello.payload.v` 的主版本时，不回 `hello-ack`，也不再发任何消息，直接改显示原生降级界面（提示版本不一致）。宿主收到任何致命 `error` 后，同样改显示原生降级界面。
6. WebGL 上下文丢失：页面调用 `preventDefault()`，停止渲染循环，发 `error`（`context_lost`，非致命）。上下文恢复后，页面用内存里的 layout 和 presence 重建 GPU 资源，然后发 `ready`（`restored: true`）。宿主不必重发数据，重发也没有副作用。
7. 宿主界面不可见（切到后台、被别的路由盖住）时发 `pause`，回到前台时发 `resume`。`pause` 期间宿主不发 `presence`。此外，页面在 `document.hidden` 时也会自行停止渲染循环。

## 4. 页面 → 宿主

| type | payload | 说明 |
|---|---|---|
| `hello` | `{v:"1.0", caps:[...], limits:{maxSpaces:12, maxResidents:8, maxResidentsPerMessage:32}, renderer:{three:"r160", webgl:1或2}}` | `caps` 列出页面支持的可选能力：`tap`、`camera`、`stats`、`focus`、`theme`。 |
| `ready` | `{restored:bool, spaces:int, residents:int}` | 发送时机见第 3 节。 |
| `tap` | `{kind:"villa"或"resident", id, spaceId?}` | 点别墅时 `id` 是 spaceId；点居民时 `id` 是 residentId，`spaceId` 是居民所在的空间。单指、移动小于 10 px、按下到抬起不到 300 ms 才算点击，其余都算拖动镜头。点地面不上报。 |
| `camera` | `{mode:"overview"或"villa", spaceId?}` | 可选。镜头飞到一栋别墅或回到全景后报一次，拖动过程中不报。 |
| `error` | `{code, message, fatal:bool, ref?}` | code 见下表。 |
| `stats` | `{fps, frameMs, calls, mode, residents:{shown, culled, unplaced}}` | 可选。`mode` 取 `running`、`idle`、`paused`、`hidden`。只有 `hello-ack.config.statsIntervalMs` 不小于 1000 时才按该间隔发送。 |

| error.code | 致命 | 含义 |
|---|---|---|
| `bad_envelope` | 否 | 不是 JSON 对象、`v` 不对或缺少 `type`。 |
| `unknown_type` | 否 | 不认识的 type。 |
| `bad_payload` | 否 | 字段缺失或非法。能用的部分照常应用，非法条目丢弃。 |
| `protocol_mismatch` | 是 | 主版本不符。 |
| `webgl_unavailable` | 是 | 无法创建 WebGL 上下文。 |
| `context_lost` | 否 | WebGL 上下文丢失，正在等待恢复。 |
| `internal` | 视情况 | 页面内部异常。 |

## 5. 宿主 → 页面

### `hello-ack`

`{v:"1.0", config:{theme?, quality?, maxResidents?, statsIntervalMs?}}`

- `theme`：`"light"`（默认）或 `"dark"`。
- `quality`：`"high"`（默认，像素比上限 2）或 `"low"`（像素比固定为 1）。
- `maxResidents`：1 到 8，默认 8（NFR-04：同屏不超过 8 个形象）。
- `statsIntervalMs`：0（默认，不发 stats）或不小于 1000 的毫秒数。

### `layout`

`{spaces:[Space, ...]}`

- 每条 `layout` 都是整条街的全量：不在本条里的空间会从街上移除。
- `Space` 就是宿主机 `GET /world/spaces/{spaceId}/layout` 返回的 WorldSpaceLayout JSON（`spaceId`、`version`、`style`、`mainColor?`、`rooms`、`updatedAt?`），另加三个街区字段：
  - `slot?`：0 到 11 的地块编号（见第 6 节）。缺省时用数组下标。两个空间占同一 slot 时，后出现的顺延到下一个空 slot。
  - `label?`：显示名，不超过 32 字符。
  - `relation?`：`"self"`、`"own_ai"`、`"friend"` 或 `"other"`。
- 最多 12 个空间，多出的丢弃，页面回 `bad_payload`。`spaceId` 必须匹配 `^[A-Za-z0-9_-]{1,64}$`（与 jingyu_core 的 `validateId` 一致）。
- 同一个 `spaceId`：`version` 变大才重建别墅；`version` 不变时只更新 `slot`、`label`、`relation`（只移动，不重建）；`version` 变小则忽略这一条。
- `style` 取宿主机 `RoomStyle.wire` 的值：`seaside`、`forest`、`modern`、`cyber`、`chinese_courtyard`，不认识的按 `modern` 处理。`mainColor` 接受 `#RRGGBB` 或 `#RGB`，非法时用该风格的默认色。
- `rooms` 和 `furniture`：v1 只校验结构，不绘制。室内属于 FR-38/39，不在 v1 范围内。

### `presence`

`{t, residents:[Resident, ...]}`

- `t`：宿主的单调毫秒计数（例如 Dart 的 `Stopwatch`），同一页面会话内严格递增。如果 `t` 不大于已处理过的最大值，整条丢弃（latest wins）。
- 每条都是全量快照：不在本条里的居民从场景中移除。每条最多 32 个居民，多出的丢弃。宿主手上超过 32 个时，按第 7 节的优先级挑出 32 个再发；宿主不知道镜头位置，跳过“镜头所在别墅”这一级。
- `Resident`：`{residentId, spaceId, x, y, z, motion, updatedAt?, label?, role?}`
  - `x`、`y`、`z`：单位米，是 `spaceId` 对应地块的局部坐标（见第 6 节），必须是有限数。宿主机 JSON 里的 `position{x,y,z}` 在这里拍平成三个字段。
  - `motion`：`idle`、`walk`、`sit`、`wave`（FR-40，即宿主机 `PresenceMotion.wire`），不认识的按 `idle` 处理。
  - `updatedAt`：ISO-8601 UTC 时间，只用于剔除时排序。
  - `label`：不超过 32 字符。`role`：`self`、`own_ai`、`friend`、`visitor` 或 `other`。
  - `residentId` 必须匹配 `^[A-Za-z0-9_-]{1,64}$`。
- 频率为 2 到 5 Hz，每秒最多 5 条。每个周期的所有居民合并成一条发送。`pause` 期间不发。

### `pause` 和 `resume`

payload 都是 `{}`。
- `pause`：页面停止渲染循环，清空插值缓冲。
- `resume`：页面先画一帧。之后收到的第一条 `presence` 直接落位，不跨越暂停期插值。

### `theme`（可选）

`{mode:"light"或"dark"}`，可以随时切换。

### `focus`（可选）

`{kind:"overview"或"villa"或"resident", id?}`：镜头飞到全景、某栋别墅或某个居民。到位后页面回一条 `camera`。

## 6. 坐标

- 单位米，右手系，+y 向上，地面 y = 0。朝向由页面根据插值速度计算，宿主不发朝向。
- 街区坐标（页面内部使用）：街道沿 +x 方向延伸，中心线在 z = 0。车道 |z| ≤ 3.5，人行道 3.5 < |z| ≤ 5。
- 地块局部坐标：每个空间一块 14 m × 14 m 的地块，原点在地块中心的地面上，x 和 z 都在 [-7, 7] 内。+z 从院门指向地块深处，也就是背离街道的方向。
  - 院门在 (0, 0, -7)。
  - 别墅占地块后半部分：x ∈ [-4.5, 4.5]，z ∈ [0.5, 6.5]。正门在 (0, 0, 0.5)，朝 -z。
  - 前院是 z ∈ [-7, 0.5] 的部分，原点位于前院内。
- 地块到街区的变换：列号 c = floor(slot / 2)；slot 为偶数时侧向 s = +1，为奇数时 s = -1。地块原点放在街区坐标 (16c, 0, 12s)，再绕 +y 旋转 θ（s = +1 时 θ = 0，s = -1 时 θ = π），保证局部 +z 总是背离街道：
  - s = +1：X = 16c + x，Z = 12 + z
  - s = -1：X = 16c − x，Z = −12 − z
  - y 不变。按此变换，院门落在 |Z| = 5 处，也就是人行道外沿。
- 居民的 `spaceId` 不在当前 layout 里时，计为 unplaced，不绘制（v1 没有公共街道空间）。超出地块范围的位置会被钳回地块内再绘制。

## 7. 插值与性能（FR-36、NFR-04）

- 页面按接收时间为每个居民缓存快照。渲染时刻为 now − delay，其中 delay = 1.5 × 最近几次快照间隔的中位数，并限制在 300 到 750 ms 之间（5 Hz 约 300 ms，2 Hz 约 750 ms）。
- 没有更新的快照时，按最后的速度外推，最多 250 ms，之后原地停住。单步位移超过 8 m 或 `spaceId` 改变时直接瞬移。`motion` 在快照时刻切换。
- 同屏人数不超过 `maxResidents`。超出时按以下优先级保留：`role` 为 `self`，其次 `own_ai`，其次镜头所在别墅里的居民，其次 `updatedAt` 较新的，最后按 `residentId` 字典序。其余的计入 `culled`。
- 按需渲染：镜头静止且没有人移动时不出帧；有动画时不超过 30 fps；像素比上限为 2。收到 `pause`、`document.hidden` 或上下文丢失时停止渲染循环。

## 8. 示例

以下 id 均为合成数据。

```json
{"v":1,"type":"hello","ts":1764057600000,"payload":{"v":"1.0","caps":["tap","camera","stats","focus","theme"],"limits":{"maxSpaces":12,"maxResidents":8,"maxResidentsPerMessage":32},"renderer":{"three":"r160","webgl":2}}}
{"v":1,"type":"hello-ack","ts":1764057600050,"payload":{"v":"1.0","config":{"theme":"light","quality":"high","maxResidents":8,"statsIntervalMs":0}}}
{"v":1,"type":"layout","ts":1764057600060,"payload":{"spaces":[{"spaceId":"demo-home-1","version":3,"style":"seaside","mainColor":"#4F8FBF","rooms":[],"slot":0,"label":"我的别墅","relation":"self"}]}}
{"v":1,"type":"presence","id":"p-42","ts":1764057600300,"payload":{"t":125000,"residents":[{"residentId":"demo-resident-1","spaceId":"demo-home-1","x":-1.5,"y":0,"z":-3,"motion":"walk","updatedAt":"2026-11-25T08:00:00Z","role":"self"}]}}
{"v":1,"type":"tap","ts":1764057601000,"payload":{"kind":"villa","id":"demo-home-1"}}
{"v":1,"type":"error","ts":1764057601200,"payload":{"code":"bad_payload","message":"presence.residents[3].x is not a finite number","fatal":false,"ref":"p-42"}}
```

## 9. 变更记录

- 1.0（2026-11-25）：首版。
