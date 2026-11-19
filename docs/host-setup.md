# 在 Windows 上运行宿主并连接客户端

客户端只接受**同一设备的环回 HTTP**或**有受信证书的 HTTPS**。尾网 IP 是私有地址，但 `http://<尾网 IP>:8787` 仍不是可用的客户端地址。把 `http://` 改成 `https://` 也不会让宿主自动提供 TLS。

## 1. 在本机启动宿主

准备 Dart SDK 3.9 或以上（可随 Flutter 安装），确认 `dart --version` 可用。以下命令从仓库根目录在 Windows PowerShell 中运行。初始化使用独立窗口；如执行策略禁止运行脚本，核对源码后可用 `powershell.exe -NoProfile -ExecutionPolicy Bypass` 打开仅本次使用的窗口，不必改系统策略。

仅在**首次部署**时初始化一个新的数据目录。已有宿主跳到日常启动，沿用原数据目录。若脚本找不到 SDK，可用 `-Dart` 指定 SDK 中的 `dart.exe`；Flutter 的 SDK 位于其 `bin\cache\dart-sdk` 下。

```powershell
$data = Join-Path $env:LOCALAPPDATA 'Jingyu\host-data'
$secret = Read-Host '设置管理员密码（至少 12 位）' -AsSecureString
try {
  $password = [System.Net.NetworkCredential]::new('', $secret).Password
  .\tool\init_host.ps1 -DataDir $data -AdminName 'Root' -AdminPassword $password `
    -BindAddress 127.0.0.1 -Port 8787
} finally {
  Remove-Variable password,secret -ErrorAction SilentlyContinue
}
```

初始化会打印管理员账号 ID 和一次性邀请码，然后停止临时宿主。请私下保存这些信息，不要截屏或发到群里。邀请码用于创建普通客户端账户，不是管理员密码，也不是账户 ID。

日常启动时在仓库根目录重新执行下列命令。若初始化时用了其他数据目录或端口，此处对应修改。`host.env` 是配置记录，不会自动加载。

```powershell
$env:JINGYU_DATA_DIR = Join-Path $env:LOCALAPPDATA 'Jingyu\host-data'
$env:JINGYU_BIND = '127.0.0.1'
$env:JINGYU_PORT = '8787'
Set-Location .\apps\host
dart run bin/server.dart
```

保留宿主窗口。在另一窗口运行 `Invoke-RestMethod http://127.0.0.1:8787/api/v1/health`，确认返回 `status: ok`。**同一台电脑的客户端**可填 `http://127.0.0.1:8787`。停止时在宿主窗口按 Ctrl+C；下次启动沿用同一数据目录。

## 2. 可选：让 Android 或另一台电脑访问

宿主继续监听环回地址。目标设备需加入同一私有 tailnet 并获准访问宿主，tailnet 管理员需启用 MagicDNS 和 HTTPS 证书。以下以 Tailscale Serve 为例，不使用 Funnel，不开公网端口。若机器已有 Serve 配置，先用 `tailscale serve status` 确认不会覆盖已有服务。

宿主健康后，在另一窗口运行：

```powershell
tailscale serve --https=443 8787
```

保留该窗口，把 Serve 输出的 **`https://…ts.net` 域名**填给另一台设备的客户端。不要填尾网 IP、代理路径或宿主后端端口；若用了非默认 HTTPS 端口，以 Serve 打印的完整 HTTPS 地址为准。先在目标设备的浏览器访问该地址加 `/api/v1/health`，确认**无需忽略证书告警**就能看到 `status: ok`。若 Serve 尚未启用，先由管理员完成尾网设置；同机验证不需要等待。也可使用现有的私有 HTTPS 反向代理转发到同一环回宿主，不要关闭客户端证书校验。

## 3. 创建账户、登录与排查

- **新建账户**：使用未用过且未过期的邀请码，填显示名、设备名和账户密码。成功后保存展示的**账号 ID**。
- **已有账户**：填同一宿主的地址、账号 ID、设备名和账户密码，不再用邀请码。邀请码用完或过期，请让该宿主管理员签发新邀请，不要为此重建旧库。
- **`Invalid host origin; HTTPS is required`**：客户端没发出认证请求。检查地址是否是同机环回 HTTP 或受信的 HTTPS origin（不含路径、查询、用户名或密码）。
- **健康检查不通**：先确认宿主已启动、端口相同；跨机再检查尾网权限、证书和代理指向。健康检查通过后，再排查邀请码或账户凭据。
