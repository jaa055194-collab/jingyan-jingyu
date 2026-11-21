# Persona-card import — matched real-app captures

This evidence covers the first-phase persona-card import in the existing AI run-configuration editor. Import has two local entries — **导入人格文件** and **粘贴人格 JSON** — and only fills the existing P0/P1/P2 text fields. It never initializes or saves; the existing **初始化人格** / **保存人格修改** buttons remain the only write actions.

## Captures

| Capture | Revision | Observable state |
| --- | --- | --- |
| [Before](<before-379231f.png>) | `379231f3b9153781a476298243bca637c2e0cfd1` (tree `92f8239c7054629d62ae60215190fab161f543f3`) | The production Settings → AI 运行配置 route, scrolled to the persona card. No import controls exist. |
| [After — entry](<after-entry-21f2a34.png>) | `21f2a342ac8f7db03c3f9336fee7a56cbb15f949` | The same route and scroll anchor now shows both import controls above the unchanged P0/P1/P2 fields. No import has occurred and no host write was sent. |
| [After — imported](<after-imported-21f2a34.png>) | `21f2a342ac8f7db03c3f9336fee7a56cbb15f949` | Follow-on state, same anchor: the documented synthetic sample was pasted and validated; its three layers fill the form and a summary shows the source and `P0 2 项 · P1 1 项 · P2 2 项`, stating “仅填充表单”. |

![Before: no import entry in the persona card](<before-379231f.png>)

![After entry: file and paste import controls above the unchanged form](<after-entry-21f2a34.png>)

![After imported: synthetic sample fills P0/P1/P2 with a source summary](<after-imported-21f2a34.png>)

The Before revision is the assigned base. The lead identified it as the main-equivalent of remote main `63463852`; that remote commit is not present in this worktree, so the capture is tied to the local base SHA and its verified tree. All frames are unedited renders of the production `WhaleChatApp` + `ClientRuntime` + Settings/`AiConfigEditor` route in Flutter's Windows widget harness, with only the fixture transport injected. Both revisions used Flutter 3.50.0 / Dart 3.14.0, light theme, 390 × 844 logical pixels at DPR 1, text scale 1, the same fonts, dependency lock and driver, and the same Settings → editor → persona-anchor navigation.

The driver answers only the existing profile-resolve POST (`/api/v1/ai-profiles/register`); any persona write would throw and fail the run. It asserts the controls are absent Before and present After, that the initial After frame has no summary, that import leaves the writer untouched, that the pasted sample fills exactly `name=示例角色`/`role=示例用途`, `style=示例表达风格`, `mood=示例情绪`, and that the summary is shown. All three runs passed (1 test each). Pixel decoding found both captures opaque and nonblank; the Before/After-entry pair differs across `(19,160)–(370,839)` because the new controls shift the form rows below, and the entry/imported follow-on differs across `(19,263)–(370,843)`.

| Artifact | SHA-256 |
| --- | --- |
| [Before PNG](<before-379231f.png>) | `B957AA8BF0443C3939F591409284B3A78949D9BF5EE7DD4BAED676CE3A85C080` |
| [After entry PNG](<after-entry-21f2a34.png>) | `D1FFC156D567C5D70523DF2FF9F8B9863E20574CE4EFF2C98A007FB7C5EA4025` |
| [After imported PNG](<after-imported-21f2a34.png>) | `830C35E2B1EFC35FBE80FEEAACC5F097B4C849F2ADA46332835CAEFB9C9700E9` |
| [Capture driver](<../persona_import_capture_test.dart>) | `4C1FE18C058D7FBDFED1281FEB4FD147163BDA13A7E2032C88AA10D5ABA23A44` |
| [Synthetic sample](<../../../docs/examples/persona-sample.json>) | `49C54C0F053AA3BAA6799B725A457D6AA7A5A9175EFEF57543005D34F1F26D11` |
| Client dependency lock (both revisions) | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |
| SimHei TTF | `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E` |
| Flutter Material Icons OTF | `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453` |

## Verification

- **RED:** Both new suites initially failed to load because the parser, picker and editor injection did not exist (`persona_card_import.dart`, `persona_file_picker.dart`, `personaFilePicker`). The first GREEN attempt then surfaced fixture/edge defects — factory self-reference, BOM stripping by `dart:utf8`, a test map type, and an unreachable form-representability case — which were corrected test-first.
- **GREEN:** `flutter test --no-pub --concurrency=1 test/persona_card_import_test.dart test/persona_import_ui_test.dart` passed **21/21** at `21f2a34`. Adjacent existing suites `ai_config_editor_test.dart`, `settings_persona_history_route_test.dart`, `settings_chat_model_picker_test.dart` passed **40/40**. Scoped `dart analyze --fatal-infos` on the changed production/test/evidence files reported no issues.

```text
# apps/client_flutter (offline dependencies already resolved)
flutter pub get --offline
flutter test --no-pub --reporter expanded --concurrency=1 test/persona_card_import_test.dart test/persona_import_ui_test.dart
flutter test --no-pub --reporter expanded --concurrency=1 test/ai_config_editor_test.dart test/settings_persona_history_route_test.dart test/settings_chat_model_picker_test.dart
dart analyze --fatal-infos lib/features/ai_config/persona_card_import.dart lib/features/ai_config/persona_file_picker.dart lib/features/ai_config/ai_config_editor.dart test/persona_card_import_test.dart test/persona_import_ui_test.dart evidence/persona_import_capture_test.dart

# capture, per revision
flutter test --no-pub --reporter expanded evidence/persona_import_capture_test.dart --dart-define=CAPTURE_STAGE=entry --dart-define=CAPTURE_SAMPLE=<sample path> --dart-define=CAPTURE_PATH=<PNG path> --dart-define=CAPTURE_CJK_FONT=<SimHei TTF> --dart-define=CAPTURE_ICON_FONT=<Material Icons OTF>
# After entry adds --dart-define=CAPTURE_EXPECT_IMPORT=true; imported state uses --dart-define=CAPTURE_STAGE=imported
```

## Limits

These are desktop widget-harness renders with a fixture transport, not a live host, live model, Windows native UI or Android device acceptance. The Windows/Android picker dialogs were not opened; the file path is covered by widget/unit tests with an injected platform fake and real temporary files (cancel, oversize, invalid, temp deletion, user file preserved). Imported content was synthetic only. No full client suite was run here; the lead owns combined checks and publication. Image viewing was unavailable in the agent runtime, so visual judgment rests on the widget assertions and full-pixel comparison above, not a human review.