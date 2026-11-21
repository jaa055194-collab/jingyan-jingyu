# Hermetic contract test for the phase-one candidate staging tooling.
[CmdletBinding()]
param([string]$SourceRoot = '')

$ErrorActionPreference = 'Stop'
if (-not $SourceRoot) { $SourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot) }
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$builder = Join-Path $SourceRoot 'tool/build_phase_one_package.ps1'
$launcher = Join-Path $SourceRoot 'tool/phase_one_release/start-host.ps1'
$template = Join-Path $SourceRoot 'tool/phase_one_release/README.template.md'
$verifier = Join-Path $SourceRoot 'tool/phase_one_release/verify_package.ps1'
foreach ($path in @($builder, $launcher, $template, $verifier)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "missing tool: $path" }
}

$prefix = 'jingyu-package-contract-'
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$root = Join-Path $tempBase ($prefix + [guid]::NewGuid().ToString('N'))
$failures = [System.Collections.Generic.List[string]]::new()
function Assert([bool]$condition, [string]$message) {
  if ($condition) { Write-Output "PASS $message" }
  else { $failures.Add($message); Write-Output "FAIL $message" }
}
function Write-Text([string]$path, [string]$text) {
  $parent = Split-Path -Parent $path
  if ($parent) { $null = New-Item -ItemType Directory -Force -Path $parent }
  [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}
function Invoke-Child([string[]]$arguments) {
  $out = Join-Path $root ('child-' + [guid]::NewGuid().ToString('N') + '.out')
  $err = Join-Path $root ('child-' + [guid]::NewGuid().ToString('N') + '.err')
  $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
  $process = Start-Process -FilePath $powershellExe -ArgumentList $arguments -Wait -PassThru -RedirectStandardOutput $out -RedirectStandardError $err -WindowStyle Hidden
  $result = @{ ExitCode = $process.ExitCode; StdOut = [IO.File]::ReadAllText($out); StdErr = [IO.File]::ReadAllText($err) }
  Remove-Item -LiteralPath $out, $err -Force
  return $result
}
function New-FixtureRepo {
  $repo = Join-Path $root 'repo'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $repo 'tool/phase_one_release')
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $repo 'docs/examples')
  Copy-Item -LiteralPath $builder -Destination (Join-Path $repo 'tool/build_phase_one_package.ps1')
  Copy-Item -LiteralPath $template -Destination (Join-Path $repo 'tool/phase_one_release/README.template.md')
  Write-Text (Join-Path $repo 'docs/examples/persona-sample.json') '{"format":"PRIVATE_AI_PERSONA_1","p0":{"name":"fixture"},"p1":{"style":"fixture"},"p2":{"mood":"fixture"}}'
  Write-Text (Join-Path $repo 'READMEROOT.md') 'fixture repository'
  & git -C $repo init -q
  if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
  & git -C $repo config user.name 'fixture'
  & git -C $repo config user.email 'fixture@example.invalid'
  & git -C $repo add -A
  & git -C $repo commit -q -m fixture
  if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
  return @{ Path = $repo; Head = (& git -C $repo rev-parse HEAD) }
}
function New-FixtureWindows {
  $windows = Join-Path $root 'windows-bundle'
  foreach ($pair in @(
      @('client_flutter.exe', 'fixture exe'),
      @('flutter_windows.dll', 'fixture dll'),
      @('data/app.so', 'fixture aot'),
      @('data/icudtl.dat', 'fixture icu'),
      @('data/flutter_assets/AssetManifest.bin', 'fixture manifest'))) {
    Write-Text (Join-Path $windows $pair[0]) $pair[1]
  }
  return $windows
}
function New-FixtureHost {
  $hostDir = Join-Path $root 'host-snapshot'
  foreach ($relative in @(
      'apps/host/bin/server.dart',
      'apps/host/bin/init_accounts.dart',
      'apps/host/bin/http_worker.dart',
      'apps/host/pubspec.yaml',
      'tool/init_host.ps1',
      'docs/host-setup.md',
      'docs/persona-card-format.md',
      'packages/jingyu_core/pubspec.yaml',
      'packages/jingyu_protocol/pubspec.yaml',
      'packages/jingyu_host_kit/pubspec.yaml',
      'packages/jingyu_client_kit/pubspec.yaml')) {
    Write-Text (Join-Path $hostDir $relative) 'fixture source'
  }
  Write-Text (Join-Path $hostDir 'apps/host/lib/src/config.dart') 'fixture config'
  return $hostDir
}
function Invoke-Builder([hashtable]$arguments) {
  return & (Join-Path $root 'repo/tool/build_phase_one_package.ps1') @arguments
}

try {
  $repo = New-FixtureRepo
  $windows = New-FixtureWindows
  $hostSource = New-FixtureHost
  $apk = Join-Path $root 'app-debug.apk'
  [IO.File]::WriteAllBytes($apk, [byte[]](1..255))
  $verificationNote = Join-Path $root 'verification.md'
  Write-Text $verificationNote "# Fixture verification`r`n`r`n- Synthetic result only."
  $staging = Join-Path $root 'staging'
  $null = New-Item -ItemType Directory -Path $staging
  $stamp = $repo.Head.Substring(0, 7)
  $expectedOut = Join-Path $staging "jingyu-phase-one-$stamp"
  $baseArgs = @{
    SourceRoot = $repo.Path
    Commit = $repo.Head
    WindowsBundleDir = $windows
    AndroidApk = $apk
    HostSourceDir = $hostSource
    LauncherPath = $launcher
    VerificationNotePath = $verificationNote
    OutputDir = $expectedOut
  }

  # 1. Happy path: self-contained layout, complete checksum coverage.
  $output = Invoke-Builder $baseArgs
  Assert (($output -join "`n") -match 'PACKAGE_STAGED=') 'staging reports PACKAGE_STAGED'
  foreach ($relative in @('windows/client_flutter.exe', 'windows/data/app.so', 'windows/data/flutter_assets/AssetManifest.bin', 'android/jingyu-debug.apk', 'host/apps/host/bin/server.dart', 'host/tool/init_host.ps1', 'start-host.ps1', 'persona-sample.json', 'README.md', 'VERIFICATION.md', 'HOST-SOURCE.txt', 'SHA256SUMS', "jingyu-windows-phase-one-$stamp.zip")) {
    Assert (Test-Path -LiteralPath (Join-Path $expectedOut $relative)) "layout contains $relative"
  }
  $sourceInfo = Get-Content -LiteralPath (Join-Path $expectedOut 'HOST-SOURCE.txt') -Raw
  Assert ($sourceInfo -match [regex]::Escape($repo.Head) -and $sourceInfo -match 'git archive') 'HOST-SOURCE records commit and archive method'
  $readme = Get-Content -LiteralPath (Join-Path $expectedOut 'README.md') -Raw
  Assert ($readme -notmatch '\{\{[A-Z0-9_]+\}\}') 'README has no unresolved tokens'
  Assert ($readme -match [regex]::Escape($repo.Head)) 'README names the source commit'
  Assert ($readme -match 'Synthetic result only') 'README embeds the verification note'
  Assert (($readme -match 'host\\tool\\init_host.ps1') -or ($readme -match 'host/tool/init_host.ps1')) 'README points first-time init at bundled host'
  Assert (($readme -match 'b1FastBrain=2000') -and ($readme -match 'chat=8000')) 'README shows concrete budget format'
  Assert ((Get-Content -LiteralPath (Join-Path $expectedOut 'VERIFICATION.md') -Raw).Trim() -eq (Get-Content -LiteralPath $verificationNote -Raw).Trim()) 'VERIFICATION copied verbatim'
  $sums = @(Get-Content -LiteralPath (Join-Path $expectedOut 'SHA256SUMS') -Encoding UTF8)
  $allFiles = @(Get-ChildItem -LiteralPath $expectedOut -Force -Recurse -File | Where-Object FullName -ne (Join-Path $expectedOut 'SHA256SUMS'))
  Assert ($sums.Count -eq $allFiles.Count) 'SHA256SUMS covers every staged file'
  $sumOk = $true
  foreach ($line in $sums) {
    $match = [regex]::Match($line, '^([0-9a-f]{64})  (.+)$')
    if (-not $match.Success) { $sumOk = $false; break }
    $full = Join-Path $expectedOut ($match.Groups[2].Value -replace '/', '\')
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { $sumOk = $false; break }
    if ((Get-FileHash -Algorithm SHA256 -LiteralPath $full).Hash.toLowerInvariant() -ne $match.Groups[1].Value) { $sumOk = $false; break }
  }
  Assert $sumOk 'SHA256SUMS matches recomputed hashes'

  # 2. Independent verifier accepts the staged package, then detects corruption.
  $verified = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifier, '-PackageDir', $expectedOut)
  Assert (($verified.ExitCode -eq 0) -and ($verified.StdOut -match 'SHA256SUMS_OK')) 'verify_package accepts staged package'
  $exePath = Join-Path $expectedOut 'windows/client_flutter.exe'
  $exeBytes = [IO.File]::ReadAllBytes($exePath)
  [IO.File]::WriteAllBytes($exePath, [byte[]](1..3))
  $tampered = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $verifier, '-PackageDir', $expectedOut)
  Assert (($tampered.ExitCode -ne 0) -and ($tampered.StdOut -notmatch 'SHA256SUMS_OK')) 'verify_package rejects a modified release file'
  [IO.File]::WriteAllBytes($exePath, $exeBytes)

  # 3. Package launcher resolves the bundled host and the existing data dir.
  $dataDir = Join-Path $root 'host-data'
  Write-Text (Join-Path $dataDir 'host.sqlite') 'fixture database'
  $packageLauncher = Join-Path $expectedOut 'start-host.ps1'
  $check = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packageLauncher, '-CheckOnly', '-DataDir', $dataDir)
  Assert (($check.ExitCode -eq 0) -and ($check.StdOut -match 'CHECK_OK RepoRoot=') -and ($check.StdOut -match [regex]::Escape((Join-Path $expectedOut 'host')))) 'launcher -CheckOnly binds bundled host by default'
  Assert (($check.StdOut -match [regex]::Escape($dataDir)) -and ($check.StdOut -match 'Port=8787')) 'launcher reports data dir and default port'
  $missingRepo = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packageLauncher, '-CheckOnly', '-DataDir', $dataDir, '-RepoRoot', (Join-Path $root 'no-such-host'))
  Assert ($missingRepo.ExitCode -ne 0) 'launcher rejects a missing host root'
  $missingData = Invoke-Child @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $packageLauncher, '-CheckOnly', '-RepoRoot', (Join-Path $expectedOut 'host'), '-DataDir', (Join-Path $root 'no-such-data'))
  Assert ($missingData.ExitCode -ne 0) 'launcher rejects an uninitialized data dir'

  # 4. Incorrect or destructive staging is refused.
  $exists = $false
  try { Invoke-Builder $baseArgs | Out-Null } catch { $exists = $_.Exception.Message -match 'already exists' }
  Assert $exists 'existing output directory is never overwritten'

  $wrongCommitArgs = $baseArgs.Clone()
  $wrongCommitArgs.Commit = ('0' * 40)
  $wrongCommitArgs.OutputDir = Join-Path $staging ('jingyu-phase-one-' + ('0' * 7))
  $wrongCommit = $false
  try { Invoke-Builder $wrongCommitArgs | Out-Null } catch { $wrongCommit = $_.Exception.Message -match 'HEAD does not match' }
  Assert $wrongCommit 'source HEAD mismatch is rejected'

  $dirtyHost = Join-Path $root 'host-with-git'
  Copy-Item -LiteralPath $hostSource -Destination $dirtyHost -Recurse
  $null = New-Item -ItemType Directory -Path (Join-Path $dirtyHost '.git')
  $dirtyArgs = $baseArgs.Clone()
  $dirtyArgs.HostSourceDir = $dirtyHost
  $dirtyArgs.OutputDir = Join-Path $staging ('jingyu-phase-one-' + $stamp + '-dirty')
  $dirty = $false
  try { Invoke-Builder $dirtyArgs | Out-Null } catch { $dirty = $_.Exception.Message -match 'must not contain .git' }
  Assert $dirty 'host snapshot with Git metadata is rejected'

  $buildStateHost = Join-Path $root 'host-with-build'
  Copy-Item -LiteralPath $hostSource -Destination $buildStateHost -Recurse
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $buildStateHost 'apps/host/.dart_tool')
  $buildStateArgs = $baseArgs.Clone()
  $buildStateArgs.HostSourceDir = $buildStateHost
  $buildStateArgs.OutputDir = Join-Path $staging ('jingyu-phase-one-' + $stamp + '-build')
  $buildState = $false
  try { Invoke-Builder $buildStateArgs | Out-Null } catch { $buildState = $_.Exception.Message -match 'local build/dependency state' }
  Assert $buildState 'host snapshot with local dependency state is rejected'

  $badWindows = Join-Path $root 'windows-missing-exe'
  Copy-Item -LiteralPath $windows -Destination $badWindows -Recurse
  Remove-Item -LiteralPath (Join-Path $badWindows 'client_flutter.exe')
  $badWindowsArgs = $baseArgs.Clone()
  $badWindowsArgs.WindowsBundleDir = $badWindows
  $badWindowsArgs.OutputDir = Join-Path $staging ('jingyu-phase-one-' + $stamp + '-noexe')
  $badWindowsRejected = $false
  try { Invoke-Builder $badWindowsArgs | Out-Null } catch { $badWindowsRejected = $true }
  Assert $badWindowsRejected 'Windows bundle without executable is rejected'
} finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}

if ($failures.Count -gt 0) {
  Write-Output ("PACKAGE_CONTRACT_FAILED count={0}" -f $failures.Count)
  exit 1
}
Write-Output 'PACKAGE_CONTRACT_PASSED'