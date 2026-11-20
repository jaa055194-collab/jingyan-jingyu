# Isolated Windows recovery drill with age and SQLite

This test-only rehearsal covers an initial part of [FR-64](../../鲸言鲸语-需求规格-v4.2.md#L592-L595) / AC-15 in [roadmap #131](../superpowers/plans/2026-11-18-project-delivery.md). It is not an operator backup or restore command. The ordinary host suite skips it.

## What the drill proves

1. Start the default host with temporary SQLite and normal Windows DPAPI key storage. Create a one-time synthetic administrator with a random password and a synthetic group message. Check that the stored message body is encrypted and stop the host before taking the snapshot.
2. Use Windows `tar.exe` to package only the closed `host.sqlite` and its DPAPI-protected `host.sqlite.kek`. Write an age-encrypted archive, not a plaintext tar file. Hash the ciphertext and verify the stored bytes. Both generated age identities (the matching one and a separate control) stay in memory and use age's standard input; no private key goes into argv, files, or logs.
3. Refuse a restore into a directory that already exists. Wrong identity, ciphertext digest mismatch, and modified ciphertext with a recomputed digest must all fail without creating a restore directory. Only the fixture's two expected members are read from the known archive; tar emits their bytes to the test instead of extracting paths to disk.
4. Restore to a fresh separate directory and verify both member hashes. Reopen the default host there, check `PRAGMA integrity_check` returns `ok`, log in as the synthetic owner, and read the same canonical message through the authenticated sync handler. Verify that the source database and its protected key file are unchanged.

This small fixture buffers archive/member bytes in memory with a per-child output bound. It uses no HTTP listener, real credentials, model provider, or live data. It writes its fixture data only under a newly allocated temporary root. Child operations have bounded waits and use caller-supplied absolute paths to trusted executables; the fixture neither installs software nor downloads it during testing.

## Reproduce

Use Windows x64 and Dart 3.14.0. Prepare trusted `age.exe` and `age-keygen.exe` for your system. The observed run used the official [age v1.3.2 Windows x64 ZIP](https://github.com/FiloSottile/age/releases/tag/v1.3.2), SHA-256 `f48d8f8f9ebe903ab5027ed067652f2cc1db94bc206976430133b905dcd8e8c7`, checked against GitHub release metadata, then extracted only the two executable members into local scratch storage. Windows supplies `tar.exe`.

```powershell
$env:JINGYU_TEST_AGE = '<absolute path to age.exe>'
$env:JINGYU_TEST_AGE_KEYGEN = '<absolute path to age-keygen.exe>'
$env:JINGYU_TEST_TAR = Join-Path $env:SystemRoot 'System32/tar.exe'
$env:JINGYU_RUN_AGE_RESTORE_DRILL = '1'
Push-Location apps/host
try {
  dart pub get --offline
  if ($LASTEXITCODE -ne 0) { throw 'Host dependencies failed' }
  dart test --concurrency=1 --reporter expanded test/age_sqlite_restore_drill_test.dart
  if ($LASTEXITCODE -ne 0) { throw 'Restore drill failed' }
} finally { Pop-Location }
```

On Windows x64 with Dart 3.14.0 and age 1.3.2, this drill and the adjacent storage suite passed together (19 tests). Without opting in, the drill skipped as designed. A first attempt using `age-keygen -o` failed to create an on-disk identity on this Windows setup; the drill instead uses age's documented streaming modes and does not create identity files.

## Remaining gates

Same Windows user and machine only: age decryption recovers the DPAPI-protected file, not the ability for another Windows profile or host to unwrap it. This does not implement or test production scheduling, live database snapshots, media, a second disk, remote storage, rotation, replay or deployment, or arbitrary archive import. It does not count as full AC-15 or a portable production restore. Use trusted test data only.
