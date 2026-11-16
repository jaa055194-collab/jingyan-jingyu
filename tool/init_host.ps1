# 鲸言鲸语宿主一键初始化（AC-31）
#
# 从一个空目录完成宿主搭建，不依赖任何旧库 / 旧配置 / 旧路径：
#   1) 离线解析依赖并建库（含全部迁移）；
#   2) 创建唯一管理员（trusted one-time bootstrap，不监听端口时完成）；
#   3) 启动一次宿主，管理员登录并生成第一个邀请码；
#   4) 把监听地址（默认取 tailnet 地址）写入 $DataDir\host.env，随后停止临时宿主。
#
# 用法（在仓库任意位置）：
#   pwsh -File tool/init_host.ps1 `
#     -DataDir C:\jingyu-data `
#     -AdminName Root `
#     -AdminPassword '<至少12位的口令>' `
#     [-BindAddress 100.x.y.z] [-Port 8787] [-Dart <dart.exe 绝对路径>]
#
# 说明：密钥/口令只经进程环境变量传入子进程，不写入仓库、不打印。脚本只修改
# $DataDir 下的数据，不改动源码；不 push / PR / merge。

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$DataDir,
  [Parameter(Mandatory = $true)][string]$AdminName,
  [Parameter(Mandatory = $true)][string]$AdminPassword,
  [string]$BindAddress = '',
  [int]$Port = 8787,
  [string]$Dart = ''
)

$ErrorActionPreference = 'Stop'

function Resolve-Dart([string]$explicit) {
  if ($explicit -and (Test-Path $explicit)) { return (Resolve-Path $explicit).Path }
  $cmd = Get-Command dart -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $fallback = Join-Path $env:LOCALAPPDATA 'Programs\Flutter\flutter\bin\cache\dart-sdk\bin\dart.exe'
  if (Test-Path $fallback) { return $fallback }
  throw '找不到 dart（请安装 Flutter/Dart SDK 或用 -Dart 指定 dart.exe）'
}

$repo = Split-Path -Parent $PSScriptRoot   # tool/ -> 仓库根
$hostApp = Join-Path $repo 'apps/host'
if (-not (Test-Path (Join-Path $hostApp 'bin/server.dart'))) {
  throw "未找到宿主工程：$hostApp"
}
$dartPath = Resolve-Dart $Dart

# 数据目录必须可创建或为空，保证“从零搭建、不依赖旧库/旧配置”。
$DataDir = [System.IO.Path]::GetFullPath($DataDir)
if (Test-Path $DataDir) {
  $existing = Get-ChildItem -Force -LiteralPath $DataDir -ErrorAction SilentlyContinue
  if ($existing -and @($existing).Count -gt 0) {
    throw "数据目录非空，拒绝在已有数据上初始化：$DataDir（请指定空目录或先手动备份/清除）"
  }
}
$null = New-Item -ItemType Directory -Force -Path $DataDir
$dataRoot = (Resolve-Path -LiteralPath $DataDir).Path

# 监听地址：显式传入 > tailscale IPv4 > 本地环回（并告警，提示部署到 tailnet）。
if (-not $BindAddress) {
  $ts = Get-Command tailscale -ErrorAction SilentlyContinue
  if ($ts) {
    try {
      $ip = (& tailscale ip -4 2>$null | Select-Object -First 1)
      if ($ip) { $BindAddress = $ip.Trim() }
    } catch { }
  }
}
if (-not $BindAddress) {
  $BindAddress = '127.0.0.1'
  Write-Warning '未检测到 tailnet 地址，回退到 127.0.0.1；部署时请用 -BindAddress 指定 tailnet 地址。'
}

$env:JINGYU_DATA_DIR = $dataRoot
$env:JINGYU_BIND = $BindAddress
$env:JINGYU_PORT = "$Port"
$env:JINGYU_ADMIN_NAME = $AdminName
$env:JINGYU_ADMIN_PASSWORD = $AdminPassword

Write-Host "== 1/4 解析依赖（离线）与建库/建管理员 =="
Push-Location $hostApp
try {
  & $dartPath pub get --offline 2>&1 | Out-Null
  if ($LASTEXITCODE -ne 0) {
    Write-Warning '离线 pub get 失败，尝试在线 pub get（首次部署可能需要）。'
    & $dartPath pub get 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'pub get 失败' }
  }

  $initOut = (& $dartPath run bin/init_accounts.dart 2>&1 | Out-String)
  if ($LASTEXITCODE -ne 0) {
    throw "管理员初始化失败（exit $LASTEXITCODE）。输出：$initOut"
  }
  $match = [regex]::Match($initOut, 'Administrator account:\s*([A-Za-z0-9_-]+)')
  if (-not $match.Success) { throw "无法从初始化输出解析管理员账号：$initOut" }
  $adminId = $match.Groups[1].Value
  Write-Host "管理员账号：$adminId"
} finally {
  Pop-Location
}

Write-Host "== 2/4 启动临时宿主（$BindAddress`:$Port）=="
$logOut = Join-Path $dataRoot 'init-server.out.log'
$logErr = Join-Path $dataRoot 'init-server.err.log'
$server = Start-Process -FilePath $dartPath `
  -ArgumentList @('run', 'bin/server.dart') `
  -WorkingDirectory $hostApp `
  -RedirectStandardOutput $logOut `
  -RedirectStandardError $logErr `
  -PassThru -WindowStyle Hidden

try {
  $base = "http://$BindAddress`:$Port"
  $healthy = $false
  for ($i = 0; $i -lt 120; $i++) {
    if ($server.HasExited) { break }
    try {
      $h = Invoke-RestMethod -Uri "$base/api/v1/health" -TimeoutSec 2
      if ($h.status -eq 'ok') { $healthy = $true; break }
    } catch { }
    Start-Sleep -Milliseconds 500
  }
  if (-not $healthy) {
    $errText = if (Test-Path $logErr) { Get-Content $logErr -Raw -ErrorAction SilentlyContinue } else { '' }
    throw "宿主未通过健康检查。server.err：$errText"
  }

  Write-Host '== 3/4 管理员登录并生成第一个邀请码 =='
  $loginBody = @{
    accountId      = $adminId
    'password' = $AdminPassword
    deviceName     = 'init-script'
  } | ConvertTo-Json
  $login = Invoke-RestMethod -Uri "$base/api/v1/auth/login" -Method Post `
    -ContentType 'application/json' -Body $loginBody -TimeoutSec 30
  $token = $login.accessToken
  if (-not $token) { throw '管理员登录未返回 accessToken' }

  $expires = (Get-Date).ToUniversalTime().AddDays(7).ToString('o')
  $inviteBody = @{ expiresAt = $expires; maxUses = 1 } | ConvertTo-Json
  $invite = Invoke-RestMethod -Uri "$base/api/v1/admin/invites" -Method Post `
    -ContentType 'application/json' `
    -Headers @{ authorization = "Bearer $token" } `
    -Body $inviteBody -TimeoutSec 30
  $inviteCode = $invite.code
  if (-not $inviteCode) { throw '未生成邀请码' }
} finally {
  Write-Host '== 4/4 停止临时宿主并写入配置 =='
  if ($server -and -not $server.HasExited) {
    Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue
  }
  # 尽力清理 dart run 拉起的子进程（按命令行匹配本工程的 bin/server.dart）。
  Get-CimInstance Win32_Process -Filter "Name = 'dart.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'bin[\\/]server\.dart' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}

$configPath = Join-Path $dataRoot 'host.env'
@(
  "JINGYU_DATA_DIR=$dataRoot"
  "JINGYU_BIND=$BindAddress"
  "JINGYU_PORT=$Port"
) | Set-Content -LiteralPath $configPath -Encoding UTF8

Write-Host ''
Write-Host '初始化完成（AC-31）。' -ForegroundColor Green
Write-Host "  数据目录：$dataRoot"
Write-Host "  管理员账号：$adminId"
Write-Host "  首个邀请码：$inviteCode"
Write-Host "  监听地址：$BindAddress`:$Port"
Write-Host "  配置写入：$configPath"
Write-Host '启动：在 apps/host 下  dart run bin/server.dart（读取上面的 JINGYU_* 环境/配置）。'
