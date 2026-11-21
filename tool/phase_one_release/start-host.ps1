# 第一期候选包启动脚本：默认使用包内 host/ 干净源码快照。
[CmdletBinding()]
param(
  [string]$RepoRoot = '',
  [string]$DataDir = '',
  [string]$BindAddress = '',
  [int]$Port = 0,
  [string]$Dart = '',
  [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

function Fail([string]$message) { throw "START_HOST_FAILED: $message" }

if (-not $RepoRoot) { $RepoRoot = Join-Path $PSScriptRoot 'host' }
if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) {
  Fail "找不到宿主源码目录：$RepoRoot（请用 -RepoRoot 指向匹配该提交的源码副本）"
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$hostApp = Join-Path $RepoRoot 'apps\host'
foreach ($required in @('bin\server.dart', 'bin\http_worker.dart', 'pubspec.yaml')) {
  if (-not (Test-Path -LiteralPath (Join-Path $hostApp $required) -PathType Leaf)) {
    Fail "宿主源码不完整，缺少 apps\host\$required：$RepoRoot"
  }
}
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'tool\init_host.ps1') -PathType Leaf)) {
  Fail "宿主源码不完整，缺少 tool\init_host.ps1：$RepoRoot"
}

function Resolve-SdkDart([string]$explicit) {
  if ($explicit) {
    if (-not (Test-Path -LiteralPath $explicit -PathType Leaf)) { Fail "指定的 Dart 不存在：$explicit" }
    $candidate = (Resolve-Path -LiteralPath $explicit).Path
  } else {
    $cmd = Get-Command dart -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $candidate = $cmd.Source }
    else {
      $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Flutter\flutter\bin\cache\dart-sdk\bin\dart.exe'
      if (-not (Test-Path -LiteralPath $fallback -PathType Leaf)) {
        Fail '找不到 dart（请安装 Flutter/Dart SDK，或用 -Dart 指定 SDK 的 dart.exe）'
      }
      $candidate = $fallback
    }
  }
  if ([IO.Path]::GetExtension($candidate) -in @('.bat', '.cmd')) {
    $sdK = Join-Path (Split-Path -Parent $candidate) 'cache\dart-sdk\bin\dart.exe'
    if (Test-Path -LiteralPath $sdK -PathType Leaf) { return (Resolve-Path -LiteralPath $sdK).Path }
  }
  return $candidate
}
$dartPath = Resolve-SdkDart $Dart

if (-not $DataDir) { $DataDir = $env:JINGYU_DATA_DIR }
if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'Jingyu\host-data' }
$DataDir = [IO.Path]::GetFullPath($DataDir)
if (-not (Test-Path -LiteralPath $DataDir -PathType Container)) {
  Fail "数据目录不存在：$DataDir（首次使用请按 README 运行配套源码的 tool\init_host.ps1，不要手工建库）"
}
$database = Join-Path $DataDir 'host.sqlite'
if (-not (Test-Path -LiteralPath $database -PathType Leaf)) {
  Fail "数据目录尚未初始化：$DataDir（先按 README 运行 tool\init_host.ps1，并沿用原数据目录）"
}

if (-not $BindAddress) { if ($env:JINGYU_BIND) { $BindAddress = $env:JINGYU_BIND } else { $BindAddress = '127.0.0.1' } }
if ($Port -eq 0) { if ($env:JINGYU_PORT) { $Port = [int]$env:JINGYU_PORT } else { $Port = 8787 } }
if ($Port -lt 1 -or $Port -gt 65535) { Fail "端口不合法：$Port" }

# Leave both override variables unset by default so bin/server.dart resolves
# the running SDK and its sibling worker. Explicit overrides belong to the operator.
$workerExecutable = [Environment]::GetEnvironmentVariable('JINGYU_MODEL_WORKER_EXECUTABLE')
$workerPath = [Environment]::GetEnvironmentVariable('JINGYU_MODEL_WORKER_PATH')
$workerMode = 'default'
if ($null -ne $workerExecutable -or $null -ne $workerPath) {
  foreach ($override in @($workerExecutable, $workerPath)) {
    if ([string]::IsNullOrWhiteSpace($override) -or
        $override -notmatch '^(?:[A-Za-z]:[\\/]|\\\\[^\\]+\\[^\\]+\\)' -or
        -not (Test-Path -LiteralPath $override -PathType Leaf)) {
      Fail '请同时设置 JINGYU_MODEL_WORKER_EXECUTABLE 和 JINGYU_MODEL_WORKER_PATH 为两个现有文件的绝对路径，或同时清除它们。'
    }
  }
  $workerMode = 'explicit'
} else {
  $workerPath = Join-Path $hostApp 'bin\http_worker.dart'
}

if ($CheckOnly) {
  Write-Output "CHECK_OK RepoRoot=$RepoRoot"
  Write-Output "CHECK_OK DataDir=$DataDir BindAddress=$BindAddress Port=$Port"
  Write-Output "CHECK_OK Dart=$dartPath WorkerMode=$workerMode Worker=$workerPath"
  return
}

Push-Location $hostApp
try {
  if (-not (Test-Path -LiteralPath '.dart_tool\package_config.json' -PathType Leaf)) {
    Write-Host '首次运行：解析宿主依赖（需要网络或本地 pub 缓存）…'
    # In Windows PowerShell 5.1 redirected native stderr can otherwise stop
    # execution before the offline failure can fall back to normal pub get.
    $previousPreference = $ErrorActionPreference
    try {
      $ErrorActionPreference = 'Continue'
      & $dartPath pub get --offline
      if ($LASTEXITCODE -ne 0) {
        & $dartPath pub get
        if ($LASTEXITCODE -ne 0) { Fail '依赖解析失败：请在 apps\host 目录手动运行 dart pub get' }
      }
    } finally { $ErrorActionPreference = $previousPreference }
  }
  $names = @('JINGYU_DATA_DIR', 'JINGYU_BIND', 'JINGYU_PORT')
  $previous = @{}
  foreach ($name in $names) { $previous[$name] = [Environment]::GetEnvironmentVariable($name) }
  try {
    $env:JINGYU_DATA_DIR = $DataDir
    $env:JINGYU_BIND = $BindAddress
    $env:JINGYU_PORT = "$Port"
    & $dartPath run bin/server.dart
    exit $LASTEXITCODE
  } finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $previous[$name]) }
  }
} finally {
  Pop-Location
}