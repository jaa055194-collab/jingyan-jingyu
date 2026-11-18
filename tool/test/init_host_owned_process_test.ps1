# Offline regression for AC-31. Default: parse only; never execute the bootstrap.
# Optional: -Integration -Dart <SDK dart.exe> runs with two temporary loopback hosts.
[CmdletBinding()]
param([switch]$Integration, [string]$Dart)

$ErrorActionPreference = 'Stop'
$tool = Split-Path -Parent $PSScriptRoot
$script = Join-Path $tool 'init_host.ps1'
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($script, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -ne 0) { throw 'Bootstrap does not parse.' }
$globalProcessCommands = $ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and
        $node.GetCommandName() -in @('Get-CimInstance', 'Get-WmiObject', 'Get-Process', 'Stop-Process', 'taskkill')
}, $true)
if ($globalProcessCommands.Count -gt 0) {
    throw 'Bootstrap must not discover or stop processes by global command/PID; use its owned process object.'
}
$bom = [IO.File]::ReadAllBytes($script) | Select-Object -First 3
if (($bom -join ',') -ne '239,187,191') { throw 'Bootstrap must keep its UTF-8 BOM for Windows PowerShell 5.1.' }
# Inspect ownership without executing even the cleanup block. The process
# returned by Start-Process must be the only target of termination.
$launch = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
        $node.Left.VariablePath.UserPath -eq 'server'
}, $true))
if ($launch.Count -ne 1) { throw 'Expected one assignment of the owned server process.' }
$start = $launch[0].Right.Find({
    param($node)
    $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Start-Process'
}, $true)
if (-not $start -or 'PassThru' -notin $start.CommandElements.ParameterName) {
    throw 'The server process must be returned by Start-Process -PassThru.'
}
$kill = @($ast.FindAll({
    param($node)
    $node -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Member.Value -eq 'Kill'
}, $true))
if ($kill.Count -ne 1 -or $kill[0].Static -or
    $kill[0].Expression -isnot [System.Management.Automation.Language.VariableExpressionAst] -or
    $kill[0].Expression.VariablePath.UserPath -ne 'server' -or $kill[0].Arguments.Count -ne 0) {
    throw 'Only the owned server object may receive a non-recursive Kill call.'
}
$inFinally = $false
for ($node = $kill[0]; $node.Parent; $node = $node.Parent) {
    if ($node.Parent -is [System.Management.Automation.Language.TryStatementAst] -and
        [object]::ReferenceEquals($node, $node.Parent.Finally)) {
        $inFinally = $true
        break
    }
}
if (-not $inFinally) { throw 'Owned process cleanup must run in finally.' }
Write-Host 'PASS: BOM, Windows PowerShell parse and owned-only cleanup structure (no process started).'
if (-not $Integration) { return }

if (-not $Dart) { throw 'Integration requires an SDK dart.exe path.' }
$Dart = (Resolve-Path -LiteralPath $Dart).Path
$repo = Split-Path -Parent $tool
$hostApp = Join-Path $repo 'apps/host'
if (Test-Path Env:JINGYU_DATA_DIR) { throw 'Run the integration in a clean test shell.' }
foreach ($name in 'JINGYU_BIND', 'JINGYU_PORT', 'JINGYU_ADMIN_NAME', 'JINGYU_ADMIN_PASSWORD', 'JINGYU_MODEL_WORKER_EXECUTABLE', 'JINGYU_MODEL_WORKER_PATH', 'JINGYU_HOST_ACCOUNT_ID', 'JINGYU_HOST_DEVICE_ID') {
    if (Test-Path "Env:$name") { throw 'Run the integration in a clean test shell with no configured Jingyu host or credentials.' }
}
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$fixtureRoot = Join-Path $tempRoot ('jingyu-bootstrap-test-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $fixtureRoot
$controlData = Join-Path $fixtureRoot 'control data'
$bootstrapData = Join-Path $fixtureRoot 'bootstrap data'
$control = $null

function Reserve-TestPorts {
    $listeners = @()
    try {
        for ($i = 0; $i -lt 2; $i++) {
            $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
            $listener.Start()
            $listeners += $listener
        }
        foreach ($listener in $listeners) { $listener.LocalEndpoint.Port }
    } finally {
        foreach ($listener in $listeners) { $listener.Stop() }
    }
}

function Test-Health([int]$Port) {
    try { (Invoke-RestMethod -Uri "http://127.0.0.1:$Port/api/v1/health" -TimeoutSec 1).status -eq 'ok' }
    catch { $false }
}

try {
    Push-Location $hostApp
    try {
        & $Dart pub get --offline
        if ($LASTEXITCODE -ne 0) { throw 'Integration requires cached dependencies.' }
    } finally { Pop-Location }
    $controlPort, $bootstrapPort = Reserve-TestPorts
    $env:JINGYU_DATA_DIR = $controlData
    $env:JINGYU_BIND = '127.0.0.1'
    $env:JINGYU_PORT = "$controlPort"
    $controlLog = Join-Path $fixtureRoot 'control.out'
    $control = Start-Process -FilePath $Dart -ArgumentList 'bin/server.dart' -WorkingDirectory $hostApp -PassThru `
        -RedirectStandardOutput $controlLog -RedirectStandardError (Join-Path $fixtureRoot 'control.err')
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($control.HasExited -or $deadline.Elapsed.TotalSeconds -ge 20) { throw 'Owned control host did not start.' }
        $ownedReady = (Get-Content -LiteralPath $controlLog -Raw) -match "listening on 127\.0\.0\.1:$controlPort\b"
        if (-not $ownedReady) { Start-Sleep -Milliseconds 100 }
    } until ($ownedReady)
    if (-not (Test-Health $controlPort)) { throw 'Owned control host was not healthy.' }

    # Invoke in this test shell with an explicitly constructed fresh data path.
    # Both the account and its passphrase are synthetic and never rendered.
    $pass = 'synthetic-' + [guid]::NewGuid().ToString('N')
    & $script -DataDir $bootstrapData -AdminName 'Synthetic Bootstrap' -AdminPassword $pass `
        -BindAddress '127.0.0.1' -Port $bootstrapPort -Dart $Dart 6>$null
    if ($control.HasExited -or -not (Test-Health $controlPort)) { throw 'Bootstrap stopped the independent control host.' }
    if (Test-Health $bootstrapPort) { throw 'Bootstrap left its temporary host running.' }
    # Verify port release, not just the disappearance of a healthy response.
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $bootstrapPort)
    try { $probe.Start() } finally { $probe.Stop() }
    $config = Get-Content -LiteralPath (Join-Path $bootstrapData 'host.env')
    if ($config.Count -ne 3 -or "JINGYU_DATA_DIR=$bootstrapData" -notin $config -or
        'JINGYU_BIND=127.0.0.1' -notin $config -or "JINGYU_PORT=$bootstrapPort" -notin $config) {
        throw 'Bootstrap did not write the expected listener configuration.'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $bootstrapData 'host.sqlite'))) { throw 'Bootstrap database is missing.' }
    Write-Host 'PASS: bootstrap completed; its port was released; the independent control host stayed healthy.'

    $collisionData = Join-Path $fixtureRoot 'occupied port data'
    & {
        # No HTTP may be issued by bootstrap before its own bind marker. Block
        # every request in this scoped negative test so no credentials can be
        # sent to a listener other than the newly started bootstrap server.
        $requests = [Collections.Generic.List[string]]::new()
        function Invoke-RestMethod {
            param($Uri, $TimeoutSec, $Method, $ContentType, $Body, $Headers)
            $requests.Add([string]$Method)
            throw 'Collision fixture blocked HTTP request.'
        }
        $failure = $null
        try {
            & $script -DataDir $collisionData -AdminName 'Synthetic Collision' -AdminPassword $pass `
                -BindAddress '127.0.0.1' -Port $controlPort -Dart $Dart 6>$null
        } catch { $failure = $_ }
        if ($requests.Count -ne 0) { throw 'Bootstrap probed an occupied port before its own startup marker.' }
        if (-not $failure -or $failure.Exception.Message -notlike '*server.err*') {
            throw 'Expected an owned startup failure on the occupied port.'
        }
        if ((Get-Content -LiteralPath (Join-Path $collisionData 'init-server.out.log') -Raw) -match 'listening on') {
            throw 'The collision fixture unexpectedly bound the port.'
        }
    }
    if (Test-Path -LiteralPath (Join-Path $collisionData 'host.env')) { throw 'Collision wrote host.env.' }
    if ($control.HasExited -or -not (Test-Health $controlPort)) { throw 'Collision affected the control host.' }
    Write-Host 'PASS: occupied port failed before any HTTP request or config write; control stayed healthy.'

    $inviteFailureData = Join-Path $fixtureRoot 'invite failure data'
    & {
        $requests = [Collections.Generic.List[string]]::new()
        function Invoke-RestMethod {
            param($Uri, $TimeoutSec, $Method, $ContentType, $Body, $Headers)
            $requests.Add(([uri]$Uri).AbsolutePath)
            if (([uri]$Uri).AbsolutePath -eq '/api/v1/admin/invites') {
                throw 'Synthetic invite failure after owned host login.'
            }
            Microsoft.PowerShell.Utility\Invoke-RestMethod @PSBoundParameters
        }
        $failure = $null
        try {
            & $script -DataDir $inviteFailureData -AdminName 'Synthetic Invite Failure' -AdminPassword $pass `
                -BindAddress '127.0.0.1' -Port $bootstrapPort -Dart $Dart 6>$null
        } catch { $failure = $_ }
        if (-not $failure -or $failure.Exception.Message -ne 'Synthetic invite failure after owned host login.' -or
            '/api/v1/auth/login' -notin $requests) { throw 'Expected a failure after the temporary host logged in.' }
    }
    if (Test-Path -LiteralPath (Join-Path $inviteFailureData 'host.env')) { throw 'Invite failure wrote host.env.' }
    if ($control.HasExited -or -not (Test-Health $controlPort)) { throw 'Invite failure affected the control host.' }
    $probe = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, $bootstrapPort)
    try { $probe.Start() } finally { $probe.Stop() }
    Write-Host 'PASS: invite failure cleaned up the owned host, wrote no config and left control healthy.'

    # Only stop the control process that this fixture started, then prove no
    # listener from the collision was left behind at the formerly occupied port.
    $control.Kill()
    if (-not $control.WaitForExit(5000)) { throw 'Control host did not stop.' }
    # Windows can retain the bind in TIME_WAIT after an HTTP connection. Check
    # for a listening peer, not exclusive rebind, on the former control port.
    $probe = [Net.Sockets.TcpClient]::new()
    try {
        $listening = $false
        try { $probe.Connect([Net.IPAddress]::Loopback, $controlPort); $listening = $true }
        catch [Net.Sockets.SocketException] {
            if ($_.Exception.SocketErrorCode -ne [Net.Sockets.SocketError]::ConnectionRefused) { throw }
        }
        if ($listening) { throw 'A listener remains on the collision port.' }
    } finally { $probe.Dispose() }
} finally {
    if ($control) {
        try {
            if (-not $control.HasExited) { $control.Kill(); $control.WaitForExit() }
        } finally { $control.Dispose() }
    }
    Remove-Item Env:JINGYU_DATA_DIR,Env:JINGYU_BIND,Env:JINGYU_PORT,Env:JINGYU_ADMIN_NAME,Env:JINGYU_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    $resolved = (Resolve-Path -LiteralPath $fixtureRoot).Path
    if ($resolved -ceq $fixtureRoot -and (Split-Path -Leaf $resolved) -match '^jingyu-bootstrap-test-[0-9a-f]{32}$') {
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
