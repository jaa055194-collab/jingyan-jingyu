# Unread counts and local read position — application comparison

| Capture | Production revision | Result for the same synthetic account and cached messages |
| --- | --- | --- |
| [Before](unread-read-position-before.png) | `e7fdf7d968ca5b358529dffc4321205acf02aff2` | Three conversations with 4, 2 and 0 cached canonical messages. Every row renders without a badge; the list has no notion of unread. |
| [After](unread-read-position-after.png) | see the PR head SHA | The same three conversations render **4**, **2** and no badge. The counts come from the production unread projection over the cached canonical messages. |
| [After — opened](unread-read-position-after-opened.png) | see the PR head SHA | The same viewport/theme after one explicit open of 项目小组: that badge is gone and 家人 still shows **2**. |

Both revisions rendered the production `WhaleChatApp` with the real `ClientRuntime`, on the chat tab, at 1280 × 960, DPR 1, light theme. The dependency lock SHA-256 matched in both worktrees: `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`. The same Windows SimHei CJK font and Flutter MaterialIcons font were injected in both runs, and the [capture driver](unread_read_position_capture_test.dart) is byte-identical in both worktrees (SHA-256 `985BEB3A2EC356B2129711DED8434B4AD9EC624BBFC40174EB148BA0D1819B0F`). The Before image is an unedited render of baseline `e7fdf7d` produced in a separate `git worktree` at that revision, not a mockup or an edited screenshot.

The fixture is a loopback host serving three synthetic conversations and their canonical messages to the real runtime. No real host, saved session, private account data or credentials were used, and the rendered rows contain no message text beyond the synthetic fixture.

The driver asserts the initial state (`quiet:0,family:2,team-project:4`), then on the After revision taps 项目小组, waits for the production read position to be checkpointed, and asserts that only that conversation cleared (`team-project:0`, `family:2`). It also asserts exactly one `POST /api/v1/conversations/team-project/ack` with `{"seq": 4}`, so the After image is accompanied by the actual host report rather than only a UI state. On the baseline revision the driver detects that the read-position API does not exist and captures the Before image without the opened-state half, which is why one identical driver works on both revisions.

Image integrity: all three PNGs are 1280 × 960 with valid PNG signatures and were written by `RenderRepaintBoundary.toImage` with the dimensions checked inside the driver and no framework exception at capture time.

- Before `786243413592ACBF922573791693DDEF65956D162A25755D0CCD566511368B61`
- After `C7309F1F8F58B3A3C6C11C471267C45D7393DEE3CA7513AEC703AE1B122FD86E`
- After opened `4EEE66BD65BEE2747F970B1E760EF39C31E113C01B52B3C3562C3716D3626FBF`

To reproduce, run `flutter pub get --offline` from the client app in both worktrees, copy the driver into each app's `evidence/` directory, and run `flutter test --no-pub evidence/unread_read_position_capture_test.dart` with `--dart-define=CAPTURE_PATH=<absolute PNG path>`, `--dart-define=CAPTURE_CJK_FONT=<SimHei TTF path>` and `--dart-define=CAPTURE_ICON_FONT=<Flutter MaterialIcons-Regular.otf path>`. On the After worktree also supply `--dart-define=CAPTURE_OPENED=<absolute second PNG path>`. The driver lives outside the default `test/` directory so ordinary test runs neither need these fonts nor emit screenshots.

## Honest limits

This is a widget-harness render. It is **not** device, native-window, or live-host acceptance: no Windows or Android install was exercised, no real host was contacted, and no human visually reviewed the result on a device. Subjective visual approval was unavailable on the text-only model that produced this slice.

The comparison shows the list badge and its clearing. It does not demonstrate cross-device read receipts, WebSocket delivery, push notifications, server-computed unread, or unread surviving an account switch beyond what the unit and runtime tests cover.
