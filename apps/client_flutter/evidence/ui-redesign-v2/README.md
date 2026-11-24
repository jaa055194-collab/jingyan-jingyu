# UI redesign v2: Before/After harness renders

These are harness renders for the v2 client redesign (ticket ui-redesign-v2-58efb3240b0f). They come from `flutter test` with a fake model. They are not native-window captures and do not show a live host.

- `ui_redesign_v2_capture_test.dart` is the capture test. A `CaptureModel` (extends `TestShellModel` from `test/ui_test.dart`, with a `noSuchMethod` fallback) drives the real `WhaleChatApp`. Each scenario renders at 412x915 or 1280x800 logical pixels (device pixel ratio 1), in light or dark, and is saved as `<scenario>-<size>-<theme>.png`. The test only runs when `CAPTURE_OUT` is set. A plain `flutter test` of the file reports one skipped test.
- `before/` holds main `0300369`. Each batch was rendered from a byte-identical copy of the test (SHA-256 checked) in the clean detached baseline worktree. Afterwards the copy, its directory and `build/` were removed, and the worktree was clean again.
- `after/` will hold the integration branch once the pages are merged.

Fonts: icon fonts load from the app's `FontManifest.json` under their own family names. Microsoft YaHei (`%WINDIR%\Fonts\msyh.ttc`) stands in for every text family, so Chinese renders as it does on Windows. Each scenario advances a fixed 2 s (20 × 100 ms) before capture, without `pumpAndSettle`.

## Before (main 0300369)

Every scenario has four files: `<scenario>-412x915-light.png`, `-412x915-dark`, `-1280x800-light` and `-1280x800-dark`. All renders exited 0 with no framework exceptions, and every image was viewed.

| Scenario | State | What the render shows |
|---|---|---|
| `conversations` | Signed in and online; six conversations with previews and unread counts, none open. | Title 聊天 with 在线 and the settings button, 创建群聊, 刷新会话, six rows with badges 1/2/12. Phone: bottom navigation 聊天/联系人/动态/收件箱/世界. Wide: navigation rail, the list, and 选择一个会话，开始聊天 on the right. |
| `conversations-empty` | Signed in and online; no conversations. | 暂无会话 / 可以创建群聊，或等好友发来消息。 |
| `conversations-offline` | Signed in, offline; nothing loaded. | 离线 in the title bar, 创建群聊 disabled, 暂时离线 / 恢复连接后，会显示你的聊天。 |
| `conversations-error` | Signed in and online; reading the conversations failed. | Error banner 会话读取失败，请稍后重试 with a close button, 没有可显示的会话, 重新读取. |

Render log (time +08:00, test SHA-256 prefix):

- 2026-11-25 01:14: `conversations-412x915-light`, test `BEA36212D828`.
- 2026-11-25 01:46: all four `conversations*` scenarios, test `6618766F5463`. `conversations-412x915-light` came out byte-identical to the 01:14 render.
