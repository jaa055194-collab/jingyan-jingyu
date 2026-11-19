# Live2D Preview Preparation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prepare a local preview bundle from a selected ZIP and stage it privately without writing archive paths or arbitrary archive entries.

**Architecture:** Extend the existing preflight to retain only checked renderer inputs on the preview path. Build a fresh minimal model3 manifest under generated filenames. Flutter owns an isolated temporary directory; neither preparation nor staging activates a renderer or changes account state.

**Tech Stack:** Dart, existing archive package, native Dart zlib, Flutter test.

**Spec:** Approved #131 roadmap F/R1 and FR-38/39. Continue draft #128; this is not AC-25/26 completion.

## Global Constraints

- Models and parameter maps remain per-device; no network, bundled SDK/model, host upload or shared backups.
- Preview preparation does not select/activate a model, open a WebView, or establish rendering fidelity.
- Stage only a generated manifest, MOC3 and referenced PNG textures; no ZIP entry names become disk destinations.

## Review Focus

- A rejected package must yield no preview bundle or staged files.
- Unused payloads and original manifest fields must not become viewer resources.
- Texture slots retain manifest order; duplicate references keep their slots.
- Disk staging must clean up its own directory, never a caller directory or another session.

### Task 1: Verified preview inputs

**Files:** `packages/jingyu_client_kit/lib/src/live2d_package.dart`, `lib/src/live2d_preview_inflate*.dart`, `test/live2d_package_test.dart`.

**Interface:** `Live2DPreviewBundle prepareLive2DPreview(Uint8List bytes, {Live2DPackageLimits limits, int maxArchiveBytes, int maxPreviewBytes})`; `.model3Name` and `.files`. Throws `FormatException` on invalid input.

- [x] Observe RED for the missing preview API and aggregate resource budget.
- [x] Reuse the existing archive and manifest validation; bound selected resources before exposing them; use native chunked inflater for preview and refuse DEFLATE where it is unavailable.
- [x] Run focused and full client-kit checks; exercise the provided ZIP privately.

### Task 2: Private staging

**Files:** `apps/client_flutter/lib/features/world/live2d_preview_stage.dart`, `apps/client_flutter/test/live2d_preview_stage_test.dart`.

- [x] Observe RED for the missing stage, write rollback and retryable cleanup.
- [x] Write only fixed bundle names to unique child directories. Preserve both errors and a cleanup handle when rollback fails.
- [x] Run focused and full Flutter tests and review the file boundary. No UI or renderer changes in this increment.
