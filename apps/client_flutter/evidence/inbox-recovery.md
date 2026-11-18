# Inbox recovery — Flutter painter comparison

- Before: [0c23edd61603a49211aa22dcd8d70da16d35ad76](jin-inbox-before-0c23edd.png), SHA-256 `9BAD9C189434BDF192963810B1308A341A338482988BCF55741F3DBE71019FF5`.
- After: [156ccd3d321bb2dffc3eacaba89782f3da5ab033](jin-inbox-after-156ccd3.png), SHA-256 `730206B79C71DA8DC6C24A29B7AC530215538D304D558552B76F9DE8F425CFDC`.

Both images are unedited PNGs of the production `WhaleChatApp` widget tree using Flutter's `RenderRepaintBoundary.toImage` in isolated test worktrees. Same inbox tab, 1280×960 pixels at DPR 1, light theme, and dependency lock SHA-256 `1BD53182D4767917EF2291C46EF18CFB85C4EAE15B357F5F5246FE43AB7390FC`. Same synthetic connected recipient (`fixture-recipient`) and test connection returning one pending friend invite from `fixture-alice`; the baseline shows the unavailable state, and the final shell reads the metadata and renders the row. Capture uses the same fixed Windows CJK and Material icon fonts for both revisions. No live accounts, saved sessions or private messages.

The driver asserted the expected state and no framework exception before capture. Dimensions, nonblank raster and SHA-256 were checked. This is Flutter widget/painter evidence, not native Windows or mobile acceptance, a live-host integration capture, or manual visual review. Host route and HTTP loopback coverage are separate automated checks.
