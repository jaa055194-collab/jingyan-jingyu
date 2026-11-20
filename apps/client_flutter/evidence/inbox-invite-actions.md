# Inbox friend-request actions — application comparison

A pending friend invitation in the Inbox can now be accepted or denied on the
row itself, instead of forcing the user to go find the same request on the
Contacts tab. The images below are unedited renders of the production
`WhaleChatApp` widget tree (with the real `ClientRuntime` subclass and a fixture
`HostConnection`), captured through `RenderRepaintBoundary.toImage` in an
isolated test worktree.

## Scenario

Both revisions render the **same synthetic pending invitation**: one
`friendRequest` notification from `fixture-alice`, `status: pending`, title
`好友邀请`, `createdAt 2026-11-18T00:00:00.000Z`, served by the fixture
connection for `GET /api/v1/notifications?limit=50`. The synthetic authenticated
recipient is `fixture-recipient`, light theme, font scale 1.0, **1280 × 960**
logical pixels at **DPR 1**, same Windows CJK (`simhei.ttf`) and Material Icons
fonts on both sides. The inbox tab is selected in both. No live account, saved
session, real invitation or private message is involved.

| Capture | Production revision | What the same row shows |
| --- | --- | --- |
| [Before](inbox-invite-actions-before-e7fdf7d.png) | `e7fdf7d968ca5b358529dffc4321205acf02aff2` | The row is metadata only: `好友邀请`, `来自 fixture-alice · …`, status `pending`. There is no way to act on it, and the page footer claims it never mutates relationships. |
| [After (row)](inbox-invite-actions-after-row.png) | `deeaafc` (this branch, first commit) | The same row now offers explicit **接受** and **拒绝**; the footer states the narrowed write scope. |
| [After (confirmation)](inbox-invite-actions-after-dialog.png) | `deeaafc` | Tapping **接受** opens the required confirmation. Captured **before** any host write. This is a follow-on After image of the dialog state, not the Before/After comparison itself. |
| [After (accepted)](inbox-invite-actions-after-accepted.png) | `deeaafc` | After confirming, the row shows the host-confirmed `已接受` and no longer offers actions. |

PNG SHA-256:

- Before: `E44723FA580E63B7AA7F11480E89B0B57098B88268AEB829AE650EE648F24CFF`
- After (row): `98CB2CE6C1E1E78716B591960D08923D1B6C18BA3AB8544791D005AC48FB542A`
- After (confirmation): `C123C105F9D9C7BAC74E2A02C8CAC1D244510DE339A91453BCCED0418416DF52`
- After (accepted): `442B177C4822DA1884C0C74DE8769D207D57EFEAD99AAA1D286B233186E50164`

All four are 1280 × 960 PNGs; each passed a full pixel decode plus a
non-blank/dimension check. Before and After (row) differ in 4248 of 1228800
pixels, so the After render is a genuinely different frame rather than a copy of
the baseline.

## How it was captured

Driver: [`inbox_invite_actions_capture_test.dart`](inbox_invite_actions_capture_test.dart).
The same file was copied into a detached `git worktree` at `e7fdf7d` for the
Before image and run from this branch for the After images, so both sides render
the same production widgets with the same driver.

```
flutter test --no-pub evidence/inbox_invite_actions_capture_test.dart \
  --dart-define=CAPTURE_PATH=<abs png> \
  --dart-define=CAPTURE_CJK_FONT=C:\Windows\Fonts\simhei.ttf \
  --dart-define=CAPTURE_ICON_FONT=...\materialicons-regular.otf
```

- Flutter 3.50.0 stable, framework revision `ab2912035e`, Dart 3.14.0.
- Dependency lock SHA-256 `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`,
  resolved offline and **identical** on the baseline worktree and this branch
  (`material_ui 1.11.1`, `vector_math 2.4.4`).
- CJK font SHA-256 `9B1959DB3B3ABEB7EFDAEC26EDF7DFE871A6039DE8D614AF7248575207BE629E`,
  Material Icons SHA-256 `D9865B671A09D683D13A863089D8825E0F61A37696CE5D7D448BC8023AA62453`.
- The driver asserts, before every capture, that the pending row rendered, that
  the notifications read happened exactly once, and that **no host write
  occurred**; it also asserts no framework exception was taken. Before the
  confirmation image it asserts the dialog is open and `writes` is still empty;
  before the accepted image it asserts exactly one
  `POST /api/v1/friends/fixture-alice/accept` and the `已接受` label.

## Honest limits

- These are Flutter widget-harness renders of the production widget tree with a
  **fixture connection**, not device screenshots, not native Windows/Android
  acceptance, and not a live-host integration run. The fixture connection
  satisfies `HostConnection` in-process; no real HTTP loopback host was started
  for these images.
- They show the inbox row, the confirmation dialog and the accepted row only.
  They do not show a denied row, a failure row, or the lock/logout/account-change
  discard paths — those are covered by automated tests, not by images.
- Image input was unavailable to this model session, so the PNGs were **not**
  visually reviewed by an image-capable reader. Rendered text was checked
  indirectly: the driver asserted the expected widget keys/labels and the PNGs
  passed decode/dimension/non-blank/hash checks. Human visual review is still
  required.
- Behavioral coverage lives in the automated tests: 12 widget tests on
  `InboxScreen` (`test/inbox_invite_actions_test.dart`) and 4 production-shell
  tests through `WhaleChatApp` + `ClientRuntime`
  (`test/shell_inbox_invite_actions_test.dart`), plus the updated
  `test/inbox_screen_test.dart`.
