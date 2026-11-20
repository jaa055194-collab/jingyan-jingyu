# Device sessions: matched application captures

| Capture | Production code revision | Result |
| --- | --- | --- |
| [Before](device-sessions-before-a4de467.png) | `a4de467b861fc260eb02b1eefd8bd053136ba0ef` | Settings opens at the top. Privacy & Security has no device-session entry. |
| [After](device-sessions-after-entry.png) | `1f0b54d63eddd7cdef4795be17f22335d6ce83e3` | The same Settings view now shows the device-session entry in Privacy & Security, above General. |
| [Opened list](device-sessions-after-list.png) | `1f0b54d63eddd7cdef4795be17f22335d6ce83e3` | Follow-on state, not part of the matched pair: two synthetic signed-in devices and the confirmation for the phone. |

Both frames are unedited renders of the production `WhaleChatApp` and `ClientRuntime` in the Flutter widget harness. The driver opens Settings through the gear icon and asserts scroll offset 0, light theme, 1280 × 960 logical pixels at DPR 1, font scale 1.0, and the presence of the Privacy & Security and General headings. It asserts zero device requests before entering the page. Afterward it verifies that the complete new tile is visible between those headings. The content below the added row moves down.

The renders used Flutter 3.50.0 / Dart 3.14.0 on Windows, the same SimHei and Flutter Material Icons files, the same capture driver, and the same dependency lock. All three PNGs decoded at 1280 × 960. Sampling every fourth pixel in both dimensions found 3,936 different samples in the Before/After pair, beginning below the unchanged top part of Settings (sample bounds `(100,384)` to `(1260,928)`). The two After states were also rendered on the committed code revision and matched the recorded PNGs byte for byte.

| Artifact | SHA-256 |
| --- | --- |
| Before | `E69592034B0F468D08BAC7380D79D2C55646E67F1CA3EFB241D8C8740F7472AF` |
| After | `72DA02996834745B95EEB28E3EFA4767EF8786063886061C190F629BE3CB6E8E` |
| Opened list | `7DFD764D5B9D7FA76293E65BF9FCCDED6937BA92965E9A890D5FF4B7B4BEF48C` |
| Capture driver | `2BA06E7A245B9CA0FB8A3D2C3A4EB32F2258607803BF62811C4EF6FEA875332D` |
| Dependency lock in both worktrees | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |

## Reproduce

Create detached worktrees at the two revisions above, put the same [driver](device_sessions_capture_test.dart) in each app's `evidence` directory, and run `flutter pub get --offline` from `apps/client_flutter`. Use the same viewport and font files:

```text
flutter test --no-pub evidence/device_sessions_capture_test.dart --dart-define=CAPTURE_PATH=<absolute PNG path> --dart-define=CAPTURE_CJK_FONT=<SimHei TTF path> --dart-define=CAPTURE_ICON_FONT=<Flutter MaterialIcons-Regular.otf path>
```

Leave `CAPTURE_EXPECT_ENTRY` unset on the Before revision; add `--dart-define=CAPTURE_EXPECT_ENTRY=true` on the After revision. Add `--dart-define=CAPTURE_STAGE=list` to render the separate opened state. It asserts one device read, both fixture rows, and the confirmation panel without submitting it.

## Limits

These are widget-harness renders with a fixture connection, not live-host, accessibility, visual sign-off, or Windows/Android device acceptance. The fixture lists two synthetic devices but does not revoke either. The real host does not report which entry is current; this is why the screen asks for the device name for every sign-off when current-device status is unknown. The real-host revocation and cross-device acceptance remain unverified in this slice. No production host behavior or session policy changed.
