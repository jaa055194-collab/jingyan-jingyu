# M11 Client Controllers Implementation Plan

Goal: Implement pure Dart durable shell controllers, secure native lock coordination, onboarding, consent, and capability callbacks.
Architecture: Inject persistence, transport, native authentication, and host APIs. Serialize shell mutations so durable enqueue precedes transport; preserve wire message ids across retries.
Tech Stack: Dart, existing core/protocol dependencies only.
Spec: docs/modules/M11-client-shell.md and docs/plugins/01-plugin-spec.md; layering: docs/architecture/01-layering.md.

Constraints: Own client-kit files only. No Flutter or third-party runtime dependencies. No commits. Native bridge owns PIN verification and storage; no raw PIN persistence.

Review focus: concurrent enqueue/flush; persistence failure before network; replayed/gapped sequences; lock authentication failure; undeclared plugin capability.

- [x] Write controller behavior tests; run and observe missing-feature failures.
- [x] Implement ClientPersistence and ClientShellController with durable outbox, dropped failures, mirrors, cursors and drafts. Verify restart and concurrent flush.
- [x] Write tests and implement ConversationConsentController, AppLockController and OnboardingController using injected dependencies.
- [x] Write tests and implement readConversation/modelInvoke capability callbacks, preserving existing constructor compatibility.
- [x] Run full client-kit test suite, format, and analyze. Report exact interfaces and limitations to parent.
