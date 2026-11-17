# 对每个 Dart 包运行 pub get、analyze、test。任一失败则退出码非 0。
# 用法：在仓库根目录执行 powershell -ExecutionPolicy Bypass -File tool/check.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot

$dart = $null
$cmd = Get-Command dart -ErrorAction SilentlyContinue
if ($cmd) { $dart = $cmd.Source }
if (-not $dart) {
  $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Flutter\flutter\bin\cache\dart-sdk\bin\dart.exe'
  if (Test-Path $fallback) { $dart = $fallback } else { throw '找不到 dart，请先安装 Flutter/Dart SDK' }
}

$packages = @(
  'packages/jingyu_core',
  'packages/jingyu_protocol',
  'packages/jingyu_host_kit',
  'packages/jingyu_client_kit',
  'packages/jingyu_live2d_web',
  'apps/host'
)

$failed = @()
foreach ($p in $packages) {
  $dir = Join-Path $root $p
  Write-Host "=== $p ==="
  Push-Location $dir
  try {
    & $dart pub get | Out-Null
    if ($LASTEXITCODE -ne 0) { $failed += "$p (pub get)"; continue }
    & $dart analyze --fatal-infos
    if ($LASTEXITCODE -ne 0) { $failed += "$p (analyze)"; continue }
    & $dart test
    if ($LASTEXITCODE -ne 0) { $failed += "$p (test)" }
  } finally {
    Pop-Location
  }
}

if ($failed.Count -gt 0) {
  Write-Host "FAILED: $($failed -join ', ')" -ForegroundColor Red
  exit 1
}
Write-Host 'ALL CHECKS PASSED' -ForegroundColor Green
