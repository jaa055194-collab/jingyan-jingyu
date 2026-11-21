# 本人 AI 私聊回复偏好 · Flutter 证据

- **Before**：`1a04fad5a8745432587716772e95898f00f0c6e0`（已合入 #175 的同源树）。
- **After**：`8f415e0af6c0ec5e60601e3471de761d9d1e5eb8`（客户端代码修订，包含 `448cf91` 的既定路由常量依赖）。
- **同场景**：Windows、Flutter 3.50.0 / Dart 3.14.0，390 × 844，DPR 1，浅色主题，字号比例 1；SimHei 与 SDK Material Icons 测试字体。两版从同一实渲染的 Settings 路由打开同一个已解析的合成自有 AI 档案，初始均未读取/更改偏好。 [捕获驱动](owner_reply_preferences_capture_test.dart) 使用同一个[合成宿主边界夹具](../test/support/owner_reply_preferences_fixture.dart)，不访问外部模型、真实账号或部署。

| 图像 | 可核对状态 |
|---|---|
| [Before — 初始 AI 运行配置](owner-reply-preferences-before-1a04fad.png) | 原编辑器没有私聊回复偏好入口。 |
| [After — 同一初始场景](owner-reply-preferences-after.png) | 新的独立偏好卡与「读取当前状态」。过程只进行了原有的档案解析，没有偏好读写。 |
| [After — 授权之前确认](owner-reply-preferences-review.png) | 明示固定选择与持续自动使用范围，并显示 Provider ID、接收 origin 和模型；不显示目标令牌，尚未发出偏好写入。 |
| [After — 关闭后](owner-reply-preferences-disabled.png) | 合成夹具确认撤回授权，显示未授权自动使用，先前简短/要点仍保留。不是清除操作或实际模型调用证据。 |

基线、候选的 Flutter 捕获测试分别通过；4 张 PNG 的签名、390×844 尺寸与互异哈希均已检查。本执行模型不支持图像读取，未做人工像素审查；这里不声称真机、真实提供方、宿主加密存储或模型注入通过。范围和客户端定向检查见[设置切片说明](../../../docs/phase-one/owner-reply-preferences-ui.md)。

## 复现

两版 Flutter 应用内分别运行 `flutter pub get --offline`。把同一份捕获驱动及夹具复制到基线的 `evidence`、`test/support`；不更动其他基线源码。分别在对应 `apps/client_flutter` 内运行：

```powershell
# $out 为输出绝对目录，$sdk 为 Flutter SDK 根目录
$fonts = @(
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf',
  "--dart-define=CAPTURE_ICON_FONT=$sdk\bin\cache\artifacts\material_fonts\MaterialIcons-Regular.otf"
)
# 基线
flutter test --no-pub evidence/owner_reply_preferences_capture_test.dart @fonts `
  '--dart-define=CAPTURE_BEFORE=true' `
  "--dart-define=CAPTURE_PATH=$out\owner-reply-preferences-before-1a04fad.png"
# 候选
flutter test --no-pub evidence/owner_reply_preferences_capture_test.dart @fonts `
  "--dart-define=CAPTURE_PATH=$out\owner-reply-preferences-after.png" `
  "--dart-define=CAPTURE_REVIEW=$out\owner-reply-preferences-review.png" `
  "--dart-define=CAPTURE_DISABLED=$out\owner-reply-preferences-disabled.png"
```
