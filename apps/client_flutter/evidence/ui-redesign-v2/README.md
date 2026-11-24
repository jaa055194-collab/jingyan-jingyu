# UI redesign v2: Before/After harness renders

These are harness renders for the v2 client redesign (ticket ui-redesign-v2-58efb3240b0f). They come from `flutter test` with a fake model. They are not native-window captures and do not show a live host.

- `ui_redesign_v2_capture_test.dart` is the capture test. A `CaptureModel` (extends `TestShellModel` from `test/ui_test.dart`, with a `noSuchMethod` fallback) drives the real `WhaleChatApp`. Each scenario renders at 412x915 or 1280x800 logical pixels (device pixel ratio 1), in light or dark, and is saved as `<scenario>-<size>-<theme>.png`. The test only runs when `CAPTURE_OUT` is set. A plain `flutter test` of the file reports one skipped test.
- `before/` holds main `0300369`. The images were rendered from a byte-identical copy of the test (SHA-256 checked) in a clean detached worktree. Afterwards the copy, its directory and `build/` were removed, and the worktree was clean again.
- `after/` will hold the integration branch once the pages are merged.

Fonts: icon fonts load from the app's `FontManifest.json` under their own family names. Microsoft YaHei (`%WINDIR%\Fonts\msyh.ttc`) stands in for every text family, so Chinese renders as it does on Windows. Each scenario advances a fixed 2 s (20 × 100 ms) before capture, without `pumpAndSettle`.

## Renders

| File | Scenario | Source | Checks |
|---|---|---|---|
| `before/conversations-412x915-light.png` | Signed in and online. Six conversations with previews and unread counts; none is open. | `0300369`, test SHA-256 `BEA36212D828…`, 2026-11-25 01:14 +08:00 | 412x915, 275 colors, most common #FAF8F5 at 85.6%, no framework exceptions. Viewed: title 聊天 with 在线 and the settings button, 创建群聊, 刷新会话, six rows with badges 1/2/12, bottom navigation 聊天/联系人/动态/收件箱/世界. |
