# Friend actions — Flutter painter comparison

Before: `4ea0f6b` (main includes #116 and #124). After images were captured at `40b28f7762ab193479e1abc732da647e048ae975` and re-rendered at product revision `44fbf626815504ac3d0b68c51b1c4e5995dad6e0`. The pending, unbound, and empty After PNGs all matched the existing files byte-for-byte (SHA-256). The new account-ID fallback applies only to names that become blank after control-character replacement, a separate case covered by a widget regression.

| Scene | Before | After |
| --- | --- | --- |
| Pending | [PNG](jin-friend-pending-before-4ea0f6b.png) | [PNG](jin-friend-pending-after-40b28f7.png) |
| Unbound | [PNG](jin-friend-unbound-before-4ea0f6b.png) | [PNG](jin-friend-unbound-after-40b28f7.png) |
| Empty | [PNG](jin-friend-empty-before-4ea0f6b.png) | [PNG](jin-friend-empty-after-40b28f7.png) |

Each PNG comes from Flutter `RenderRepaintBoundary.toImage` over the production `WhaleChatApp` in isolated test worktrees. All show the Contacts tab, 1280×960 pixels at DPR 1, light theme, and the same test dependency lock and Windows CJK / Material icon fonts. Each pair uses the same synthetic host state: Fixture Alice (`fixture-alice`) pending, no connection, or a connected empty list. The capture test asserted one list read when connected (zero when unbound), the expected displayed state, no framework exception, and the invitation controls absent before vs enabled after in the pending scene. No mutation was issued during capture; the production shell regression separately checks writes only after explicit taps.

No real credentials, accounts, sessions or conversations were used. Dimensions, nonblank raster and SHA-256 were checked. This is Flutter widget/painter evidence, not native-device acceptance, a live-host capture or manual visual review.
