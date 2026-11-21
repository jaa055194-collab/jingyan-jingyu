# 聊天置顶 · Flutter 复现与证据

**Before**：`1a04fad5a8745432587716772e95898f00f0c6e0`（`80828d8` 的同源树）。**After**：`11c619394dcb61cf26fe4bc9d029458e5241470e`（客户端代码修订；宿主鉴权补强由集成分支另行提供）。

两次使用同一 [capture driver](chat_pins_capture_test.dart) 和[合成回环夹具](../test/support/chat_pins_fixture.dart)。Windows Flutter 3.50.0 / Dart 3.14.0，390 × 844，DPR 1，浅色主题、字号比例 1，SimHei 和 SDK Material Icons。两端从同一个未变更的宿主夹具选择「周末野餐」，初始聊天显示同样两条文本和一条撤回墓碑，初始截图前没有读写置顶。

| 截图 | 断言对应场景 |
|---|---|
| [Before — 聊天](chat-pins-before-1a04fad.png) | 基线没有会话置顶入口。 |
| [After — 相同聊天](chat-pins-after-chat.png) | 聊天标题新增「置顶消息」按钮；原入群操作保留。 |
| [After — 可见置顶列表](chat-pins-after-list.png) | 点标题按钮，显示已同步且未撤回的置顶消息。夹具也返回了旧宿主可能暴露的隐藏与已撤回元数据，断言这两条和服务器 actor ID 不出现在列表。 |
| [After — 写入前确认](chat-pins-after-confirm.png) | `⋯ → 管理置顶`，读取当前状态后显示共享会话的显式确认按钮；截图时未写入。 |
| [After — 已确认置顶后重读](chat-pins-after-result.png) | 点「置顶」，夹具收到一次正向请求并回完整回执；重新打开列表后，已确认的两条可见消息均出现。取消置顶由 widget 测试覆盖，本图不展示取消。 |

以上为 Flutter 引擎实际输出的 PNG；两轮捕获测试各 1 项通过，5 个图像均检查了签名、尺寸和内容哈希互异。执行模型不支持图像输入，因此不声称人工视觉检查或真机验收。测试使用合成 HTTP 主机，不等于验证集成后的 SQLite 鉴权；宿主事务规则及旧宿主不能作为安全边界的说明见[切片说明](../../../docs/phase-one/chat-pins.md)。

## 重跑

在两版 Flutter 应用内分别 `flutter pub get --offline`；只将同一驱动和夹具复制到基线的 `evidence`、`test/support`。下面命令在各版的 `apps/client_flutter` 运行，`$out` 是输出绝对目录、`$sdk` 是 Flutter SDK 绝对目录：

```powershell
$fonts = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf"
)
# 基线
flutter test --no-pub evidence/chat_pins_capture_test.dart @fonts `
  '--dart-define=CAPTURE_BEFORE=true' `
  "--dart-define=CAPTURE_PATH=$out\chat-pins-before-1a04fad.png"
# 候选
flutter test --no-pub evidence/chat_pins_capture_test.dart @fonts `
  "--dart-define=CAPTURE_PATH=$out\chat-pins-after-chat.png" `
  "--dart-define=CAPTURE_LIST=$out\chat-pins-after-list.png" `
  "--dart-define=CAPTURE_CONFIRM=$out\chat-pins-after-confirm.png" `
  "--dart-define=CAPTURE_RESULT=$out\chat-pins-after-result.png"
```
