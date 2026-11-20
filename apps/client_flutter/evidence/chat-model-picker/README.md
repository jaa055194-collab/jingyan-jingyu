# Chat binding model catalog evidence

## Matched comparison

| Frame | Production revision | SHA-256 |
| --- | --- | --- |
| [Before](before.png): existing manual chat-binding fields and Save | `85b7f5e1fcbc2deee6dca1715a8b69abfac1e8e6` | `2F6D3C9A994604680E7F66CC9FB0A3AE1032D1F221EC3D523E31EBF4FCA6AB85` |
| [After](after.png): same draft plus the explicit catalog action | `428e330a1408c502630f12ca30ea7de899151149` | `06EAECB49550E343D58922E970DC71E6DB75968937888F22C6E4551395648B95` |
| [Follow-on, selection filled but not saved](after-picked-unsaved.png) | `428e330a1408c502630f12ca30ea7de899151149` | `6B3333D65FE86F5B6CD752D5F5DE67CB4FF6B737CC064F997AA0CC3C1AB9E6CD` |

The [capture driver](../chat_model_picker_capture_test.dart) renders the real `WhaleChatApp`, taps 设置, opens the existing AI 运行配置 route, and scrolls to 聊天绑定. It substitutes a synthetic authenticated, unlocked `ClientRuntime` session and an in-process `HostConnection` fixture. The paired frames use the same owned AI, the same typed `provider-fixture` and `fixture-manual-model`, no field focus, and the shared binding-help anchor 64 logical pixels into the editor viewport. Save is visible in both frames; neither clicks it or reads a catalog. Both exercise the editor's existing profile registration/resolution POST.

The follow-on is not part of the matched pair. It explicitly reads the fixture's saved provider catalog, selects `fixture-model-fast`, and asserts that the existing model field updates. The only requests observed are the existing profile POST and one catalog GET. There is no binding PUT.

- 1280×960 logical and physical pixels, DPR 1, light Material theme, font scale 1.0. Flutter 3.50.0 / Dart 3.14.0 on Windows.
- SimHei as the test text font, SHA-256 `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`; SDK MaterialIcons font, SHA-256 `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`.
- Same generated dependency lock, SHA-256 `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`; driver SHA-256 `40B618DC84BA6CB6E5B4BD538322514D41B06B0553257B045FED510B0F0B5425`.
- Before was captured before any production edits on the specified base. After was captured at the clean production/test commit above. The driver writes unedited Flutter renderer PNGs.

## Reproduce

Run `flutter pub get --offline` in `apps/client_flutter` on both revisions. Place the same capture driver under `evidence/` in each worktree, then use the same local fonts and absolute output paths:

```powershell
flutter test --no-pub --concurrency=1 evidence/chat_model_picker_capture_test.dart `
  '--dart-define=CAPTURE_PATH=<absolute PNG path>' `
  '--dart-define=CAPTURE_CJK_FONT=<absolute SimHei TTF path>' `
  '--dart-define=CAPTURE_ICON_FONT=<absolute SDK MaterialIcons OTF path>'
```

On the After revision also pass `--dart-define=CAPTURE_EXPECT_PICKER=true`. Add `--dart-define=CAPTURE_PICK_PATH=<absolute PNG path>` for the optional follow-on.

## Verification and limits

The focused Flutter run passed 57 tests: 18 production-route widget tests, 8 existing editor tests, 8 writer tests, and 23 diagnostics adapter tests. Scoped Flutter analysis found no issues. The local loopback retry test observed one binding PUT and no renewal on a 401 with the pinned writer; the existing default retry test still passes. Both capture invocations passed; PNG dimensions and hashes were checked programmatically. No full client suite was run for this slice.

These are production-widget renders with synthetic data, not native-device or live-provider acceptance. The catalog is not proof of model availability or `chat` compatibility, and there is no save-time connection test. An already dispatched write is not rolled back by session invalidation; the old editor suppresses its late result and cannot replay it. This is partial FR-57 / AC-10 evidence, not completion of either requirement.
