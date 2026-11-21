# Fetches the pinned PurismCore Web runtime into this package (MIT, third-party).
# The runtime binaries are NOT committed; run this once per checkout. The model
# itself is never downloaded or bundled by this script.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$dest = Join-Path $root 'web/runtime/purismcore'
$zip = Join-Path $env:TEMP 'PurismCore-v1.1.0-Web.zip'
$expected = 'ee229d1b28c33a9f57f02c777f8633141042cd771e5e47bf4795ba345b3a0b39'
$url = 'https://github.com/SakuraMotion/PurismCore/releases/download/v1.1.0/PurismCore-v1.1.0-Web.zip'

if (-not (Test-Path $zip)) {
  Invoke-WebRequest -Uri $url -OutFile $zip
}
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
  throw "PurismCore zip sha256 mismatch: $actual != $expected"
}

$extract = Join-Path $env:TEMP 'PurismCore-v1.1.0-Web'
if (Test-Path $extract) { Remove-Item -Recurse -Force $extract }
Expand-Archive -LiteralPath $zip -DestinationPath $extract
New-Item -ItemType Directory -Force -Path $dest | Out-Null
Copy-Item -LiteralPath (Join-Path $extract 'Core/purismcore.js') -Destination (Join-Path $dest 'purismcore.js') -Force
Copy-Item -LiteralPath (Join-Path $extract 'LICENSE') -Destination (Join-Path $dest 'LICENSE') -Force
Write-Host "PurismCore runtime installed to $dest"
