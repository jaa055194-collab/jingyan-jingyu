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
  avatars.dart          VRM 与设备本地 Live2D profile 引用；不含模型字节
```

## 客户端侧

- 3D 页面是独立模块，不嵌进聊天页面（FR-12）：Android 用 WebView，Windows 用 WebView2，加载 feiyu-room-template 的 Three.js 房间。
- 内置插件 `jingyu.room.generator` 实现 `RoomGenerator`，按 `02-assets.md` §2 做"按提示词生成房间"，在首次创建人物时出现。
- 本地 profile 元数据校验位于 `packages/jingyu_client_kit/lib/src/live2d_profile.dart`，不属于宿主 registry；只校验配置，不检查模型文件是否存在或参数名是否真实可用。
- Live2D 选择/导入由每位用户在自己的设备执行；不使用 `hostOnly` 插件门控。各设备独立保存模型文件与 profile，跨端只同步稳定引用和 revision；远端缺少该引用或本地文件时应回退 VRM，不能下载其他用户模型。

## 规则

1. 每个设备独立选取用户自行取得的 Live2D 模型；默认目录/模型包不由应用提供。VRM 保持默认跨端 fallback。
2. profile 只保存相对 model3 manifest 路径、稳定 model_id、profile_rev 与语义 param_map，不保存模型字节、绝对路径、URL、API key 或 Cubism/Core 文件；模型字节不得进入服务端附件、同步、导出或共享备份。
3. profile schema 与 mapping 校验是导入安全流程的一部分；实际解包器仍须实施 Zip Slip 防护、白名单/拒绝扩展名、条目数/解压体积/压缩比/JSON 深度上限、纹理魔数和像素总量校验。缺口型、左右眨眼、表情或动作映射时不得启用；不可猜参数。
4. 热切换须离屏预载 → 句边界/口型≈0 的一帧原子替换 → 新模型首帧成功后销毁旧实例；不中断音频；失败回滚。当前仅定义 profile metadata，runtime 与热切换尚未实现。
5. 拜访：好友可进小院；室内需邀请；单户访客 ≤4；被拉黑方无法拜访（口径 C-5）。
6. 宿主离线时位置冻结，恢复后继续，不补造路上经历（FR-36）。
7. 性能：同屏 ≤8 人，中端安卓室内目标 30fps，空闲降帧（NFR-04）。

## 授权与复用边界

- 朋友端模型由用户自行取得并承担其对模型素材的授权责任；本项目不提供、内置、上传或向他人分发任何 `.moc3`/模型包。
- 本项目不分发 Cubism SDK/Core 二进制或 SDK 资产。Live2D 将 SDK 使用/发布与出版许可相联系；尚未取得覆盖本项目应用发布方式的书面确认，不能将其标注为已获许可。
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
- [ ] AC-25 同步只含 `model_id + profile_rev` 引用，不接受或返回本地模型参数映射、路径或模型文件。
- [ ] AC-26 各设备自行导入兼容模型后独立渲染；缺本地模型/映射时回退 VRM；不捆绑或分发模型/Cubism 资产。通用 `hostOnly` 插件机制不受此变更影响。
- [ ] C-13 房间生成器对五个风格预设都能产出合法 `RoomLayout`；生成结果不含可执行代码。
