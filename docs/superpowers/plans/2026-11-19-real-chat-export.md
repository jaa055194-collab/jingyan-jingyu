# Real Chat Export Implementation Plan

> **For agentic workers:** Use task-scoped fresh contexts. Run a failing behavior regression before the minimal implementation.

**Goal:** The default host's existing export returns the current user's actually visible chat history instead of an empty in-memory source, and identifies the package as chat-history-only until other export domains are wired.

**Architecture:** Keep the version-1 text bundle and existing authenticated route. A production `ChatHistoryExportSource` delegates chat enumeration, membership/history checks and message paging to the same existing services as HTTP sync. Only host composition imports the two domain implementations. Coverage metadata is additive and does not imply restore or complete account portability.

**Spec:** [#131 C/R2](2026-11-18-project-delivery.md), [M12](../../modules/M12-lifecycle.md) FR-65/AC-29 and [decisions A-12](../../architecture/02-decisions.md). Main baseline `84410bdaae5c658f0ccf1cccee01b25736dabed9` (contains #145).

## Constraints

- No schema, HTTP request, frame or format-version break. Do not weaken membership, history or owner AI rules; never export an inaccessible conversation or prefix.
- No invented persona/attachment/memory data. An additive `coverage` manifest object must identify `scope: chatHistory`, `completeAccountExport: false`, and pending domains. Existing fixture export sources keep the old shape.
- No credentials, attachment contents, local paths, Live2D model bytes or T2 memory are added to the package.
- Export is read-only. Device work remains deferred; no deletion or import behavior is introduced.

## Scope and files

1. `apps/host/lib/src/lifecycle/chat_history_export_source.dart`: `ChatHistoryExportSource implements ExportSource` takes injected enumeration, floor, head, page and final batch-visibility callbacks. Validate/sort/dedupe IDs, snapshot sequence heads per conversation, page only the authorized suffix, reject gaps/wrong IDs/non-progress. A required final visibility snapshot filters revoked or rejoined histories together. Explicit assembly limits fail without truncation; message edits/recalls may still change across pages. Other methods return no unsupported-domain data.
2. `apps/host/lib/src/lifecycle/export.dart`: add optional `ExportCoverage`; include metadata only for implementing sources. Sanitize assembly failures to `internal`. An optional `maxImportRequestBytes` checks the exact UTF-8 import envelope after all files/checksums, so the default HTTP export does not report an oversized, non-importable package as success.
3. `apps/host/lib/jingyu_host.dart`: reuse one `PrivateConversations` instance, the canonical store and existing group/direct access rules. Add transaction-scoped floor helpers without changing their public results; `CombinedMembership.historySnapshot` reuses those policies in one transaction for final candidate bounds. Pass the source and `maxJsonBodyBytes` envelope limit to LifecycleModule. Do not change module responsibilities or default import sink.
4. Host tests: true SQLite / default host authenticated route with two owners, direct/group/late-join history, >1 page, revoked or ambiguous membership, empty groups, deterministic caps, corrupt read failure, and checksums. A fake callback test may control a mid-export membership change or message append. The default-host regression must be RED because current export has zero actual conversations.
5. Client `BackupQuotaScreen`: when `manifest.coverage.completeAccountExport == false`, display the source's known chat-history limitation in fixed local wording alongside counts. Keep old source/bundle behavior, import confirmation and actions intact. Widget regression and matched actual app Before/After.

## Execution

- [x] Reproduce current default-host empty export despite actual visible messages (expected 3 conversations / 202 messages, actual 0 / 0).
- [x] Implement adapter/coverage, limits, final transaction and exact import envelope; targeted host and legacy export/import tests pass.
- [x] Wire default host; root checks passed (host 1,525 passed, 15 existing skips); scoped policy/adapter/default-host 47 passed.
- [x] Surface honest scope; focused client 17 passed, full Flutter 625 passed / one opt-in skip and analysis clean.
- [x] Independent final code review found no blockers for this partial export.
- [ ] Add matched application captures, push and bind PR, then wait final checks and report review-ready (not full R2 or formal release).
