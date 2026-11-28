# 鲸言鲸语 · 文档集

> 手机（Android）+ 电脑（Windows）双端、自托管的 AI 聊天软件。自用与朋友小圈子，不公开发表。
> AI 是独立账号：有人格、记忆、音色、形象、持续生活状态；人与 AI 双向聊天并分享任何内容。

## 文档导航

| 文档 | 说明 |
|---|---|
| [鲸言鲸语-需求规格-v4.2.md](../鲸言鲸语-需求规格-v4.2.md) | **单一事实源**：67 条功能需求 + 12 项创造性功能 + 12 条非功能需求 + 35 条验收判据 |
| [docs/创意功能灵感池.md](创意功能灵感池.md) | 夜间迭代过程：灵感来源、候选功能取舍理由 |
| [docs/history/鲸窝-需求规格-v3.1.md](history/鲸窝-需求规格-v3.1.md) | 前期调研文档（历史依据，仅供追溯，不再约束实现） |
| [architecture/01-layering.md](architecture/01-layering.md) | 分层、依赖方向、硬性规则 |
| [architecture/02-decisions.md](architecture/02-decisions.md) | 需求方 2026-11-13 答复口径与框架方提议规则；与 v4.2 冲突时以它为准 |
| [modules/README.md](modules/README.md) | 给实现模型的逐模块编写指令（M01–M13） |
| [plugins/01-plugin-spec.md](plugins/01-plugin-spec.md) | 客户端插件规范 v1 |
| [plugins/02-assets.md](plugins/02-assets.md) | feiyu-room-template 素材复用与许可 |
| [plugins/03-plugin-runtime.md](plugins/03-plugin-runtime.md) | 插件运行时内核：安全加载、安装管理器、沙箱策略与能力桥 |

## 阅读顺序

1. 先读 v4.2 的「0. 文档约定与阅读指南」；
2. 再读 `architecture/02-decisions.md`，了解需求方对待确认项的答复；
3. 实现某个模块时，读 `modules/README.md` 和对应的模块文件。

## 当前状态

- 需求规格 v4.2 定案；待确认项已由需求方于 2026-11-13 答复（见 `architecture/02-decisions.md`）；
- 程序框架已完成：Dart 包 `jingyu_core`、`jingyu_protocol`、`jingyu_host_kit`、`jingyu_client_kit` 与宿主应用 `apps/host`；客户端外壳按 M11 用 Flutter 创建；
- 宿主部署形态：家里常驻电脑 + Tailscale 私有隧道，不对公网开端口。
