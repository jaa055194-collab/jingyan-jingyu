# #131 E — Android playback of a sent voice message

This is the explicit, foreground playback slice of FR-19/FR-62. It reuses the authenticated message-scoped `GET /api/v1/conversations/{conversationId}/messages/{messageId}/voice-attachment` route merged in #159. It does not add recording, uploading, transcription, TTS, a download/cache, a service for playback, or Windows playback.

## Matched application captures

| Capture | Production revision | Observable state |
| --- | --- | --- |
| [Before](<before-85b7f5e.png>) | `85b7f5e1fcbc2deee6dca1715a8b69abfac1e8e6` | The authenticated fixture opens the same chat with one text row and one sent audio row. The audio row has no play action. |
| [After](<after-53790c6.png>) | `53790c6efb0b00287cc81d935115f1ed61aa6e1e` | The same audio row has a visible, enabled **播放语音** action. No action was taken in the captured frame. |

![Before: the audio row has no playback action](<before-85b7f5e.png>)
![After: the audio row has an explicit playback action](<after-53790c6.png>)

These are unedited renders of the production `WhaleChatApp` and `ClientRuntime`, in Flutter's Windows widget harness using Android Material platform and a synthetic Android method-channel capability response. Both use Flutter 3.50.0 / Dart 3.14.0, light theme, 390 × 844 logical pixels at DPR 1, default scroll position, font scale 1.0 and the same fonts. The real client syncs canonical fixture rows from a loopback HTTP host, then the driver opens the same conversation through the app's conversation list. The fixture marks those rows read before opening the chat to avoid an incidental read receipt affecting either frame. The driver checks the chat title, the synthetic voice text, the absence/presence and hit testing of the Play button, **zero voice attachment requests**, **zero native playback commands**, and no Flutter exception. Both runs passed (1 test each).

Full pixel decoding found both PNGs opaque and nonblank (106 distinct colors Before, 121 After). 10,230 of 329,160 pixels differ, all within `(16,225)–(150,336)`, the voice bubble region. There was no subjective image review: image input is not available in the agent runtime.

| Artifact | SHA-256 |
| --- | --- |
| [Before PNG](<before-85b7f5e.png>) | `E396993FEC05CE0531796D1EE6B52AB2536B1A4B231188143B48402A2110BDFA` |
| [After PNG](<after-53790c6.png>) | `24CD3973ABA403F660DF1E202C26E767346CB37174031F5AAE3030A770D7F6D7` |
| [Identical driver](<../voice_playback_capture_test.dart>) | `068F4783075B4CFB98800E46AE72C8FFFE6E5A25F1C107A9D21737B6C7206D14` |
| Dependency lock on both revisions | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |
| SimHei (`simhei.ttf`) | `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E` |
| Flutter `materialicons-regular.otf` | `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453` |

To reproduce, check out or extract the production files at the two listed revisions, copy the same [capture driver](<../voice_playback_capture_test.dart>) to the app's evidence directory in both, and from each `apps/client_flutter` run `flutter pub get --offline`. Use the same fonts and lock. Set `CAPTURE_EXPECT_PLAY=true` only for After.

```text
flutter test --no-pub --reporter expanded evidence/voice_playback_capture_test.dart --dart-define=CAPTURE_PATH=<absolute PNG path> --dart-define=CAPTURE_CJK_FONT=<SimHei TTF path> --dart-define=CAPTURE_ICON_FONT=<Flutter Material Icons OTF path>
```

## Verification and limits

- **RED:** The three new test files were written and run against the original client first. The run failed as expected because the baseline had no playback model, runtime methods, voice DTO, or bounded transport read. The first implementation run also exposed and corrected fixture issues (buffered HTTP chunks, Windows read-receipt cleanup timing, and a UI fixture that overwrote its messages on selection).
- **GREEN:** On the After production revision, 90 tests passed, zero failed. The targeted run included 33 new tests for the voice API, runtime, and chat UI and 57 existing adjacent tests for network, runtime auth/lock/image/unread, image UI and mention UI. The real-app navigation regression holds a loopback voice response after tapping Play, opens Settings, waits for the read to cancel, then releases the response and verifies no native command. Other tests cover HTTP refusal/error/malformed responses, response bounds before decoding, cancel on lock/logout/switch/dispose/background, a superseded native start acknowledgment or completion, and loss of message eligibility after a history-floor update.
- **Analysis/build:** `flutter analyze --no-pub` reported `No issues found!`. `flutter build apk --debug --no-pub` built the debug APK on the short Windows worktree alias. The APK was 185,064,556 bytes, SHA-256 `9B20369F7E2EB6698938397DFC9C56C3A2D1A26BC5EDB9DD05C6DA5FBCD3181C`. No full client suite was run concurrently with the other integration lanes.
- The Android build compiles the native `MediaPlayer`/in-memory `MediaDataSource`, focus handling, and lifecycle guards. The tests substitute the channel handler and establish **command ordering, not sound output**. No device or emulator was launched or installed, and neither Android audio output, actual native prepare/stop/completion timing, nor live-host acceptance was run. Nothing here certifies AAC-LC, sampling rate, channel count or every valid M4A container at playback time, and this does not complete FR-19/FR-62 or any device acceptance gate.

```text
flutter test --no-pub --reporter expanded --concurrency=1 test/voice_message_api_test.dart test/runtime_voice_playback_test.dart test/voice_message_playback_test.dart test/network_test.dart test/runtime_app_lifecycle_lock_test.dart test/runtime_auth_test.dart test/runtime_image_preview_test.dart test/message_image_preview_ui_test.dart test/runtime_unread_test.dart test/mention_message_ui_test.dart
flutter analyze --no-pub
flutter build apk --debug --no-pub
```
