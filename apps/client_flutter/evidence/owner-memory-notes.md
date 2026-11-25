# 记忆便签 · Flutter 同场景证据

- **Before**：`b303c0291e326d9245b8d0f8ecfe5db95a06443d`
- **After**：`ab1bff5020d80848afb448ceb0b15c350706c027`（协议路由依赖 `56df973b094ca751e2947381f54455ca2b213366`）
- **同场景**：Windows、Flutter 3.50.0 / Dart 3.14.0，Android 目标平台，390 × 844，DPR 1，浅色主题，文字缩放 1；SimHei 与 SDK Material Icons 测试字体。驱动 [owner_memory_notes_capture_test.dart](<owner_memory_notes_capture_test.dart>) 使用合成 AI 档案、合成便签（`喜欢桂花`/`第二句便签`）和回环宿主边界；不接触真实账户、真实设置或外部网络。两版初始均未读取便签状态。

| 图像 | 可核对内容 |
|---|---|
| [Before — AI 运行配置](<owner-memory-notes-before.png>) / [After — 同一场景](<owner-memory-notes-after.png>) | 基线没有记忆便签入口；候选显示“记忆便签”与显式读取，尚未请求宿主状态。 |
| [读取后的便签列表](<owner-memory-notes-list.png>) | 两条合成便签、条数/大小上限和独立使用授权（默认关闭）；没有聊天记录或第三人内容。 |
| [开启授权确认](<owner-memory-notes-review.png>) | 当前 AI、仅当前本人 AI 私聊范围、provider/model/origin；说明不是聊天历史、不会主动发送；token 不显示。 |

基线与候选捕获测试各 1 项通过；四张 PNG 均为 390×844，签名和不同 SHA-256 已检查。当前执行模型不支持图像输入，未做人工像素审查。不是 Android 真机、真实宿主、真实数据或跨设备同步证据。

## 复现

```powershell
# 在基线和候选的 apps/client_flutter 中；$out 为证据目录绝对路径
$sdk = Split-Path (Split-Path (Get-Command flutter).Source)
$args = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf",
  "--dart-define=CAPTURE_OUTPUT=$out"
)
# 基线
flutter test --no-pub --reporter expanded evidence/owner_memory_notes_capture_test.dart @args '--dart-define=CAPTURE_BEFORE=true'
# 候选
flutter test --no-pub --reporter expanded evidence/owner_memory_notes_capture_test.dart @args
```
