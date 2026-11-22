# 主动联系与聊天历史自动记忆 · Flutter 同场景证据

- **Before**：`269890ced23897b14b30db347406bf3fbd0fed7b`（合并后的 main，PR #181 已合入）
- **After**：`5e7c13d0a641e5df5abc13f6245c5d3a77db748f`（本 PR 分支头）
- **同场景**：Windows、Flutter 3.50.0 / Dart 3.14.0，Android 目标平台 390 × 844，DPR 1，浅色主题，文字缩放 1；材料字体与 CJK 字体显式加载。
- **驱动**：[memory_proactive_capture_test.dart](<memory_proactive_capture_test.dart>) 复用真实「设置 → AI 运行配置」导航与真实编辑器，只在宿主边界使用合成连接；不接触真实账号、真实配置或外部网络。两份修订运行**同一个测试文件**，因此场景、视口和主题一致。

| 图像 | 可核对内容 |
|---|---|
| [Before · AI 运行配置](<memory-proactive-before.png>) / [After · 自动记忆区段](<memory-proactive-after-auto-memory.png>) | 基线只有私聊回复偏好、本人规则问候、记忆便签三个区段；候选中新增「自动记忆」区段，显示默认关闭、仅当前本人 AI 私聊、不采集群聊或第三人内容，并提供「读取当前设置」。 |
| [After · 模型主动联系区段](<memory-proactive-after-proactive.png>) | 同一编辑器中新增「本人模型主动联系」区段：默认关闭、仅 B3 预算内本人私聊、使用模型但不读记忆或聊天历史、错过不补发，并提供「读取当前主动联系设置」。 |

`flutter test` 对两张 After 图与一张 Before 图均断言解码后的图像尺寸恰为 390 × 844；三图 SHA-256 不同，分别对应基线与候选的两个不同区段。当前执行模型不支持图像输入，未做人工像素审阅；证据仅为同场景实际 Flutter 渲染捕获，不是设计稿或 mockup。

不覆盖 Android 真机、真实账号、真实宿主数据、真实外部 Provider 或跨设备同步。

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
flutter test --no-pub --reporter expanded evidence/memory_proactive_capture_test.dart @args '--dart-define=CAPTURE_BEFORE=true'
# 候选
flutter test --no-pub --reporter expanded evidence/memory_proactive_capture_test.dart @args
```
