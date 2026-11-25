# 消息表情回应 · Android 优先 Flutter 对照

- **Before**：`fda8453735016b88f4a89040d62ee09a5c3169e9`。
- **After**：`3b4378b2fc0e3c2e246a7c5e75d7c7347d39a10e`（客户端代码树；宿主鉴权补强另集成）。
- **同一场景**：Flutter 3.50.0 / Dart 3.14.0 的实际 widget engine 渲染，390×844 逻辑像素，DPR 1、浅色主题、字号比例 1。两版均打开同一个合成群聊并点同一条对端消息的 `⋯`，在任何回应 GET/POST 之前捕获操作菜单；不使用真实账户、消息或部署。

| 图像 | 捕获状态 |
|---|---|
| [Before — 原操作菜单](chat-reactions-before-fda8453.png) | 未加表情回应，复制和管理置顶仍可用。 |
| [After — 同一操作菜单](chat-reactions-after-menu.png) | 复制、管理置顶保留，新增「表情回应」入口；打开菜单没有后台读写。 |
| [After — 已读取回应](chat-reactions-after-picker.png) | 进入后读取六个固定表情的聚合状态；合成数据的爱心是本人已选，赞未选。原始账户标识和旧版任意字符串未进入界面。 |
| [After — 单次点赞并核对](chat-reactions-after-confirmed.png) | 测试验证一次点赞 POST 加一次 GET，当前账号的点赞状态与回执一致，才显示成功和新计数。 |

基线、候选各 1 个捕获测试通过；4 张 PNG 的签名、尺寸、互异 SHA-256 已检查。使用 [Flutter 驱动](chat_reactions_capture_test.dart) + [合成回环宿主夹具](../test/support/chat_reactions_fixture.dart)；字体为本机 SimHei、Segoe UI Emoji 与 Flutter SDK Material Icons。执行模型不支持读图，未做人工像素或终端字体审查。没有在 Android 模拟器或物理手机上运行本捕获；不能把 390×844 说成 Android 运行验收。

## 重跑

两版 Flutter 应用内运行 `flutter pub get --offline`；复制同一捕获驱动、回应夹具到基线现有 `evidence` 和 `test/support`。以下分别在两版 `apps/client_flutter` 运行（`$out` 为 PNG 输出绝对目录，`$sdk` 为 Flutter SDK 根目录）：

```powershell
$fonts = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  '--dart-define=CAPTURE_EMOJI_FONT=C:\Windows\Fonts\seguiemj.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf"
)
# 基线
flutter test --no-pub evidence/chat_reactions_capture_test.dart @fonts `
  '--dart-define=CAPTURE_BEFORE=true' `
  "--dart-define=CAPTURE_PATH=$out\chat-reactions-before-fda8453.png"
# 候选
flutter test --no-pub evidence/chat_reactions_capture_test.dart @fonts `
  "--dart-define=CAPTURE_PATH=$out\chat-reactions-after-menu.png" `
  "--dart-define=CAPTURE_PICKER=$out\chat-reactions-after-picker.png" `
  "--dart-define=CAPTURE_CONFIRMED=$out\chat-reactions-after-confirmed.png"
```
