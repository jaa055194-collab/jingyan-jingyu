# Inbox manual refresh — matched Flutter rendering

| State | Production code revision | PNG / SHA-256 |
| --- | --- | --- |
| Before: temporary read failure, no retry action | `32ac64f54358bf8e7837a566ea225bf966322c38` | [Before](inbox-refresh-before-32ac64f.png) · `69AF3550DB9D3B6FEA97150FD67B23099F472E82577BEC6E7950C1F760982CB7` |
| After: the same temporary read failure, with manual retry | `2e917e6dfd4af6f74dff2201dc67817ae1a227d6` | [After](inbox-refresh-after-2e917e6.png) · `FB3BECA49360BB28C0C5404CBA4F5FCBFFA43A7676EE3B64EAE49545E7CA1131` |
| After: invitation metadata after one explicit retry | `2e917e6dfd4af6f74dff2201dc67817ae1a227d6` | [Recovered](inbox-refresh-recovered-2e917e6.png) · `E44723FA580E63B7AA7F11480E89B0B57098B88268AEB829AE650EE648F24CFF` |

Both worktrees rendered the production `WhaleChatApp` on its Inbox tab, at 1280×960, DPR 1 and light theme. The dependency lock SHA-256 matched: `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC`. The same Windows CJK and Flutter Material icon fonts were injected in both renderer runs. The fixture uses an isolated synthetic recipient and a test connection that requires the expected GET route with a null body. It returns a temporary failure on the first read and one synthetic invitation on the second. No real host, saved session, private account data or credentials were used.

The [capture driver](inbox_manual_refresh_capture_test.dart) asserts the same initial failure and exactly one read before both captures. On the After revision it taps retry, asserts exactly two reads, and verifies the invitation is shown and the failure is gone. The PNGs are unedited output from Flutter's `RenderRepaintBoundary.toImage`, with dimensions checked in the driver and no framework exception at capture time. These are production-widget renderer comparisons, not native Windows/mobile or real-host acceptance.

To reproduce, run `flutter pub get --offline` from the client app in both worktrees, copy the same driver into each app's `evidence/` directory, and run `flutter test --no-pub evidence/inbox_manual_refresh_capture_test.dart` with `--dart-define=CAPTURE_PATH=<absolute PNG path>`, `--dart-define=CAPTURE_CJK_FONT=<SimHei TTF path>` and `--dart-define=CAPTURE_ICON_FONT=<Flutter MaterialIcons-Regular.otf path>`. On the After worktree also supply `--dart-define=CAPTURE_RECOVERY=<absolute recovered PNG path>`. The driver is outside the default `test/` directory so usual test runs do not require these files or emit screenshots.
