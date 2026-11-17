# Device-local Avatar References Implementation Plan

> Native execution with test-first changes and independent review.

**Goal:** Keep Live2D models and model-specific mappings on each device; the host publishes only stable avatar references.

**Architecture:** Retain the existing owner-scoped world registry and revision semantics, remove model-specific mapping storage/transport, and introduce an independently validated local profile in the UI-independent client kit. No model or Cubism assets are added.

**Spec:** v4.2 FR-38/39, NFR-12 and AC-25/26, as amended by the approved local-import direction; M10-world.

## Constraints and review focus

- Existing migrations 900–904 remain unchanged; append migration 905 to remove existing server mapping data while preserving registered avatars and active revisions.
- POST avatar registration accepts only kind/modelId. Model identifiers are stable tokens, never local paths or URLs. Preserve owner isolation and stale-revision rejection.
- Local modelFile is a canonical relative model3 path; no absolute/remote paths, traversal, control characters, or Windows reserved names. This is metadata validation, not filesystem containment or complete import validation.
- Explicit nonempty mouth, blink, expression and motion mappings are required; parsing does not prove parameter/model existence.
- Runtime, safe archive extraction, persistence/UI and actual VRM fallback remain unimplemented and must not be represented as delivered.

## Tasks

- [x] Add local profile tests; observe missing API and invalid-input RED; implement immutable validated profile using existing package-path sanitizer.
- [x] Expand regressions so path/schema/revision rejection uses otherwise valid fixtures; observe empty-map/unknown-field/schema-type failures and fix them.
- [x] Test reference-only registration, storage and response, including upgrade from migration 904; remove old mapping contract and append 905.
- [x] Synchronize affected specs/M10/plugin descriptions and acceptance status; preserve unchanged specification bytes/line endings.
- [x] Add a reserved generated-ID namespace and a colliding legacy-ID regression; review exposed both the test failure and the implementation correction.
- [ ] Run focused tests and final full repository check after collision review fix; final diff review; then commit/push and create ticket PR with accurate limitations.
- [x] Assess an open runtime against the actual supplied model before selecting a rendering integration; never infer working Live2D from metadata tests.
- [x] Add a pure-Dart safe importer (`validateLive2DPackage`) with archive/JSON/MOC3/PNG/texture-budget checks and validate the supplied package locally.
- [ ] Add device-persisted profiles, a WebView renderer/bridge, hot-switch and verified VRM fallback; validate real-device GPU limits, memory and frame rate in follow-up increments.
