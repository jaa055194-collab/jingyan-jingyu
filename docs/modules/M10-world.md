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
  avatars.dart          VRM/设备本地 Live2D 选择，按设备隔离；不含模型字节
```

## 客户端侧

- 3D 页面是独立模块，不嵌进聊天页面（FR-12）：Android 用 WebView，Windows 用 WebView2，加载 feiyu-room-template 的 Three.js 房间。
- 内置插件 `jingyu.room.generator` 由 client kit 的 `FeiyuRoomGenerator` 实现 `RoomGenerator`，按 `02-assets.md` §2 做"按提示词/对话建屋"：五个风格预设 + `RoomBrief`→`RoomLayout`，只产出布局数据，不下载或执行代码；`briefFromConversation` 把对话文本映射为 brief。
- 本地 profile 元数据校验位于 `packages/jingyu_client_kit/lib/src/live2d_profile.dart`，只在设备本地校验配置，不检查数据库或参数名是否真实存在。
- 设备本地档案与列表由 `Live2DModelStore` 保存（revision 校验、激活、原子 JSON 快照，不含模型字节）；模型包安全校验由 `validateLive2DPackage` 完成（Zip Slip/白名单/体积/压缩比/JSON 深度、引用完整性、MOC3 与 PNG 魔数、纹理像素预算）；纹理按 `planLive2DTextures` 的移动端预算降采样规划。
- 渲染桥接：client kit `Live2DRendererBridge` 定义 Flutter↔WebView 的加载/参数/表达式/动作/错误/销毁协议与 idle→loading→ready 状态机；WebView 实体与资源服务由外壳实现，尚未接入真实渲染。
- Live2D 选择/导入由每位用户在自己的设备执行；不使用 `hostOnly` 插件门控。各设备独立保存模型文件与 profile，**不做跨端同步、不广播单一 model_id/profile_rev**；同一账号的手机与电脑可各自使用不同模型（如手机 B、电脑 C）。设备缺少本地模型或有效映射时回退 VRM，不下载他端模型。

## 规则

1. 每个设备独立选取用户自行取得的 Live2D 模型；默认目录/模型包不由应用提供。VRM 保持默认 fallback。形象选择按设备隔离，不做双端一致；同账号各设备互不影响。
2. profile 只保存相对 model3 manifest 路径、稳定 model_id、profile_rev 与语义 param_map，不保存模型字节、绝对路径、URL、API key 或 Cubism/Core 文件；模型字节不得进入服务端附件、同步、导出或共享备份。
3. 导入安全由两层组成：`validateLive2DPackage` 在设备本地校验压缩包（Zip Slip、拒绝脚本/可执行扩展名、条目数/单条/总量/压缩比、model3 JSON 深度、被引用文件是否存在、MOC3 魔数与版本、PNG 魔数与纹理像素预算），`Live2DProfile` 再校验显式映射。缺口型/左右眨眼/表情/动作映射禁止启用，不许猜参数。两层都只是元数据/字节校验，不证明参数名存在于模型、也不证明渲染正确。
4. 热切换须离屏预载 → 句边界/口型≈0 的一帧原子替换 → 新模型首帧成功后销毁旧实例；不中断音频；失败回滚。当前仅定义 profile metadata，runtime 与热切换尚未实现。
5. 拜访：好友可进小院；室内需邀请；单户访客 ≤4；被拉黑方无法拜访（口径 C-5）。
6. 宿主离线时位置冻结，恢复后继续，不补造路上经历（FR-36）。
7. 性能：同屏 ≤8 人，中端安卓室内目标 30fps，空闲降帧（NFR-04）。形象/Live2D 渲染以骁龙 888 稳定 30–60fps 为目标；暂无真机时先实现，整体完成后再实测，不把估算当实测。
8. 移动端纹理优化：`planLive2DTextures` 以保守的骁龙888级别预算（每边 ≤8192、RGBA8 总量 ≤256MiB）对纹理规划降采样，超长边等比缩放、超总量统一减半；提供的模型可据此从约 592MiB 压到预算内。真实 `MAX_TEXTURE_SIZE`、显存与帧率仍以真机/日志为准。

## 授权与复用边界

- 朋友端模型由用户自行取得并承担其对模型素材的授权责任；本项目不提供、内置、上传或向他人分发任何 `.moc3`/模型包。
- **个人自用授权口径**：Live2D 上传即可使用，不做事前授权校验，使用人自负；应用仍不捆绑或分发模型或 Cubism SDK/Core 资产。
- Live2D 官方：[SDK 发行许可](https://www.live2d.com/zh-CHS/sdk/license/)、[Cubism Core 专有软件协议](https://www.live2d.com/eula/live2d-proprietary-software-license-agreement_en.html)。此处仅记录风险，不构成法律意见。
- Coopanion 仅作为架构参考：其仓库采用 AGPL-3.0-or-later，figure-pack/分离部件 rig 不是 `.moc3` renderer，也非 Flutter Android/Windows drop-in；本项目未复制代码或资产。
- PurismCore `v1.1.0` 为 MIT 的可行候选；已在本地用发布 WASM v5/v6 core 对提供的模型完成 MOC3 一致性校验、模型构造与一次 update（详见 `docs/research/purismcore-model-compatibility.md`）。这证明该文件可由该 core 读取，不证明真实图像、Flutter WebView 集成、物理/动作、性能或生产安全。
- 最快渲染原型方向是评估/适配 PurismCore 自带的 Raylib WebGL2 viewer 到受控本地 WebView；viewer 文档明确称其不完整、没有 physics 和完整 JSON parser。不得直接采用其 ZIP loader 作为安全导入器；必须单独实现并测试路径/条目/体积/JSON/纹理上限。尚未将该候选接入应用或作最终选型。
- 提供的某张纹理为 8192×8192；所有五张 RGBA8 base texture 合计约 592 MiB，尚未计入副本、WASM、mask/offscreen 缓冲。WebView 设备必须验证 `MAX_TEXTURE_SIZE >= 8192` 或经批准的降采样方案，并做真实中端安卓内存/帧率测试；当前没有这些证据。
- 开源 core 的 MIT 许可不等于素材许可或格式/商标法律结论。保留已提供素材来源署名，并不得把模型或整个资源包放进安装包/公开产物。

## 验收

- [ ] AC-22 AI 从自家走到好友家，路径由宿主计算；门锁、被拒、超时回家都有日志。
- [ ] AC-23 室内需邀请；第 5 位访客被拒；被拉黑方拜访被拒。
- [ ] AC-25 合法 Live2D 包导入成功；缺映射不能启用；恶意包（Zip Slip、含 .js、超大解压）被拒。
- [ ] AC-25 模型与映射只存本设备、不跨端同步；服务端不广播单一 model_id/profile_rev。
- [ ] AC-26 同一账号手机与电脑可各用不同模型（B/C）互不影响；缺本地模型/映射时回退 VRM；不捆绑或分发模型/Cubism 资产。通用 `hostOnly` 插件机制不受此变更影响。
- [ ] C-13 房间生成器对五个风格预设都能产出合法 `RoomLayout`；生成结果不含可执行代码。
