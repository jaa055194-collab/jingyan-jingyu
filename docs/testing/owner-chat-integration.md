# Owner chat with the real client runtime and host

This opt-in check extends the two separate checks in #129 (real host listener) and #130 (client cursor recovery). It covers part of #131 R1 / AC-18, with the production `ClientRuntime`, a real IPv4 loopback listener, the default host modules and fresh SQLite storage. It changes no production code or dependencies.

## What the check proves

1. Create an isolated owner with a one-time password. The client starts signed out, calls the existing account login path and saves its session through a test platform channel. It enters chat without changing world setup.
2. The client creates an owned AI, configures it through the existing adapters, and explicitly enables owner-text consent. The existing shortcut resolves to the one authorized direct conversation. Updating the draft alone does not queue a send.
3. An explicit send results in one message POST. The production model pipeline invokes a separate deterministic worker through the existing process transport. The worker opens no sockets. Sync yields exactly the owner's message and one S2 reply, with distinct message IDs and sequences 1 and 2. The reply-status endpoint references those same IDs.
4. Stop the listener and observe the client go offline. Reopen the same host data directory at the same origin, and start a new runtime with the saved session and on-disk snapshot. Its sync starts at sequence 2; an independent history read from the reopened host verifies both rows and the original reply ID. The restarted client makes no login, token refresh or send request.

Only the loopback listener can receive client requests in the test. The test creates and removes its own temporary data root, uses no real vendor credentials, and stops only its own subprocesses. The host trace includes method, route, status and cursor/row counts; it never includes headers or message bodies. Session-channel storage stays in the test process instead of touching OS credentials.

## Run it

Use a terminal at the repository root on Windows. The example derives the SDK executable from the installed Flutter command; use an absolute SDK `dart.exe` path if your Flutter command is a shim. `--offline` assumes the dependencies are already cached.

```powershell
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$env:JINGYU_TEST_DART = Join-Path (Split-Path -Parent $flutter) 'cache/dart-sdk/bin/dart.exe'
$definition = '--dart-define=JINGYU_RUN_OWNER_CHAT_INTEGRATION=true'
Push-Location apps/host
try {
  dart pub get --offline
  if ($LASTEXITCODE -ne 0) { throw 'Host dependencies failed' }
} finally { Pop-Location }
Push-Location apps/client_flutter
try {
  flutter pub get --offline
  if ($LASTEXITCODE -ne 0) { throw 'Client dependencies failed' }
  flutter test --no-pub --concurrency=1 --reporter expanded $definition `
    test/runtime_real_host_owner_chat_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'Owner chat integration failed' }
} finally { Pop-Location }
```

The ordinary Flutter suite skips this test. For a negative control, run the same command with `--dart-define=JINGYU_OWNER_CHAT_REJECT_REPLY=true`. The worker then returns a synthetic failure; the acceptance assertion must fail because sync finds the stored owner message but no S2 reply. It must not fail at login or process startup.

## Observed result and limits

On Windows with Flutter 3.50.0 and Dart 3.14.0, the positive check passed; the negative control failed at the expected missing-reply assertion. The test manually drives the existing HTTP refresh at defined points instead of relying on a periodic timer. It does not exercise the deployed server entrypoint, native Windows or Android widgets, operating-system session storage, a live model, token rotation, a queued send during the outage, or a second device. See [the separate live-provider listener check](live-model-chat.md) for the provider evidence; neither check alone completes R1 or AC-18.
