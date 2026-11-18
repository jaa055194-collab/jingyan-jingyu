# Friend actions — Flutter painter comparison

- Before: [0c23edd61603a49211aa22dcd8d70da16d35ad76](jin-friend-before-0c23edd.png), SHA-256 `6E2A0FC1BA91DABE2714DDA512CF2A87F4C1BA212988159A21C5CEF1FB53C3E9`.
- After: [bca748b37e57276f35b0e34e3b98f94d1a50cb0e](jin-friend-after-bca748b.png), SHA-256 `4D01092AB9658578F87C168C5721AEB6C4CE0253030FEBAEE3E2541E31CD3BA3`.

Both PNGs come from Flutter `RenderRepaintBoundary.toImage` over the production `WhaleChatApp` in isolated test worktrees. Both show the Contacts tab, 1280×960 pixels at DPR 1, light theme, identical dependency lock SHA-256 `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC` and the same synthetic pending row for Fixture Alice (`fixture-alice`). Both sides use the same Windows CJK and Material icon test fonts. The capture test asserted a single friends list read, no framework exception, and absence of invitation controls before vs both controls enabled after. No mutation was issued during capture; the production shell regression separately checks writes only after explicit taps.

No real credentials, accounts, sessions or conversations were used. Dimensions, nonblank raster and SHA-256 were checked. This is Flutter widget/painter evidence, not native-device acceptance, a live-host capture or manual visual review.
