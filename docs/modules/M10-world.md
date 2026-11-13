# M10 · world：3D 街区、房间、形象、Live2D

> 依据：v4.2 FR-35～40、AC-22～26、NFR-04；口径 A-5、C-5、C-12、C-13。依赖：social、ai_core。
> 素材与许可：先读 `docs/plugins/02-assets.md`。

## 宿主侧

```text
apps/host/lib/src/world/
  world_module.dart     name 'world'
  layout_store.dart     space_layout：房间布局 + 版本号
  pathfinding.dart      waypoint graph + A*；位置权威在宿主
  presence.dart         2–5Hz 位置同步、拜访会话、门锁
  avatars.dart          形象登记：Live2D 包、VRM；profile_rev 广播
  live2d_import.dart    安全解包与校验（仅宿主机客户端可调用）
```

## 客户端侧

- 3D 页面是独立模块，不嵌进聊天页面（FR-12）：Android 用 WebView，Windows 用 WebView2，加载 feiyu-room-template 的 Three.js 房间。
- 内置插件 `jingyu.room.generator` 实现 `RoomGenerator`，按 `02-assets.md` §2 做"按提示词生成房间"，在首次创建人物时出现。
- Live2D `.moc3` 导入做成 `hostOnly: true` 的插件，朋友端不加载（FR-38）。

## 规则

1. 默认形象是需求方提供的 Live2D 压缩包（口径 A-5）；其他用户可上传自己的；已导入形象可自由切换（口径 C-12）。
2. Live2D 导入安全（FR-39）：Zip Slip 防护；扩展名白名单；拒绝 `.js/.html/.svg/.wasm/.exe/.dll/.so/.bat/.sh`；限制条目数、解压体积、压缩比、JSON 深度；校验纹理魔数与像素总量；缺参数映射禁止启用。
3. 热切换：离屏预载 → 口型≈0 的一帧原子替换 → 新模型首帧成功后销毁旧实例；不中断音频；失败回滚。
4. 拜访：好友可进小院；室内需邀请；单户访客 ≤4；被拉黑方无法拜访（口径 C-5）。
5. 宿主离线时位置冻结，恢复后继续，不补造路上经历（FR-36）。
6. 性能：同屏 ≤8 人，中端安卓室内目标 30fps，空闲降帧（NFR-04）。

## 验收

- [ ] AC-22 AI 从自家走到好友家，路径由宿主计算；门锁、被拒、超时回家都有日志。
- [ ] AC-23 室内需邀请；第 5 位访客被拒；被拉黑方拜访被拒。
- [ ] AC-25 合法 Live2D 包导入成功；缺映射不能启用；恶意包（Zip Slip、含 .js、超大解压）被拒。
- [ ] AC-25 切换形象后双端拿到相同 `model_id + profile_rev`。
- [ ] AC-26 朋友端插件宿主拒绝加载 `hostOnly` 插件（`PluginHost` 已有测试，接入后保持通过）。
- [ ] C-13 房间生成器对五个风格预设都能产出合法 `RoomLayout`；生成结果不含可执行代码。
