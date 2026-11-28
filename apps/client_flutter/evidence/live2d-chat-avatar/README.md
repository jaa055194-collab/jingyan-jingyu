# Live2D 聊天页形象卡片（D1）Android 截图

本目录保存 PR #188 增量 D1（聊天页 Live2D 形象卡片）在同一台 Android 模拟器、同一视口、同一浅色主题下的 Before / After 截图。

- Before：`66fc60c`（D1 之前的代码基线），APK `head-66fc60c.apk`。
- After：`e3f5d47`（D1），APK `d1-e3f5d47.apk`。
- 截图流程使用仓库外的临时脚本 `tmp/cap3/capture.ps1` 与 `tmp/d1cap/chat*.ps1`；本目录只放截图和本说明，没有改动任何产品代码。

## 测试环境

- AVD：`Flutter_API_36`，Android 16 / API 36，`sdk_gphone64_x86_64`，无 Play Store；只读、无快照启动。
- 视口：1080 × 2400，420 dpi；浅色主题（`night mode = no`）；状态栏通过系统 demo mode 固定为 12:00。
- 应用：debug x86_64，`com.jingyu.client_flutter`，`versionName=1.0.1`，`versionCode=2`，`minSdk=26`，`targetSdk=36`。
- WebView：WebGL 2.0（OpenGL ES 3.0 Chromium），渲染器为 Android Emulator OpenGL ES Translator (Google SwiftShader)；模型画布 935 × 735（CSS 356 × 280），32 个参数、10 个部件。
- 宿主：合成演示宿主 `apps/host/tool/demo_s1.dart`，`http://127.0.0.1:18188`（模拟器经 `adb reverse tcp:18188 tcp:18188` 访问），数据目录 `tmp/cap3/host-data`。使用合成演示账户登录；密码不写入本目录、日志或报告。

## APK 版本

| 角色 | 提交 | APK | SHA-256 |
|---|---|---|---|
| Before | `66fc60c` | `head-66fc60c.apk`（74,298,665 字节） | `933B2E19F78A8A692116C68FD0BF6A03CB14E5EA724763C15D54CE4DAAFF201F` |
| After | `e3f5d47` | `d1-e3f5d47.apk`（100,849,159 字节） | `31FE3C6238F44D58A96AD446A7C599581F8DB4BE03F92908A6CE5F8E4E85213D` |

## PNG 说明

| 步骤 | Before（`66fc60c`） | After（`e3f5d47`） | 内容 |
|---|---|---|---|
| 00 | `d1-before-00-notification-permission.png` | `d1-after-00-notification-permission.png` | 首次启动的系统通知授权弹窗（Allow / Don't allow），其下为「初次设置 · 1/3 连接你的宿主」。两次构建逐字节相同。 |
| 01 | `d1-before-01-onboarding.png` | `d1-after-01-onboarding.png` | 通知弹窗关闭后的初次设置第 1/3 步：宿主地址、新建/已有账户、邀请码或账户 ID、显示名称、设备名称、账户密码、连接宿主。两次构建逐字节相同。 |
| 02 | `d1-before-02-chat.png` | `d1-after-02-chat.png` | 登录并跳过设置后，进入「聊天」列表，打开「Synthetic S1 demo group」会话。Before 的聊天页（标题、返回、定时消息/置顶/加成员、消息与输入栏）**没有任何形象卡片**；After 在会话标题与消息之间显示 **Live2D 形象卡片**：标题 `archlive2d-cc0`、右上角收起按钮、模型画面、底部拖动条（默认展开，高度 220 dp / 578 px）。 |
| 03 | — | `d1-after-03-chat-collapsed.png` | 点击右上角「收起形象」后：只剩卡片标题栏与「展开形象」按钮，模型平台视图已卸载，消息列表上移。 |
| 04 | — | `d1-after-04-chat-resized.png` | 再次展开并等待模型重新加载后，从卡片底部拖动条向下拖动约 300 px；模型区域明显变高，下方消息随之让位。 |

所有 PNG 均为 1080 × 2400、浅色主题、状态栏 12:00；可逐张核对。

## 捕获步骤

1. 对每个 APK 先 `adb uninstall` 再 `adb install -t`，保证是全新安装；启动应用。
2. 00：系统通知权限弹窗出现时截图，随后点击 Don't allow。
3. 01：在初次设置页填写宿主地址 `http://127.0.0.1:18188`，切换到「已有账户」，填入合成账户 ID、设备名与密码，点击「连接宿主」；截图。密码只以字段长度出现在脚本日志中，不记录内容。
4. 登录成功、跳过后续设置进入应用外壳后，打开「聊天」Tab，进入「Synthetic S1 demo group」会话，截 02。
5. After 额外走完整 Live2D 启用流程：世界页 → 选择 Live2D ZIP（系统文件选择器）→ 等待临时预览就绪 →「保留此模型」→ 在已保存模型上「设置映射」→ 向导三页（口型/眨眼自动预选 `ParamMouthOpenY`/`ParamEyeLOpen`/`ParamEyeROpen`；表情页把「开心（happy）」映射为 `Mouse.exp3.json`；动作页勾选「此模型没有动作」）→「确认并保存」→「启用此形象」。随后回到聊天页，截 02/03/04。
6. 03：点击卡片右上角「收起形象」。04：点击「展开形象」，等模型重新加载完成，再从底部拖动条向下拖动约 300 px。

## 观察与说明

- **Before 的基线含义**：`66fc60c` 其实已经包含世界页的 Live2D 导入/预览/映射/启用流程（仓库 `evidence/live2d-android-preview` 中已有 `head-66fc60c-05..12` 截图）。本次 Before 采集用 `-Pick no` 只走到世界页第 04 步，未在 Before 上启用模型，以保持最小基线；聊天页没有卡片与「启用形象」入口，是因为 D1 才把 `Live2DAvatarCard` 接进聊天页，而不是因为该 APK 无法导入模型。D1 提交 `e3f5d47` 的改动即为聊天页卡片与会话接线。
- **After 需要先启用模型**：卡片只在存在已启用模型时显示。本次启用的是 CC0 合成测试模型 `archlive2d-cc0.zip`（1,687,422 字节），仅在模拟器本机导入、映射与保存，未上传；该 zip 不在仓库中。模型 ID 为 `live2d-mx03axpv-ka0lvc`，`profileRev=1`。
- **截图 02/03/04 的差异**：02 为默认展开（220 dp）；03 收起后平台视图卸载；04 重新展开并把拖动条下拖约 300 px，模型区域明显变高。三张都保持同一会话、同一状态栏与主题。
- **脚本告警（非产品问题）**：D1 删除了旧提示「已启用。暂不会显示在聊天或世界场景中。」（因为形象现在会显示在聊天页），而 `capture.ps1` 第 12 步仍在等这句旧文案，因此在启用已经成功后以退出码 3 结束并留下 `d1-after-finding.png`。同一时刻 WebView 状态已变为 `modelId=live2d-...`（而非临时预览的 `preview`），随后聊天页卡片正常加载，说明启用本身成功；这是截图脚本的过期断言，不是 D1 缺陷。`d1-after-02/03/04` 是在该断言之后另行捕获的。
- 00/01 在两次构建中逐字节相同：系统通知弹窗与初次设置页不受 D1 改动影响，正好证明同环境、同主题、同视口。
- 本目录只新增 PNG 与 README；未修改、未提交任何产品代码。完整流程截图（00–12）保留在 `tmp/d1cap/out-after`，报告见 `tmp/d1cap/report.md`。