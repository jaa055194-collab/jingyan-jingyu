# Read-only checks for a staged candidate; the ZIP is streamed, never extracted.
[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$PackageDir)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath $PackageDir).Path
$manifestPath = Join-Path $root 'SHA256SUMS'
$files = @(Get-ChildItem -LiteralPath $root -Force -Recurse | Where-Object {
  if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected link: $($_.FullName)" }
  -not $_.PSIsContainer -and $_.FullName -ne $manifestPath
})
$actual = @{}
foreach ($file in $files) { $actual[$file.FullName.Substring($root.Length + 1).Replace('\', '/')] = $file }
$digests = @{}
foreach ($line in [IO.File]::ReadAllLines($manifestPath, [Text.Encoding]::UTF8)) {
  if ($line -cnotmatch '^([a-f0-9]{64})  (.+)$') { throw 'Malformed checksum line' }
  $digest = $Matches[1]; $relative = $Matches[2]
  if (-not $actual.ContainsKey($relative) -or $digests.ContainsKey($relative)) {
    throw "Unknown or duplicate manifest item: $relative"
  }
  if ((Get-FileHash -Algorithm SHA256 -LiteralPath $actual[$relative].FullName).Hash -ne $digest) {
    throw "SHA-256 mismatch: $relative"
  }
  $digests[$relative] = $digest
}
if ($digests.Count -ne $files.Count) { throw 'Some package files are not covered by SHA256SUMS' }
$zipNames = @($digests.Keys | Where-Object { $_ -match '^jingyu-windows-phase-one-[a-f0-9]{7}\.zip$' })
if ($zipNames.Count -ne 1) { throw 'Expected exactly one Windows ZIP' }
foreach ($required in @('windows/client_flutter.exe', 'windows/flutter_windows.dll', 'windows/data/app.so', 'windows/data/icudtl.dat', 'windows/data/flutter_assets/AssetManifest.bin', 'android/jingyu-debug.apk', 'start-host.ps1', 'persona-sample.json', 'README.md')) {
  if (-not $digests.ContainsKey($required)) { throw "Missing package entry: $required" }
}
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [IO.Compression.ZipFile]::OpenRead($actual[$zipNames[0]].FullName)
$seen = @{}
try {
  foreach ($entry in $zip.Entries) {
    $relative = 'windows/' + $entry.FullName.Replace('\', '/')
    if ($relative -match '(?:^|/)\.\.(?:$|/)|[\:\x00]' -or $relative.StartsWith('windows//')) {
      throw "Unexpected ZIP path: $relative"
    }
    if ($relative.EndsWith('/')) { continue }
    if (-not $digests.ContainsKey($relative) -or $seen.ContainsKey($relative)) {
      throw "Unknown or duplicate ZIP entry: $relative"
    }
    if ($entry.Length -ne $actual[$relative].Length) { throw "ZIP entry size differs: $relative" }
    $stream = $entry.Open()
    try {
      if ((Get-FileHash -Algorithm SHA256 -InputStream $stream).Hash -ne $digests[$relative]) {
        throw "ZIP entry differs from release directory: $relative"
      }
    } finally { $stream.Dispose() }
    $seen[$relative] = $true
  }
} finally { $zip.Dispose() }
if ($seen.Count -ne @($digests.Keys | Where-Object { $_.StartsWith('windows/') }).Count) {
  throw 'Windows ZIP is missing bundled release files'
}
Write-Output "SHA256SUMS_OK FILES=$($files.Count) WINDOWS_ZIP_FILES=$($seen.Count)"
