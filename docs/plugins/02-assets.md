# 素材复用：feiyu-room-template

> 来源：<https://github.com/sh2234113/feiyu-room-template>（模板 v3.0.0）。需求方 2026-11-13 确认可使用该模板的任何内容，包括"按提示词生成房间"。
> 本文件记录**每类素材的许可证**，实现模型复用时必须遵守。需求方的许可不能改变第三方素材本身的许可证。

## 1. 可以复用什么、按什么条件

| 内容 | 位置（模板仓库） | 许可证 | 条件 |
|---|---|---|---|
| 房间、菜园、角色行为代码 | `public/room/*.js`、`src/` | MIT | 保留 MIT 版权声明。 |
| Three.js 与 GLTFLoader | `public/room/vendor/` | MIT | 保留 `LICENSE-three.txt`。 |
| 2D 立绘、动画、点击音效 | `public/room/assets/pet/` | **CC BY-NC-SA 4.0**（来自 dsh-pet） | 必须署名；非商业；改动后同样以 CC BY-NC-SA 共享；保留 `CREDITS.md`。 |
| 3D 模型 `da-feiyu.opt.glb`（6.7MB）/ `da-feiyu.glb`（58.9MB） | `public/room/assets/models/` | 模板作者版权，仅随模板做个人非商业展示 | 不得单独提取、转售、商用、批量再分发。本项目只在需求方本机自用，可以加载；**不要**把它打包分发给朋友端以外的人。 |
| 房间生成提示词 | `HOUSE_GENERATION_PROMPT.md` | MIT（随仓库） | 改写为 `RoomGenerator` 插件的系统提示词与 brief 模板。 |

本项目是自用小圈子，不商业化（v4.2 FR-02），满足 CC BY-NC 的非商业条件。

## 2. 落地方式

- 房间前端是 Three.js 网页。v4.2 FR-12 要求 3D 世界以**独立模块**接入客户端，不内嵌聊天页面。M10 用 WebView（Android）/ WebView2（Windows）承载模板的房间页面，作为独立的 3D 页面。
- "按提示词生成房间"做成内置插件 `jingyu.room.generator`（能力 `roomScene` + `modelInvoke`），由 client kit 的 `FeiyuRoomGenerator` 实现（`packages/jingyu_client_kit/lib/src/room_generator.dart`）：
  - `presets` 取模板的五个方向：海边小屋、森林木屋、现代公寓、赛博小屋、中式小院；
  - `RoomBrief` 字段对应模板的 brief：风格、主色、氛围、户型、备注；
  - 生成结果是 `RoomLayout` 布局数据，存宿主 `space_layout` 并带版本号（FR-35），**不生成、不下载可执行代码**。
- 首次创建 AI 时进入"创建人物 + 房间"向导：先选形象，再填 brief，生成房间并预览。
- 模板里的 QQ 桥接、SnowLuma、DSH preset **不复用**：与本项目无关，且引入外部账号风险。

## 3. 必须保留的署名文件

复制素材到本仓库时，同时复制：

```text
third_party/feiyu-room-template/LICENSE
third_party/feiyu-room-template/THIRD_PARTY_NOTICES.md
third_party/feiyu-room-template/assets/pet/CREDITS.md
```

并在插件 `plugin.json` 的 `assetCredits` 写明：

```json
"assetCredits": [
  "feiyu-room-template (MIT) https://github.com/sh2234113/feiyu-room-template",
  "dsh-pet 立绘与动画 (CC BY-NC-SA 4.0) https://github.com/PC2005-cloud/dsh-pet",
  "three.js (MIT)"
]
```

## 4. 大文件

`da-feiyu.glb`（58.9MB）不进本仓库。M10 首次运行时从模板仓库按固定 commit 下载到宿主数据目录，并校验 sha256。下载地址过 `UrlGuard`。
