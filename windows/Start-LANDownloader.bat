@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
set "LAN_SHARE_ROOT=%~dp0"
set "LAN_LAUNCHER=%~f0"
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$s=[IO.File]::ReadAllText($env:LAN_LAUNCHER); & ([scriptblock]::Create(($s -split '(?m)^# POWERSHELL_BEGIN\r?$',2)[1]))"
exit /b %errorlevel%
# POWERSHELL_BEGIN
$ErrorActionPreference = 'Stop'
try {
    $shareRoot = [IO.Path]::GetFullPath($env:LAN_SHARE_ROOT)
    if ($shareRoot.Length -gt [IO.Path]::GetPathRoot($shareRoot).Length) { $shareRoot = $shareRoot.TrimEnd('\') }
    $candidatePaths = @((Join-Path $shareRoot 'caddy.exe'), $env:CADDY_EXE, 'C:\Caddy\caddy.exe', (Join-Path $env:LOCALAPPDATA 'Caddy\caddy.exe'))
    $caddyPath = $candidatePaths | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
    if (-not $caddyPath) {
        $command = Get-Command caddy.exe -ErrorAction SilentlyContinue
        if ($command) { $caddyPath = $command.Source }
    }
    if (-not $caddyPath) {
        Write-Host '没有找到 caddy.exe。' -ForegroundColor Yellow
        Write-Host '请把 caddy.exe 放到 C:\Caddy\caddy.exe（以后所有目录都可共用），或放在此 BAT 旁边。'
        Write-Host '官方下载：https://caddyserver.com/download'
        Read-Host '按回车关闭'; exit 1
    }
    function Test-FreePort([int] $number) {
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Any, $number)
        try { $listener.Start(); return $true } catch { return $false } finally { $listener.Stop() }
    }
    $stateDirectory = Join-Path $env:LOCALAPPDATA 'LANDownloader'
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($shareRoot.ToLowerInvariant()))).Replace('-', '') }
    finally { $hasher.Dispose() }
    $portFile = Join-Path $stateDirectory ($key + '.port')
    $portNumber = 8080
    $savedPort = 0
    if ((Test-Path -LiteralPath $portFile) -and [int]::TryParse([IO.File]::ReadAllText($portFile).Trim(), [ref]$savedPort) -and $savedPort -ge 1024 -and $savedPort -le 65535) { $portNumber = $savedPort }
    if (-not (Test-FreePort $portNumber)) {
        $previous = $portNumber
        $portNumber = 0
        foreach ($candidate in 8080..8199) { if (Test-FreePort $candidate) { $portNumber = $candidate; break } }
        if ($portNumber -eq 0) { throw '8080–8199 端口均被占用，请关闭不需要的共享窗口。' }
        Write-Host "端口 $previous 已占用，本目录改用 $portNumber。请在 App 中使用下面的新地址。" -ForegroundColor Yellow
    }
    [IO.File]::WriteAllText($portFile, [string]$portNumber)
    Write-Host ''
    Write-Host '局域网文件传输 · 当前文件夹共享' -ForegroundColor Cyan
    Write-Host "共享目录：$shareRoot"
    Write-Host "端口：$portNumber"
    Write-Host '请把以下与手机同网段的地址添加到 App：' -ForegroundColor Green
    $addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' } | Select-Object -ExpandProperty IPAddress -Unique)
    foreach ($ip in $addresses) { Write-Host ("  http://{0}:{1}" -f $ip, $portNumber) -ForegroundColor Green }
    if ($addresses.Count -eq 0) { Write-Host '未找到 IPv4 地址。请连接 Wi-Fi 或网线后重新启动。' -ForegroundColor Yellow }
    Write-Host ''
    Write-Host '保持本窗口打开；Ctrl+C 停止此目录共享。不要重复双击同一个目录的 BAT。'
    Write-Host '首次防火墙提示请选择允许专用网络。只共享你愿意向同一局域网开放的文件夹。'
    if ((Test-Path -LiteralPath (Join-Path $shareRoot 'index.html')) -or (Test-Path -LiteralPath (Join-Path $shareRoot 'index.txt'))) {
        Write-Host '注意：该目录存在 index.html/index.txt，Caddy 可能展示首页而不是清单；请改用不含首页文件的子目录。' -ForegroundColor Yellow
    }
    & $caddyPath file-server --root $shareRoot --listen (':' + $portNumber) --browse
    if ($LASTEXITCODE -ne 0) { throw "Caddy 启动失败（退出码 $LASTEXITCODE），请检查端口和目录。" }
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    Read-Host '按回车关闭'; exit 1
}
