# Contacts friend request — matched application captures

This change adds an explicit outgoing friend-request action to the existing Contacts surface. A signed-in human enters the exact account ID supplied to them, reviews that ID and the consent consequence, then explicitly confirms. A host acknowledgement is displayed only after the write returns; it does **not** mean the recipient has accepted or that a chat exists.

## Captures

| State | Production source revision | Image | SHA-256 |
| --- | --- | --- | --- |
| Before: existing Contacts list; no outgoing-request input or confirmation | `6c0c0c43283b2124fa14dd93a11a01d3012c684f` | [Before PNG](contact-friend-request/before-6c0c0c4.png) | `472BEB2104E2DA641B96F603A57B88C46547EFC2198DC09CD7DB434EEC376D26` |
| After: same Contacts list and state; explicit account-ID form present | `bfa3ce9e50915deaaf4ec699465de61c7b883ec0` | [After PNG](contact-friend-request/after-bfa3ce9.png) | `EA4FB2B68093DB4FB088BD371576A062AAD42CF6688F8C26558F75987898DD96` |
| After follow-on: confirmation names the exact entered account ID and says the recipient must consent | `bfa3ce9e50915deaaf4ec699465de61c7b883ec0` | [Confirmation PNG](contact-friend-request/confirm-bfa3ce9.png) | `C7F16A1C347EE4A337E341E97C0141E99F504D7B91B3D415302E8ABE65D727C5` |
| After follow-on: host acknowledged one request; UI says recipient consent is still required | `bfa3ce9e50915deaaf4ec699465de61c7b883ec0` | [Acknowledged PNG](contact-friend-request/acknowledged-bfa3ce9.png) | `3F693DCD48547E9A5EF3466F17F28A0AECE4B50197B72062F858231DF55B2AE7` |

All captures use the same synthetic signed-in human `fixture-sender` and the same one-row Contacts fixture, `Fixture Friend` (`fixture-friend`, already friends). The primary comparison opens Contacts from the production `WhaleChatApp` shell with a fixture `ClientRuntime` session, before any input. It uses light theme, 390 × 844 logical pixels at DPR 1, Flutter 3.50.0 / Dart 3.14.0, and the exact same dependency lock SHA-256 `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`. CJK font SHA-256: `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`; Material Icons SHA-256: `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`.

The exact synthetic entered target is `Fixture_Target-02`. Opening Contacts, entering the ID, and opening the confirmation each assert zero host writes. The confirmation image is captured before confirmation and before any POST. The final image asserts exactly one bodyless `POST /api/v1/friends/Fixture_Target-02/requests`, a one-shot/no-renewal FriendsApi call, the in-place host acknowledgement, and unchanged Contacts list/read count. The baseline source itself is unchanged at `6c0c0c4`; the same untracked capture driver was used against Before and After.

## Capture and limits

Driver: [capture test](<contact_friend_request_capture_test.dart>), SHA-256 `0D08CEED648ED41DF5CE885AFA827F1ACC08487D38034C0C54336CCA7C6CF132` in both runs. From the client directory on Windows, run the command below for the Before image. For the After run, also pass `--dart-define=CAPTURE_CONFIRM=<absolute PNG path>` (selects the After assertions and captures the dialog) and `--dart-define=CAPTURE_SENT=<absolute PNG path>` (captures the acknowledged result). Both runs passed (one capture test per revision).

```powershell
flutter test --no-pub --reporter expanded evidence/contact_friend_request_capture_test.dart `
  '--dart-define=CAPTURE_PATH=<absolute PNG path>' `
  --dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf `
  --dart-define=CAPTURE_ICON_FONT=C:\Users\hu888\AppData\Local\Programs\Flutter\flutter\bin\cache\artifacts\material_fonts\materialicons-regular.otf
```

The PNGs are headless Flutter `RenderRepaintBoundary.toImage` captures, not native screenshots. The driver checked widget states, request path and count, and no framework exception. The PNGs were separately decoded and checked for dimensions, nonblank raster and SHA-256. Image input was unavailable to this worker, so manual visual review is outstanding.

The fixture connection returns in-process synthetic data. Neither a live host nor a Windows/Android device was exercised for this evidence. The [Contacts route tests](<../test/contact_friend_request_route_test.dart>) cover explicit review, exact-ID targeting, invalid/self IDs, cancel, repeated taps, rejection, stale confirmation, and discarded late results. The [HTTP loopback tests](<../test/friends_api_test.dart>) cover the existing request route's exact path and bodyless POST, no 401 renewal/replay or HTTP redirect, and malformed acknowledgement rejection.

This is the outgoing human-request slice of #131 R1 / FR-08 / AC-03, not full AC-03 acceptance. It does not add lookup, discovery, QR entry, AI initiation, blocking, relationship grants, automatic retry, direct-chat navigation, or host changes. Discarding a late response does not roll back an already dispatched request.
