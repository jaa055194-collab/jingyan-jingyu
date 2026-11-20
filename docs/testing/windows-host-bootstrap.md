# Windows host bootstrap: temporary listener ownership

This is loopback evidence for part of AC-31. The Windows bootstrap must start a host from an empty directory, authenticate its synthetic administrator, create an invite and write the listener configuration only after success. It must stop the temporary listener without terminating any other host, including on failure.

## Run the existing regression

From the repository root on Windows, with dependencies available in the local Dart package cache and no existing `JINGYU_*` deployment settings in the test shell:

```powershell
$flutter = (Get-Command flutter -ErrorAction Stop).Source
$dart = Join-Path (Split-Path -Parent $flutter) 'cache/dart-sdk/bin/dart.exe'
& powershell.exe -NoProfile -File tool/test/init_host_owned_process_test.ps1
& powershell.exe -NoProfile -File tool/test/init_host_owned_process_test.ps1 -Integration -Dart $dart
```

If the Flutter command is a shim, supply the absolute SDK `dart.exe` path instead. Without `-Integration`, the check only verifies the script's BOM, Windows PowerShell parsing, and cleanup structure. With it, the check uses two IPv4 loopback ports, isolated data directories and a one-time synthetic password. Do not run it with a real data directory, and do not publish bootstrap output from a real deployment; it contains its initial invite.

The integration checks three paths:

- A new bootstrap creates the database and listener configuration, releases its listener and leaves the separately started control host healthy. Before forwarding the first request, the test verifies that Windows attributes the listener socket to the actual process returned by the bootstrap's launch.
- Occupying the requested port makes the new bootstrap fail before any HTTP request or configuration write. The control host stays healthy.
- A failure after successful login, while creating the invite, still releases the temporary listener, leaves the control host healthy and writes no configuration. The test then stops the control host and verifies its port no longer accepts a connection.

## Why the launch changed

On Windows with Dart SDK 3.14.0, starting a script with `dart.exe` launched a separate `dartvm.exe`; Windows attributed the listening socket to that VM, not to the CLI wrapper. A probe connected briefly after the wrapper's exit, but the owned VM and listener subsequently disappeared. This establishes an ownership and shutdown timing problem, not a persistent orphan. Another earlier run timed out waiting for a control listener to start; the cause of that variation was not established.

The new regression failed at the socket-owner assertion against `d916736`. With the launch fix, the same check passed on Windows PowerShell 5.1 with Dart SDK 3.14.0, including the successful initialize, occupied-port and post-login failure paths. The bootstrap now uses the adjacent `dartvm.exe` in a split SDK for the temporary listener. It retains the existing SDK CLI for dependency resolution and database initialization, and the previous direct `dart.exe` path when there is no separate VM. Startup limits, bind-marker and health gates, authentication, and the nonrecursive stop of the retained process are unchanged. This is not Tailnet, second-device, encrypted-restore or full release acceptance.
