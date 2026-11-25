# Stage a self-contained phase-one candidate. No builds, no deployment, no user data.
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$SourceRoot,
  [Parameter(Mandatory = $true)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$Commit,
  [Parameter(Mandatory = $true)][string]$WindowsBundleDir,
  [Parameter(Mandatory = $true)][string]$AndroidApk,
  [Parameter(Mandatory = $true)][string]$HostSourceDir,
  [Parameter(Mandatory = $true)][string]$LauncherPath,
  [Parameter(Mandatory = $true)][string]$VerificationNotePath,
  [Parameter(Mandatory = $true)][string]$OutputDir
)

$ErrorActionPreference = 'Stop'

function Require-File([string]$path) {
  $item = Get-Item -LiteralPath $path -Force
  if ($item.PSIsContainer -or $item.Length -eq 0 -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Expected a nonempty regular file: $path"
  }
  $item.FullName
}
function Require-Dir([string]$path) {
  $item = Get-Item -LiteralPath $path -Force
  if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
    throw "Expected a regular directory: $path"
  }
  $item.FullName
}

$source = Require-Dir $SourceRoot
$head = & git -C $source rev-parse HEAD
if ($LASTEXITCODE -ne 0 -or $head -ne $Commit.ToLowerInvariant()) { throw 'SourceRoot HEAD does not match Commit' }
$stamp = $Commit.Substring(0, 7).ToLowerInvariant()
$apk = Require-File $AndroidApk
$hostSource = Require-Dir $HostSourceDir
$launcher = Require-File $LauncherPath
$verification = Require-File $VerificationNotePath
$template = Require-File (Join-Path $PSScriptRoot 'phase_one_release/README.template.md')
$persona = Require-File (Join-Path $source 'docs/examples/persona-sample.json')

# The bundled host must be a reviewed source snapshot: required entry points and
# no local build, dependency metadata, Git metadata or sensitive-looking files.
foreach ($required in @('apps/host/bin/server.dart', 'apps/host/bin/init_accounts.dart', 'apps/host/bin/http_worker.dart', 'apps/host/pubspec.yaml', 'tool/init_host.ps1', 'docs/host-setup.md', 'packages/jingyu_core/pubspec.yaml', 'packages/jingyu_protocol/pubspec.yaml', 'packages/jingyu_host_kit/pubspec.yaml')) {
  $null = Require-File (Join-Path $hostSource ($required -replace '/', '\'))
}
if (Test-Path -LiteralPath (Join-Path $hostSource '.git')) { throw 'Host source snapshot must not contain .git' }
foreach ($unclean in @('apps/client_flutter/build', 'apps/client_flutter/.dart_tool', 'apps/host/.dart_tool', 'packages/jingyu_core/.dart_tool', 'dist', 'node_modules')) {
  if (Test-Path -LiteralPath (Join-Path $hostSource ($unclean -replace '/', '\'))) {
    throw "Host source snapshot contains local build/dependency state: $unclean"
  }
}
$hostItems = @(Get-ChildItem -LiteralPath $hostSource -Force -Recurse)
$suspicious = $hostItems | Where-Object {
  ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
  $_.Name -match '^\.env(?:\.|$)|\.(?:sqlite[\w.-]*|kek|log|pem|pfx|key|p12)$' -or
  $_.Name -match '^(?:secrets?\.local|\.dart_tool|build|node_modules)$'
}
if ($suspicious) { throw "Host source snapshot contains suspicious paths: $($suspicious[0].FullName)" }

$windows = Require-Dir $WindowsBundleDir
foreach ($required in @('client_flutter.exe', 'flutter_windows.dll', 'data/app.so', 'data/icudtl.dat', 'data/flutter_assets/AssetManifest.bin')) {
  $null = Require-File (Join-Path $windows $required)
}
$windowsItems = @(Get-ChildItem -LiteralPath $windows -Force -Recurse)
if ($windowsItems | Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $_.Name -match '^\.env(?:\.|$)|\.(?:sqlite[\w.-]*|kek|log|pem|pfx|key|p12)$' }) {
  throw 'Windows bundle contains links or sensitive-looking files'
}

$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDir)
$parent = Split-Path -Parent $destination
if (-not (Test-Path -LiteralPath $parent -PathType Container) -or (Split-Path -Leaf $destination) -ne "jingyu-phase-one-$stamp") {
  throw 'OutputDir must be a new jingyu-phase-one-<shortsha> child of an existing staging directory'
}
if (Test-Path -LiteralPath $destination) { throw "Output already exists; refusing to overwrite: $destination" }
foreach ($localApp in @($env:LOCALAPPDATA, $env:APPDATA)) {
  if ($localApp) {
    $forbidden = (Join-Path $localApp 'Jingyu').TrimEnd('\') + '\'
    if (($destination + '\').StartsWith($forbidden, [StringComparison]::OrdinalIgnoreCase)) { throw 'OutputDir must not be in host data' }
  }
}
$ancestor = Get-Item -LiteralPath $parent -Force
while ($null -ne $ancestor) {
  if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Output path must not traverse a reparse point' }
  $ancestor = $ancestor.Parent
}

$zipName = "jingyu-windows-phase-one-$stamp.zip"
$readme = [IO.File]::ReadAllText($template, [Text.Encoding]::UTF8).
  Replace('{{COMMIT}}', $head).
  Replace('{{SHORT}}', $stamp).
  Replace('{{ZIP_NAME}}', $zipName).
  Replace('{{VERIFICATION}}', [IO.File]::ReadAllText($verification, [Text.Encoding]::UTF8).Trim())
if ($readme -match '\{\{[A-Z0-9_]+\}\}') { throw 'Unresolved README template token' }

$temporary = Join-Path $parent ('jingyu-package-tmp-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $temporary
try {
  $windowsOut = Join-Path $temporary 'windows'
  Copy-Item -LiteralPath $windows -Destination $windowsOut -Recurse -Force
  $androidOut = Join-Path $temporary 'android'
  $null = New-Item -ItemType Directory -Path $androidOut
  Copy-Item -LiteralPath $apk -Destination (Join-Path $androidOut 'jingyu-debug.apk')
  $hostOut = Join-Path $temporary 'host'
  Copy-Item -LiteralPath $hostSource -Destination $hostOut -Recurse -Force
  Copy-Item -LiteralPath $launcher -Destination (Join-Path $temporary 'start-host.ps1')
  Copy-Item -LiteralPath $persona -Destination (Join-Path $temporary 'persona-sample.json')
  Copy-Item -LiteralPath $verification -Destination (Join-Path $temporary 'VERIFICATION.md')
  [IO.File]::WriteAllText((Join-Path $temporary 'README.md'), $readme, [Text.UTF8Encoding]::new($false))
  [IO.File]::WriteAllText(
    (Join-Path $temporary 'HOST-SOURCE.txt'),
    "host/ is a clean source snapshot of commit $head produced with: git archive --format=zip --prefix=host/ $head`r`nNo Git metadata, build outputs or user data are included.`r`n",
    [Text.UTF8Encoding]::new($false)
  )
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  [IO.Compression.ZipFile]::CreateFromDirectory($windowsOut, (Join-Path $temporary $zipName), [IO.Compression.CompressionLevel]::Optimal, $false)
  $manifest = @(Get-ChildItem -LiteralPath $temporary -Force -File -Recurse | Sort-Object FullName | ForEach-Object {
    $relative = $_.FullName.Substring($temporary.Length + 1).Replace('\', '/')
    '{0}  {1}' -f (Get-FileHash -Algorithm SHA256 -LiteralPath $_.FullName).Hash.ToLowerInvariant(), $relative
  })
  [IO.File]::WriteAllLines((Join-Path $temporary 'SHA256SUMS'), $manifest, [Text.UTF8Encoding]::new($false))
  $hostFileCount = @(Get-ChildItem -LiteralPath $hostOut -Recurse -File).Count
  [IO.Directory]::Move($temporary, $destination)
  Write-Output "PACKAGE_STAGED=$destination FILE_COUNT=$($manifest.Count) HOST_FILES=$hostFileCount COMMIT=$head"
} finally {
  if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}