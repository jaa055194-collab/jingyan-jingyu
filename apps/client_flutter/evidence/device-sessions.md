# Device sessions — application comparison

| Capture | Production revision | Result |
| --- | --- | --- |
| [Before](device-sessions-before-e7fdf7d.png) | `e7fdf7d968ca5b358529dffc4321205acf02aff2` | The settings developer group has no device-session entry: the read-only list runs module test → world status → attachments list → attachment metadata, with no tile between world status and attachment metadata. |
| [After](device-sessions-after-entry.png) | this PR's head (see the PR description) | The same viewport and scroll position now shows the **设备会话** tile in that exact slot. Nothing else in the frame moved. |
| [After — opened list](device-sessions-after-list.png) | same as After | Follow-on state, **not** part of the before/after pair: the real `DeviceSessionsScreen` after one tap, listing both fixture devices with names and last-used timestamps and one open confirmation panel. |

Both Before/After frames are unedited renders of the production
`WhaleChatApp` + `ClientRuntime` through a headless Flutter widget render
(`evidence/device_sessions_capture_test.dart`), Windows Flutter 3.50.0 /
Dart 3.14.0, 1280 × 960 logical pixels, device pixel ratio 1, light theme,
font scale 1.0, identical fonts (SimHei for CJK, Material Icons) and the
**identical dependency lock** (`pubspec.lock` SHA-256
`C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` in both
worktrees).

## Identical scenario and UI state

The driver scrolls the settings list so the pre-existing
`open-attachment-viewer` tile sits at y = 300 in both frames, then asserts that
position (`closeTo(300, 1)`) before capturing. The new tile is inserted directly
above that anchor, so the Before/After pair differs only in the newly added
region.

Verified pixel diff (every 2nd pixel, both directions): 2051 differing samples,
bounding box `(98,112)–(1018,284)` — the settings content column, exactly the
band where the new tile is inserted. No other region changed, which is the
evidence that the pair is the same scenario, viewport, theme and UI state.

## Fixture and assertions

The driver's `_FixtureConnection` answers `GET /api/v1/auth/devices` with two
synthetic rows (`device-laptop` / 工作室笔记本 / `2026-11-18T02:03:04.000Z` and
`device-phone` / 随身手机 / `2026-11-17T10:00:00.000Z`) and asserts the method,
path, null body and null query. It also asserts:

- zero device reads before the entry is opened;
- the Before revision has no `open-device-sessions` tile, the After revision has
  exactly one and it is fully inside the 960-pixel viewport;
- the opened list performs exactly one read, renders both rows, and opens the
  confirmation panel for the phone row.

The fixture reports **no** `current` flag, which is what the real host does
today. That is why the follow-on capture shows the stronger gate (type the
device name) rather than a plain confirm — an honest reflection of the host
contract, not a mock of a richer one.

## Hashes

| Artefact | SHA-256 |
| --- | --- |
| `device-sessions-before-e7fdf7d.png` | `BA5BDF86E2B6312CEE438199088BAFC3179049023AA43E4D84D345F78832C2C4` |
| `device-sessions-after-entry.png` | `47E2BCE302DE093F1C4F1C167DBC6F46A500F3A1A40E8AE03E2B505A1074F055` |
| `device-sessions-after-list.png` | `7DFD764D5B9D7FA76293E65BF9FCCDED6937BA92965E9A890D5FF4B7B4BEF48C` |
| `device_sessions_capture_test.dart` (both worktrees) | `FEEF7233FB8548930BC6EB1842107F9BEB0788BDBB0CA1CC0BC011263299C02C` |
| `lib/net/device_sessions_api.dart` | `3B178D6B1F41F646C69C831BBC1D561D3C5713860A18CF235D99BEBD5BABB67A` |
| `lib/features/settings/device_sessions_screen.dart` | `9DFEB25B60EA2C7235F3046627A98F62CB5F98C22875961A5B13849CB59F1D6E` |
| `lib/features/settings/settings_screen.dart` | `EFAA07595C6AE2B7FE3A090338C9030F281E517F7F1BA32D3E53B0121CE91CA7` |
| `pubspec.lock` (both worktrees) | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` |

All three PNGs decode at exactly 1280 × 960, 32-bit ARGB, and contain
non-uniform content (22/23/27 distinct colours in a sparse sample), i.e. they
are real renders rather than blank frames.

## How to reproduce

```
# After (this branch)
cd apps/client_flutter
flutter test --no-pub evidence/device_sessions_capture_test.dart \
  --dart-define=CAPTURE_PATH=<abs png> \
  --dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf \
  --dart-define=CAPTURE_ICON_FONT=...\materialicons-regular.otf
# add --dart-define=CAPTURE_STAGE=list for the follow-on frame

# Before (detached worktree at e7fdf7d, same driver copied in)
git worktree add --detach <dest> e7fdf7d
# then the same command with the default CAPTURE_STAGE=settings
```

## Limits (explicit, not overclaiming)

- These are **widget-harness renders with a fixture connection**. No Windows or
  Android device, no live host, no real native window capture.
- **No real revocation was exercised.** The fixture never answers the revoke
  route, so the captures show the list and the confirmation gate only. Host-side
  revoke semantics are covered by existing host tests, not by this evidence.
- The device list is synthetic; the "current device" state is not shown because
  the host's `GET /auth/devices` response has no current-device field. The
  stronger gate shown here is the client's honest fallback for that gap.
- No Android device was signed off, no accessibility/contrast review was done,
  and no human visual approval was obtained (the agent session had no image
  input; validation was programmatic: dimensions, colour variance, hashes and
  the pixel-diff bounding box above).
- This is a client surface over existing host routes. It changes no host
  behaviour, adds no session policy, no re-authentication prompt and no device
  acceptance, and it does not complete AC-02 or AC-32.
