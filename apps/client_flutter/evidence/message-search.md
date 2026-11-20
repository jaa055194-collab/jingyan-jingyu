# Global message search — reachable client surface (Before / After)

## Scenario

One synthetic account opens the real Settings screen of the production `WhaleChatApp` + `ClientRuntime` and scrolls to the developer/read-only group. **Before** there is no way to reach the already-merged host search route. **After** a single read-only entry `消息搜索` exists there and opens a search screen that queries `GET /api/v1/search?type=message` only when the user explicitly submits a query.

Same scenario, viewport, DPR, theme, fonts, fixture and driver in both renders. The only intended difference is the added entry.

| Property | Value |
| --- | --- |
| Viewport | 1280 × 960 logical pixels |
| Device pixel ratio | 1 (PNG is 1280 × 960 physical) |
| Theme | Light (`ThemeMode.light` forced by the fixture runtime) |
| Fonts | `simhei.ttf` injected as `Ahem`, Flutter `MaterialIcons-Regular.otf` as `MaterialIcons` |
| Render path | Flutter widget harness, `RenderRepaintBoundary.toImage` → PNG, unedited |
| Fixture connection | synthetic `HostConnection` subclass; no real host, session, account or message content |
| Dependency lock SHA-256 | `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937` (identical in both worktrees) |
| Capture driver SHA-256 | `ADF40315BF2D5885BB9D4219420D283E0C9546FEB88F020C97042B44212955C2` (identical in both worktrees) |

## Before / After pair

| State | Production revision | Image | PNG SHA-256 | Driver metrics |
| --- | --- | --- | --- | --- |
| Before: Settings has no search entry | `e7fdf7d968ca5b358529dffc4321205acf02aff2` (detached worktree) | [message-search-before-e7fdf7d.png](message-search-before-e7fdf7d.png) | `1B3366B4F80A1EE5EBB8E2252895C8C6900CA8B7A23FD25CFD86F584F44537E1` | `searchEntry=0 searches=0` |
| After: one `消息搜索` entry in the read-only group | `{{AFTER_SHA}}` | [message-search-after-settings.png](message-search-after-settings.png) | `AE1EAD27D853FD8F1DE06347D8FDABEB224D7D9DCFD3C8833A13470ECA5F52B3` | `searchEntry=1 searches=0` |

`searchEntry` is the number of `open-message-search` widgets the driver finds after scrolling to the same anchor; `searches` is the number of `GET /api/v1/search` calls the fixture observed. The Before render therefore proves the entry is genuinely absent at `e7fdf7d`, not merely cropped out. In both runs `searches=0`, i.e. opening Settings and scrolling issues no search request.

## Follow-on state (not part of the before/after pair)

| State | Revision | Image | PNG SHA-256 |
| --- | --- | --- | --- |
| Search screen after one explicit submit, synthetic hits | `{{AFTER_SHA}}` | [message-search-after-results.png](message-search-after-results.png) | `C87B0871488800668A92AAA38DBC461576DCC2A556BC2FF5666270B06A8B06C1` |

This is a **follow-on** capture of a later UI state on the After revision, not a second before/after pair. The driver asserts: opening the search screen issues zero requests and shows the idle state; exactly one submit produces exactly one `GET`; two synthetic hits render with their conversation, sender, kind, seq, snippet and host-reported `mode`. The hits are synthetic fixture rows shaped exactly like the merged host route; they are **not** a real host's search results.

## Reproduce

1. Create a detached worktree at the baseline revision and one at the After revision.
2. Copy this driver into `apps/client_flutter/evidence/message_search_capture_test.dart` in each.
3. In both, `flutter pub get --offline` and confirm `pubspec.lock` SHA-256 matches the value above.
4. Run from `apps/client_flutter`:

```
flutter test --no-pub evidence/message_search_capture_test.dart \
  --dart-define=CAPTURE_PATH=<absolute png> \
  --dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf \
  --dart-define=CAPTURE_ICON_FONT=<flutter>/bin/cache/artifacts/material_fonts/materialicons-regular.otf
```

On the After worktree additionally pass `--dart-define=CAPTURE_FOLLOW_ON=<absolute png>`. The driver lives outside `test/`, so ordinary `flutter test` runs neither need the font paths nor emit screenshots.

## Limits (do not overclaim)

- **Harness render, not acceptance.** These are Flutter widget-harness renders with a fixture connection. They are not device, native Windows/Android, or live-host acceptance, and no real account, conversation, message text or credential is present.
- **Host capability, not a client index.** The search is the already-merged host `GET /search?type=message`: a bounded per-conversation decrypt-and-compare scan plus optional encrypted blind-index candidates (REQ-032 / REQ-034 / REQ-036). The client adds **no** full-text index, no local re-matching, no ranking, no scoring, no relevance ordering and no coverage guarantee. The screen says so in its own copy and reports the host's `mode` (`blind`/`scan`) per hit.
- **Message hits only.** `type=favorite` and `type=file` are different host surfaces with a different row shape; this adapter rejects them instead of half-parsing. Favourites, files, links and dynamics search remain unimplemented on the client.
- **No result navigation.** Tapping a hit opens nothing; there is no jump-to-message, no conversation open and no re-fetch. Result navigation is deliberately out of scope.
- **Bounded, non-exhaustive results.** The host caps `limit` at 100 and pages at most 20 × 200 messages per conversation, so an empty result is not proof of absence. The screen states this.
- **Image review.** `read_image` is unavailable in this worker session (`model "group/group" does not declare image input`); PNG dimensions, format and hashes were verified programmatically, and the driver asserted the rendered state. Human visual review of the images is still required.
- **Not AC-20 completion.** This makes the existing host search reachable; it does not complete AC-20 or FR-17, which also cover favourites/files/dynamics search and result navigation.
