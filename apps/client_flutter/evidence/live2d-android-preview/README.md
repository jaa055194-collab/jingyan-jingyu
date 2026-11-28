# Live2D Android 预览截图

本目录保存基于同一台 Android 模拟器、同一主题与视口的 Before / After 截图。Before 为合并基线 `4a08f19`，After 为 PR #188 头 `66fc60c`。测试模型为 CC0 授权的合成模型 `archlive2d-cc0.zip`（1,687,422 字节），仅在设备本机临时预览与保存，不会上传；该 zip 不在仓库中。

## 测试环境

- AVD：`Flutter_API_36`，Android 16 / API 36，`x86_64`，无 Play Store。
- 视口：1080 × 2400，420 dpi；浅色主题（night mode = no），状态栏固定为 12:00。
- WebView：WebGL 2.0（OpenGL ES 3.0 Chromium），渲染器为 Android Emulator OpenGL ES Translator (Google SwiftShader)；软件渲染。
- 应用：debug x86_64，`versionName=1.0.1`，`versionCode=2`，`minSdk=26`，`targetSdk=36`。

## APK 版本

| 组 | 提交 | SHA-256 |
|---|---|---|
| Before | `4a08f19` | `A1098EFA224725D2855E06C0A7C96F8F5DA96A68DEBFA5390BE0F2878D74E4A0` |
| After | `66fc60c` | `933B2E19F78A8A692116C68FD0BF6A03CB14E5EA724763C15D54CE4DAAFF201F` |

## PNG 说明

| 步骤 | Before（4a08f19） | After（66fc60c） | 内容 |
|---|---|---|---|
| 00 | `before-4a08f19-00-notification-permission.png` | `head-66fc60c-00-notification-permission.png` | 首次启动的系统通知授权弹窗，显示 Allow / Don't allow。 |
| 01 | `before-4a08f19-01-onboarding.png` | `head-66fc60c-01-onboarding.png` | 初次设置第 1/3 步“连接你的宿主”，含宿主地址、账户与设备字段。 |
| 02 | `before-4a08f19-02-home.png` | `head-66fc60c-02-home.png` | 登录并跳过设置后的聊天首页与底部导航。 |
| 03 | `before-4a08f19-03-world.png` | `head-66fc60c-03-world.png` | “世界”页；After 的形象模型区新增“从本机选择模型包”“选择 Live2D ZIP”与“本机保存的模型”。 |
| 04 | `before-4a08f19-04-live2d-area.png` | `head-66fc60c-04-live2d-area.png` | 形象模型区域；Before 无导入面板，03 与 04 完全相同；After 展示 Live2D 导入入口与本机保存模型区。 |
| 05 | —（无导入按钮） | `head-66fc60c-05-picker.png` | 系统文件选择器的 Downloads 页面，显示 `archlive2d-cc0.zip`（1.69 MB）。 |
| 06 | — | `head-66fc60c-06-preview.png` | 选择 ZIP 后顶部渲染出的 Live2D 临时预览；下方为“仅本机临时预览，未启用形象。”与“保留此模型 / 清理临时文件”。 |
| 07 | — | `head-66fc60c-07-kept.png` | 点击“保留此模型”后的已保存模型行（`archlive2d-cc0` / `未设置映射`，按钮 设置映射 / 启用 / 删除）与“预览：archlive2d-cc0”卡片。 |
| 08 | — | `head-66fc60c-08-wizard-params.png` | 映射向导第 1/3 步“口型与眨眼（必填）”：ParamMouthOpenY、ParamEyeLOpen、ParamEyeROpen，及“测试眨眼 / 测试说话 / 恢复建议值”。 |
| 09 | — | `head-66fc60c-09-wizard-expressions.png` | 第 2/3 步“表情”：将“开心（happy）”映射为 `Mouse.exp3.json`，其余为“不映射”，并提供“试看”。 |
| 10 | — | `head-66fc60c-10-wizard-motions.png` | 第 3/3 步“动作”：此模型没有动作（已勾选），“确认并保存”可用。 |
| 11 | — | `head-66fc60c-11-saved.png` | 保存后：状态“映射已保存，尚未启用。”，按钮“启用此形象 / 完成”。 |
| 12 | — | `head-66fc60c-12-enabled.png` | 启用后：状态“已启用。暂不会显示在聊天或世界场景中。”，按钮“完成”。 |

## 捕获步骤

1. 卸载旧应用并安装对应 APK（After 为 `head-66fc60c.apk`，其 SHA-256 已在上表校验）。
2. 若出现通知授权弹窗，截图后点击 Don't allow。
3. 在初次设置页以合成演示宿主登录；密码字段长度在日志中只记录为 43，不记录内容。
4. 跳过后续设置，进入聊天首页并打开“世界”页，对齐“形象模型”区域，截图 03 / 04。
5. Before 构建没有“选择 Live2D ZIP”按钮，捕获在 04 后结束；因为该页无可滚动节点，03 与 04 为同一张图。
6. After 构建打开系统文件选择器（05），选择 `archlive2d-cc0.zip`；临时预览就绪后截图 06。
7. 继续 07–12：保留模型 → 映射向导三页（参数 / 表情 / 动作）→ 确认并保存 → 启用此形象。

## 观察

- After 的临时预览与已保存预览均通过 WebView DevTools 读取到 `ready=true`、`loading=false`、`disposed=false`、`contextLost=false`；模型参数 32 个、部件 10 个，画布 935×735（CSS 356×280）。临时预览 `modelId=preview`，启用后为 `live2d-<id>`。
- 控制台可见 `Sakura2D Purism Core version 1.1.0 (compat 6.0.1)` 与 `[Live2DRenderer] prepare webgl2 drawables=29 ... maxTextureSize=4096`。
- 所有截图均为 1080×2400、浅色主题，与 Before 一致。
