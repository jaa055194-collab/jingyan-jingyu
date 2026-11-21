# Windows client: foreground in-app message cue

A short, non-modal **“收到新消息，可在聊天中查看。”** appears on the Windows client's authenticated, unlocked foreground Contacts or Inbox main page. Unlike the conversation-row unread badge (which is not visible on those pages), the cue calls attention to a new arrival without revealing a conversation, sender, count, or body. It does not navigate, take focus, mark messages read, or write to the host. Close is labeled for assistive technology; the quiet Material row is a live region and expires after eight seconds. There is at most one row, not a queue or notification history.

## Matched Flutter renders

| Frame | Production revision | Render |
|---|---|---|
| Before: contact list after inbound sync, no cue | `1a04fad5a8745432587716772e95898f00f0c6e0` (tree `832fe6a69426b5d9fb98ab29733d9496403bcdd5`) | [Before PNG](<foreground-message-notice-before.png>) |
| After: same contact list and inbound sync, generic cue | `0426003b598711f88c67875e86b5bea426bcf926` (tree `bdfafbc25be1e8d3bb8322ea51e54a876478ece1`) | [After PNG](<foreground-message-notice-after.png>) |

Both PNGs are unedited **1280 × 720 logical/physical pixels, DPR 1**, theme light, font scale 1. The [driver](<foreground_message_notice_capture_test.dart>) renders the real `WhaleChatApp` and `ClientRuntime` through Flutter, with the same isolated synthetic authenticated HTTP fixture and native storage stub. Both frames use the already loaded Contacts main page after one new incoming text row is accepted at sequence 1. Both assert unread 1, no selected conversation, no peer content rendered, and no write or ACK. Only After contains the cue. Pixel decode found 86,642 changed pixels; the added inline row shifts the existing Contacts content down. Lead independently checked the Chinese OCR for both frames. This is a real Flutter render, **not** a native Windows window capture, real credentials, real host data, or operating-system notification evidence.

| Asset | SHA-256 |
|---|---|
| Before | `D301EA09116F694F09F5FED65E51751E3540BDF52284FB5D502BFF883DFEFC5F` |
| After | `480047242C4C522E5B04CEBD36210DA6D74A4670F077C7A219F9355A735D1D96` |
| Dependency lock | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |
| CJK / MaterialIcons fonts | `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E` / `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453` |

To reproduce: copy the driver and its [fixture](<../test/support/foreground_notice_fixture.dart>) to the baseline if needed; use Flutter 3.50.0 (`ab2912035e`), Dart 3.14.0 and local offline dependencies. From the Flutter app directory run:

```powershell
$flutterRoot = Split-Path (Split-Path (Get-Command flutter).Source)
$icons = Join-Path $flutterRoot 'bin\cache\artifacts\material_fonts\materialicons-regular.otf'
flutter test --no-pub --reporter=expanded evidence/foreground_message_notice_capture_test.dart `
  '--dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf' `
  "--dart-define=CAPTURE_ICON_FONT=$icons" `
  '--dart-define=CAPTURE_PATH=evidence/foreground-message-notice-before.png'
```

On the changed revision use `--dart-define=CAPTURE_AFTER=true` and the After output path. Both capture commands passed 1/1.

## Trigger and verification boundaries

- Existing authenticated HTTP history refresh, nominal 15-second polling while the client is running and eligible. Only a fully successful batch can show a cue, and only if it contains an already-visible conversation's newly applied peer text or supported attachment with an unchanged history floor. First sync, first successful refresh after a detected failure or after returning to foreground, and changed visibility floors seed a baseline without showing a cue. Own, recalled, invalid/unsupported, already applied, out-of-scope, and stale results are silent. An outage that goes unobserved between two successful polls cannot be distinguished from an ordinary interval by this HTTP client.
- Same eligible main route and session must be current at both ends of the sync. Changing the main view, covering it with a route/dialog, losing foreground, locking, or signing out invalidates the cue. No setting was added, no existing notification/PIN/default behavior or native files changed, and Android does not instantiate the activity source.
- The positive regression went RED on the base (accepted rows/unread, but no cue). `flutter test --no-pub --reporter=expanded test/foreground_message_notice_test.dart test/runtime_unread_test.dart test/runtime_app_lifecycle_lock_test.dart test/shell_inbox_invite_actions_test.dart` then passed **29/29**, including 12 focused cue cases, and `flutter analyze --no-pub` reported no issues.
- Task-8 OS delivery remains outside this increment: unique synthetic WinRT probe registration failed at Windows `FOLDERID_Programs` with `ERROR_ACCESS_DENIED (5)` before its shortcut, any toast, or a capture. No release artifact, existing credential, settings change, device, or user operation was used. This cue does not satisfy Windows/Android system notification, background delivery, click routing, or lock-screen notification claims.
