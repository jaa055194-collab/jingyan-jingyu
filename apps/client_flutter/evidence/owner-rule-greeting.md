# 本人规则问候 · Flutter Before / After

- **Before**：`b915a33354a2e44dc2087dfe2f5e85eedc079c14`。
- **After**：`8dd537be5fa639f9e58d768bd4cfaebc4546b1bb`（含既定协议路由依赖 `684563b78a3891d0e31e18f8950f4b50828a3acc`）。
- **同场景**：同一 Flutter 应用、合成账号和 AI 清单；Windows 上 Flutter 3.50.0 / Dart 3.14.0，以 Android 目标平台和 390 × 844 逻辑像素渲染，DPR 1、浅色主题、文字缩放 1；测试字体为 SimHei 和 SDK Material Icons。运行 [捕获驱动](<owner_rule_greeting_settings_capture_test.dart>) 与同一 [宿主边界夹具](<../test/support/owner_rule_greeting_fixture.dart>)，不改变基线业务源码。首次打开 Settings 无网络调用；进入编辑器只执行既有档案解析，此时未读取问候状态。

| 实际 Flutter 捕获 | 核对内容 |
|---|---|
| [Settings Before](<owner-rule-greeting-before.png>) / [Settings After](<owner-rule-greeting-after.png>) | 同一 Settings 初始位置；新增可触达的独立账户级停止入口。 |
| [AI 编辑器 Before](<owner-rule-greeting-editor-before.png>) / [AI 编辑器 After](<owner-rule-greeting-editor-after.png>) | 同一已解析合成 AI；新增显式读取入口，不猜测宿主状态。 |
| [授权确认](<owner-rule-greeting-review.png>) | 每日 01:30，显式 UTC+08:00，静默 23:00–08:00。显示当前 AI、适用范围及静默顺延；此时没有写入。 |
| [撤回单个 AI](<owner-rule-greeting-disabled.png>) | 合成宿主确认关闭该 AI，仍显示先前保存的偏移及时间。 |
| [账户已停止](<owner-rule-greeting-blocked.png>) | 合成宿主确认总停止；解除不会为任何 AI 恢复授权。 |

最后一次 UI 行为变更后，基线与候选分别重新运行捕获测试，各 1 项通过；确认入口、确认按钮和撤回后偏移等在捕获时可命中。七张 PNG 的签名、尺寸及不同 SHA-256 均经检查。当前执行模型不支持图像输入，未做人工像素审查。捕获不是 Android 真机、真实账号设置、宿主发送、系统通知或模型执行证据。详见 [设置切片说明](<../../../docs/phase-one/owner-rule-greeting-ui.md>)。

## 复现

使用已有 Flutter SDK。在基线和候选的 `apps/client_flutter` 分别解析离线依赖，把同一驱动和夹具复制到基线相同相对位置。两边指定同一证据输出目录（已存在）和字体：

```powershell
# 在对应 apps/client_flutter 中；$out 是证据目录绝对路径
$sdk = Split-Path (Split-Path (Get-Command flutter).Source)
$fontArgs = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf",
  "--dart-define=CAPTURE_OUTPUT=$out"
)
# 在基线运行：
flutter test --no-pub --reporter expanded evidence/owner_rule_greeting_settings_capture_test.dart @fontArgs '--dart-define=CAPTURE_BEFORE=true'
# 在候选运行：
flutter test --no-pub --reporter expanded evidence/owner_rule_greeting_settings_capture_test.dart @fontArgs
```
