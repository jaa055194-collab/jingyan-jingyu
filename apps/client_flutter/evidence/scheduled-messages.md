# 群聊定时文字 · Flutter 同场景证据

- **Before**：`e7c2ce7b8e406a4c90a5888099f7f4fc3ee107ca`
- **After**：`7b1043e609fb63825adce4071c068004773c8bfe`
- **同场景**：Windows、Flutter 3.50.0 / Dart 3.14.0，Android 目标平台，390 × 844，DPR 1，浅色主题，文字缩放 1；SimHei 与 SDK Material Icons 测试字体。驱动 [scheduled_messages_capture_test.dart](<scheduled_messages_capture_test.dart>) 使用合成账号、合成群聊和回环宿主边界；不接触真实账号、真实设置或外部网络。两版均在打开定时消息入口前保持同一会话、同一聊天草稿，未发出定时请求。

| 图像 | 可核对内容 |
|---|---|
| [Before — 群聊标题栏](<scheduled-messages-before.png>) / [After — 同一场景](<scheduled-messages-after.png>) | 只在候选版本出现“定时消息”入口；聊天草稿 `保留这段聊天草稿` 两版均保留，没有自动发送。 |
| [发送者状态列表](<scheduled-messages-list.png>) | 当前合成群的本人记录；显示待发送/已发送/已过期状态与“已取消/未发送”说明；正文和他人记录不出现。 |
| [编辑定时文字](<scheduled-messages-compose.png>) | 独立于聊天草稿的普通文字、日期 `2090-06-15`、本地时间 `09:32`；说明绝对时刻和固定偏移。 |
| [确认页](<scheduled-messages-review.png>) | 目标群、普通文字、完整本地时间与 UTC 偏移，以及提交给宿主的 UTC `2090-06-15T01:32:00.000Z`；点确认前没有 POST。 |
| [创建成功](<scheduled-messages-created.png>) | 合成宿主返回精确 200 pending 回执后才显示已知 ID 和待发送行；未声称送达或通知。 |

基线与候选捕获测试各 1 项通过；六张 PNG 均为 390×844、不同 SHA-256，签名已检查。当前执行模型不支持图像输入，未做人工像素审查。不是 Android 真机、真实宿主发送、系统通知或跨设备同步证据。

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
flutter test --no-pub --reporter expanded evidence/scheduled_messages_capture_test.dart @args '--dart-define=CAPTURE_BEFORE=true'
# 候选
flutter test --no-pub --reporter expanded evidence/scheduled_messages_capture_test.dart @args
```
