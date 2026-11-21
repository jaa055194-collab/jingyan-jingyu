# Read an owned AI's persona change history

This is the read-only history step of #131 (FR-41). The existing AI configuration page can now show the immutable persona change log for the owned AI it already resolved. The view is disclosure-limited: version, kind, UTC time, lock transition and the number of changed fields per layer. It never renders field names/values, reasons, actors, history IDs, evidence IDs or snapshots. It performs no persona, lock or revert write and adds no route.

## Matched application captures

Both frames come from the production `WhaleChatApp` and the same synthetic Settings → AI configuration path, with the same owned AI/profile and fixture host. They use light theme, 1280 × 960 logical and physical pixels at DPR 1, font scale 1, the same dependency lock `C0BF09F7A5EF28F2AFAA8819BFE6A7ABDAC2A0F975D033C8B4E96D4D99099937`, SimHei as Roboto/Ahem (`9B1959DB…629E`) and the Flutter Material icon font (`D9865B67…62453`).

| State | Production source | PNG SHA-256 |
| --- | --- | --- |
| Before: AI persona card without a history control; renders at the same anchor | `5f2141b9fe5233e87082eb47dc3b3d31aca783f6` (tree `4f8afe5f856e56bdb83b6656598646704e0eebac`) | `EF46BB905ABA204890AF238498B633F38FECB2EE4B3BCA463675E2FBF1809E90` |
| After: the same card offers **读取人格历史（只读）** | this PR's code tree (head commit) | `D295A23A0B802054BC34B297D53A6282F09BCF2222B3C5A4A6B89975B97A1331` |
| Follow-on after one tap: three disclosed version summaries; no raw values | same After commit | `8A932881923161F90B5E5F086F88A556646B413262D1F589C262285E8D89D29A` |

Images: [Before](before.png) · [After](after.png) · [After reading one page](after-read.png). Driver: [persona_history_capture_test.dart](../persona_history_capture_test.dart); the same driver file was used for both runs.

The driver asserts that opening the page issues no new history read, that the Before tree has no history control, and that the After tap issues exactly one `GET /api/v1/ai-profiles/fixture-profile/persona/history?afterVersion=0&limit=20`. Its follow-on frame verifies three version rows, per-layer field counts, and the absence of fixture field/value/reason/evidence/actor strings. PNG dimensions, nonblank rendering, hashes and the changed-pixel counts between states were checked programmatically. No image-capable review was available, so human visual review remains outstanding.

## Verification and limits

On Windows with Flutter 3.50.0/Dart 3.14.0, both focused suites passed 21/21, scoped analysis was clean and the capture test passed 1/1. The history read is bounded to 20 rows and 2 MiB per page, uses the additive query-aware bounded GET without changing `getBoundedJson`, and cancels on route/session changes. One page is shown at a time; no polling or auto-next.

The fixture is a synthetic loopback host, not a live host, native device or real account. This slice does not implement revert, lock, history for other owners, memory/life-engine behavior, or complete FR-41/AC-05 acceptance.