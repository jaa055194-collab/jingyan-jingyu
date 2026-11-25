# 消息操作 · Flutter 前后对照

- **Before**：`38cd86c8f3a5c5e8b29a6d997bd02a2790400e96`。
- **After**：`845937c57c3ae0c4e0cea80c0130dd9fa162058b`（代码提交）。
- **匹配条件**：Windows，Flutter 3.50.0 / Dart 3.14.0；逻辑尺寸和 PNG 都为 390 × 844（DPR 1）；Light 主题、字号缩放 1；两侧运行同一 [capture driver](message_operations_capture_test.dart)，从会话列表点击同一个合成「周末野餐」群聊。用本机 SimHei 和 Flutter Material Icons 测试字体。不访问用户聊天、真凭据或外部服务。

| 截图 | 所处状态 |
|---|---|
| [Before — 初始聊天](message-operations-before-38cd86c.png) | 基线实渲染，收到两条文本消息及一条宿主撤回墓碑。 |
| [After — 相同初始聊天](message-operations-after-chat.png) | 同一组消息和宿主回执，无用户操作；新增 `⋯` 入口，自己的消息靠右，墓碑显示「消息已撤回」。 |
| [After — 操作面板](message-operations-after-actions.png) | 点本人消息的 `⋯`，显示复制（系统剪贴板）、编辑和 24 小时撤回入口。 |
| [After — 确认编辑](message-operations-after-edited.png) | 经 UI 提交编辑，回环夹具按现有宿主契约返回回执；测试断言新正文和本机「已编辑」标记。 |
| [After — 撤回确认](message-operations-after-recall.png) | 打开二次确认，尚未提交撤回；这是限制提示，不是新撤回已完成的截图。 |

两版捕获测试各 1 项通过，五个输出均验证 PNG 头与 390×844 尺寸。当前执行模型不能直接读取图像，未做逐像素或人工设备视觉验收。截图不证明真实系统剪贴板、其他设备已缓存的正文被清除、消息跨设备更新或其他消息操作已实现；具体状态与限制见[切片说明](../../../docs/phase-one/msgops.md)。

## 复现

从两个修订的 `apps/client_flutter` 分别执行 `flutter pub get --offline`。将同一份捕获驱动复制到基线的 `evidence` 目录，其余源码保持原修订。以下命令在各自的应用目录运行；`$out` 为收集输出的绝对目录，`$sdk` 为 Flutter SDK 绝对路径。

```powershell
$fonts = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf"
)
# 基线
flutter test --no-pub evidence/message_operations_capture_test.dart @fonts `
  "--dart-define=CAPTURE_PATH=$out\message-operations-before-38cd86c.png"
# 变更后
flutter test --no-pub evidence/message_operations_capture_test.dart @fonts `
  "--dart-define=CAPTURE_PATH=$out\message-operations-after-chat.png" `
  "--dart-define=CAPTURE_SHEET_PATH=$out\message-operations-after-actions.png" `
  "--dart-define=CAPTURE_EDITED_PATH=$out\message-operations-after-edited.png" `
  "--dart-define=CAPTURE_RECALL_PATH=$out\message-operations-after-recall.png"
```
