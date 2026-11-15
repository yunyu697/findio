#Requires -Version 7.0
<#
.SYNOPSIS
  托盘失败气泡验收：让自动更新检查真实失败，触发「更新检查未完成」气泡，截图并读日志。
.DESCRIPTION
  历史证据只有 Shell_NotifyIconW 返回 ok=True + 日志，没有用户可见的气泡外观截图。
  本脚本不改产品代码，只做两件可还原的事：
    1. 用户级代理指向 127.0.0.1:9（关闭端口），让 UpdateService 的真实 HTTP 请求失败；
    2. config.json 把 lastUpdateCheck 调到 25 小时前，使启动时的自动检查到点。
  UI 以 --tray 启动，6 秒后检查失败 → ShowTrayInfo → 日志「托盘提示已提交…ok=True」。
  日志出现后立刻整屏截图，然后无论成败都还原代理与配置、结束进程。
.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpTrayBalloon.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Findio.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Findio.UI.exe'
$LpServiceExe = Join-Path $LpRepo 'src\Findio.Service\bin\x64\Debug\net8.0-windows\Findio.Service.exe'
$LpLog = Join-Path $env:LOCALAPPDATA ('Findio\logs\ui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Findio\config.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-tray-config-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$LpShot = Join-Path $LpRepo 'docs\shots\85-tray-failure-balloon.png'
$LpProxyKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$LpToastKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'

$LpChecks = [System.Collections.Generic.List[object]]::new()
function Add-LpCheck {
    param([string]$LpName, [bool]$LpPassed, [string]$LpDetail)
    $LpChecks.Add([pscustomobject]@{ Name = $LpName; Passed = $LpPassed; Detail = $LpDetail })
    $LpTag = if ($LpPassed) { 'PASS' } else { 'FAIL' }
    $LpColor = if ($LpPassed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} — {2}" -f $LpTag, $LpName, $LpDetail) -ForegroundColor $LpColor
}

function Read-LpLogLines {
    if (-not (Test-Path -LiteralPath $LpLog)) { return @() }
    $LpStream = [System.IO.File]::Open($LpLog, 'Open', 'Read', 'ReadWrite')
    try {
        $LpReader = New-Object System.IO.StreamReader($LpStream)
        return ($LpReader.ReadToEnd() -split "`r?`n")
    }
    finally {
        $LpReader.Dispose()
        $LpStream.Dispose()
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

function Save-LpToastArea {
    param([string]$LpPath)

    # 只截主屏右下角通知区，避免把无关桌面内容写进仓库。
    $LpBounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $LpW = 960
    $LpH = 420
    $LpX = $LpBounds.Right - $LpW
    $LpY = $LpBounds.Bottom - $LpH
    $LpBmp = New-Object System.Drawing.Bitmap $LpW, $LpH
    $LpGfx = [System.Drawing.Graphics]::FromImage($LpBmp)
    try {
        $LpGfx.CopyFromScreen($LpX, $LpY, 0, 0, $LpBmp.Size)
        $LpBmp.Save($LpPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $LpGfx.Dispose()
        $LpBmp.Dispose()
    }
}

$LpProxySnapshot = $null
$LpProxyServerSnapshot = $null
try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }

    # 先记录通知相关设置（只读），用于结论里说明是否可能被勿扰吞掉。
    $LpToastEnabled = $null
    $LpNotifSettings = Get-ItemProperty -LiteralPath $LpToastKey -ErrorAction SilentlyContinue
    if ($null -ne $LpNotifSettings -and $LpNotifSettings.PSObject.Properties.Name -contains 'NOC_GLOBAL_SETTING_TOASTS_ENABLED') {
        $LpToastEnabled = $LpNotifSettings.NOC_GLOBAL_SETTING_TOASTS_ENABLED
    }
    Add-LpCheck -LpName '记录通知开关（HKCU Notifications\Settings）' -LpPassed $true `
        -LpDetail ("NOC_GLOBAL_SETTING_TOASTS_ENABLED={0}" -f $(if ($null -ne $LpToastEnabled) { $LpToastEnabled } else { '（键不存在，按系统默认）' }))

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force

    $LpProxy = Get-ItemProperty -LiteralPath $LpProxyKey
    $LpProxySnapshot = [int]$LpProxy.ProxyEnable
    $LpProxyServerSnapshot = [string]$LpProxy.ProxyServer
    Set-ItemProperty -LiteralPath $LpProxyKey -Name ProxyEnable -Value 1 -Type DWord
    Set-ItemProperty -LiteralPath $LpProxyKey -Name ProxyServer -Value '127.0.0.1:9' -Type String
    Write-Host ("临时代理: ProxyEnable=1 ProxyServer=127.0.0.1:9（原 ProxyEnable={0}）" -f $LpProxySnapshot)

    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    $LpConfig.autoCheckUpdates = $true
    $LpConfig.updateCheckHours = 24
    $LpConfig.lastUpdateCheck = (Get-Date).AddHours(-25).ToString('O')
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

    Get-Process Findio.UI, Findio.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $LpServiceExe -ArgumentList '--console' | Out-Null

    $LpLogSeen = @(Read-LpLogLines).Count
    $LpApp = Start-Process -FilePath $LpExe -ArgumentList '--tray' -PassThru

    $LpDeadline = (Get-Date).AddSeconds(60)
    $LpBalloonLine = $null
    $LpFailureLine = $null
    while ((Get-Date) -lt $LpDeadline) {
        $LpNew = @(Read-LpLogLines | Select-Object -Skip $LpLogSeen)
        $LpHit = @($LpNew | Where-Object { $_ -match '托盘提示已提交: title="更新检查未完成"' })
        if ($LpHit.Count -gt 0) { $LpBalloonLine = $LpHit[-1].Trim(); break }
        $LpFail = @($LpNew | Where-Object { $_ -match '自动检查更新未完成' })
        if ($LpFail.Count -gt 0) { $LpFailureLine = $LpFail[-1].Trim() }
        if ($LpApp.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }

    # 气泡出现后立即截图（系统通知通常驻留 5 秒以上）。
    Start-Sleep -Milliseconds 400
    Save-LpToastArea -LpPath $LpShot

    Add-LpCheck -LpName '自动检查真实失败（网络不可达）' -LpPassed ($null -ne $LpFailureLine -or $null -ne $LpBalloonLine) `
        -LpDetail ("日志：{0}" -f $(if ($LpFailureLine) { $LpFailureLine } else { '（未捕获失败行，可能走缓存/代理未生效）' }))
    Add-LpCheck -LpName '托盘提示已提交且 Shell 返回 ok=True' -LpPassed ($null -ne $LpBalloonLine -and $LpBalloonLine -match 'ok=True') `
        -LpDetail ("日志：{0}" -f $(if ($LpBalloonLine) { $LpBalloonLine } else { '（超时未见托盘提示行）' }))
    Add-LpCheck -LpName '已截取气泡出现时的通知区截图' -LpPassed (Test-Path -LiteralPath $LpShot) `
        -LpDetail ("{0}（{1} 字节）" -f $LpShot, $(if (Test-Path -LiteralPath $LpShot) { (Get-Item -LiteralPath $LpShot).Length } else { 0 }))
}
catch {
    Add-LpCheck -LpName '执行过程无异常' -LpPassed $false -LpDetail $_.Exception.Message
}
finally {
    # 顺序要紧：先撤代理，避免任何残留影响其它应用联网。
    if ($null -ne $LpProxySnapshot) {
        Set-ItemProperty -LiteralPath $LpProxyKey -Name ProxyEnable -Value $LpProxySnapshot -Type DWord
        if ([string]::IsNullOrEmpty($LpProxyServerSnapshot)) {
            Remove-ItemProperty -LiteralPath $LpProxyKey -Name ProxyServer -ErrorAction SilentlyContinue
        }
        else {
            Set-ItemProperty -LiteralPath $LpProxyKey -Name ProxyServer -Value $LpProxyServerSnapshot -Type String
        }
    }
    Get-Process Findio.UI, Findio.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $LpConfigBackup) {
        Copy-Item -LiteralPath $LpConfigBackup -Destination $LpConfigPath -Force
        Remove-Item -LiteralPath $LpConfigBackup -Force
    }
}

$LpFailed = @($LpChecks | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("托盘失败气泡：{0}/{1} 通过" -f ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
