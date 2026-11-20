# Two client runtimes: queued send and lost HTTP acknowledgement

This test-only check covers the offline-send and idempotency subset of [FR-14](../../鲸言鲸语-需求规格-v4.2.md#L144-L147) / [AC-18](../../鲸言鲸语-需求规格-v4.2.md#L704) and [roadmap #131, workstream A](../superpowers/plans/2026-11-18-project-delivery.md#L65-L70). It complements [the owner-AI check](owner-chat-integration.md) (#162); this scenario is human-to-human and has no model worker.

## What is exercised

1. Two synthetic human accounts use the production `ClientRuntime` password login over IPv4 loopback. They use separate client storage roots and separate in-memory platform session stubs. The test sets up the relationship through the real friend request, accept, and direct-chat HTTP routes.
2. The host listener stops. The sender explicitly sends while offline: its draft is consumed, no submission reaches the host, and reopening the sender still offline restores the queued text and its original `clientMsgId` with zero attempts.
3. The host reopens at the same origin with default modules and SQLite. The test-only [HTTP adapter](../../apps/host/test/support/dual_chat_integration_fixture.dart) calls the real pipeline, then closes the socket before writing response headers for the first successful message POST. The recipient already reads the committed row at seq 1; the sender still has one queued item with one attempt and the original ID.
4. The host and SQLite reopen again. Refresh retries the same `clientMsgId`; the real host returns `duplicate: true`, the same canonical ID and seq 1, and the outbox clears. Independent full HTTP history and both runtimes show one message with the original text and ID. Further syncs do not produce another message POST.

## Run it on Windows

From the repository root (use a short worktree path if necessary). Offline resolution assumes the packages are already in the local cache. `JINGYU_TEST_DART` must name the absolute SDK `dart.exe`, not the `.bat` launcher.

```powershell
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$env:JINGYU_TEST_DART = Join-Path (Split-Path -Parent $flutter) 'cache/dart-sdk/bin/dart.exe'
Push-Location apps/host
try { dart pub get --offline; if ($LASTEXITCODE -ne 0) { throw 'Host dependencies failed' } }
finally { Pop-Location }
Push-Location apps/client_flutter
try {
  flutter pub get --offline
  if ($LASTEXITCODE -ne 0) { throw 'Client dependencies failed' }
  flutter test --no-pub --concurrency=1 --reporter expanded `
    --dart-define=JINGYU_RUN_DUAL_CHAT_INTEGRATION=true test/runtime_real_host_dual_chat_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'Dual-chat integration failed' }
} finally { Pop-Location }
```

[The Flutter test](../../apps/client_flutter/test/runtime_real_host_dual_chat_test.dart) skips without the opt-in define. To check the assertion, add `--dart-define=JINGYU_DUAL_CHAT_CHANGE_RETRY_ID=true` to the test command. Only in this negative control, the listener substitutes a different ID for the retry before passing it to the real pipeline. The run must exit 1 at `the reopened SQLite host must contain one canonical row after retry`, with `[1, 2]` instead of `[1]`.

## Recorded result and limits

Windows x64, Flutter 3.50.0 / Dart 3.14.0, on production baseline `6c0c0c43283b2124fa14dd93a11a01d3012c684f`: positive run **1 passed**; changed-ID negative control **1 failed** at the persisted row assertion; without opting in **1 skipped**. The two new Dart files passed targeted static analysis.

The runtimes are driven in one plain-async Flutter test, with a mocked client platform channel and manual HTTP refreshes. No system session store, native UI, physical devices, production accounts, or external providers were used. The real default host uses its normal Windows storage initialization on temporary files; the listener is a fault-injection fixture, not the deployed server entrypoint. The harness stops only its own child and removes its own temporary data, and its trace includes no passwords, session tokens or message bodies. This does not verify WebSocket/push, cross-device unread counts, arbitrary network failures, or complete AC-18 acceptance.
