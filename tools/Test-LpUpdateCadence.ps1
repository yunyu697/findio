#Requires -Version 7.0
<#
.SYNOPSIS
  自动检查更新「是否真按设置触发」验收：只改 config.json 的 lastUpdateCheck / updateCheckHours /
  autoCheckUpdates，重启 UI 后读日志，逐档核对跳过与触发，并检查 lastUpdateCheck 是否被写回。
.DESCRIPTION
  历史结论来自代码推断（ReadRunAutoUpdateCheckAsync），没有实跑。本脚本用真实启动路径（UI 进程
  启动即调用 RunAutoUpdateCheckAsync）验五档：
    A 每天、距上次 25h → 应当触发检查，并把 lastUpdateCheck 写回当前时间；
    B 每天、距上次 1h  → 应当跳过，且 lastUpdateCheck 不变；
    C 每周、距上次 30h → 应当按 168h 跳过（证明不是恒按 24h 判定）；
    D 仅手动（hours=0，开关仍开）→ 应当走「已关闭」；
    E 开关关闭（autoCheckUpdates=false）→ 应当走「已关闭」。
  全程不显示主窗、不注入输入，可在锁屏时运行。
.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpUpdateCadence.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Pathleap.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Pathleap.UI.exe'
$LpServiceExe = Join-Path $LpRepo 'src\Pathleap.Service\bin\x64\Debug\net8.0-windows\Pathleap.Service.exe'
$LpLog = Join-Path $env:LOCALAPPDATA ('Pathleap\logs\ui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Pathleap\config.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-update-cadence-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))

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

function Set-LpConfigField {
    param([hashtable]$LpValues)

    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    foreach ($LpKey in $LpValues.Keys) {
        $LpConfig | Add-Member -NotePropertyName $LpKey -NotePropertyValue $LpValues[$LpKey] -Force
    }
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8
    return $LpConfig
}

function Get-LpLastCheck {
    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    return [string]$LpConfig.lastUpdateCheck
}

# 启动一次 UI（--tray，不显示窗口），收集启动后新增日志，等到匹配行或超时。
function Invoke-LpStartupCase {
    param(
        [hashtable]$LpConfigValues,
        [string]$LpLogPattern,
        [int]$LpTimeoutSec = 20
    )

    Get-Process Pathleap.UI -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    Set-LpConfigField -LpValues $LpConfigValues | Out-Null
    $LpBeforeCheck = Get-LpLastCheck
    $LpLogSeen = @(Read-LpLogLines).Count

    $LpApp = Start-Process -FilePath $LpExe -ArgumentList '--tray' -PassThru
    $LpDeadline = (Get-Date).AddSeconds($LpTimeoutSec)
    $LpMatched = $null
    while ((Get-Date) -lt $LpDeadline) {
        $LpNew = @(Read-LpLogLines | Select-Object -Skip $LpLogSeen)
        $LpHit = @($LpNew | Where-Object { $_ -match $LpLogPattern })
        if ($LpHit.Count -gt 0) { $LpMatched = $LpHit[-1].Trim(); break }
        if ($LpApp.HasExited) { break }
        Start-Sleep -Milliseconds 300
    }

    $LpAfterCheck = Get-LpLastCheck
    Get-Process Pathleap.UI -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 400

    return [pscustomobject]@{
        Matched      = $LpMatched
        BeforeCheck  = $LpBeforeCheck
        AfterCheck   = $LpAfterCheck
        Exited       = $LpApp.HasExited
    }
}

try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force
    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    Start-Process -FilePath $LpServiceExe -ArgumentList '--console' | Out-Null

    $LpNow = Get-Date

    # A 每天 + 距上次 25h：应当触发（网络结果不计入判定），并写回 lastUpdateCheck。
    $LpA = Invoke-LpStartupCase -LpConfigValues @{
        autoCheckUpdates = $true
        updateCheckHours = 24
        lastUpdateCheck  = $LpNow.AddHours(-25).ToString('O')
    } -LpLogPattern '自动检查更新(:|发现|失败|未完成)' -LpTimeoutSec 45
    $LpAChanged = $false
    try {
        $LpAChanged = ([DateTimeOffset]::Parse($LpA.AfterCheck) -gt $LpNow.AddMinutes(-2))
    }
    catch { $LpAChanged = $false }
    Add-LpCheck -LpName 'A 每天/已过 25h → 到点触发' -LpPassed ($null -ne $LpA.Matched) `
        -LpDetail ("日志：{0}" -f $(if ($LpA.Matched) { $LpA.Matched } else { '（超时未见自动检查更新行）' }))
    Add-LpCheck -LpName 'A 触发后写回 lastUpdateCheck' -LpPassed $LpAChanged `
        -LpDetail ("before={0} after={1}" -f $LpA.BeforeCheck, $LpA.AfterCheck)

    # B 每天 + 距上次 1h：应当跳过且不写回。
    $LpB = Invoke-LpStartupCase -LpConfigValues @{
        autoCheckUpdates = $true
        updateCheckHours = 24
        lastUpdateCheck  = $LpNow.AddHours(-1).ToString('O')
    } -LpLogPattern '距上次检查更新未满 24 小时，跳过' -LpTimeoutSec 15
    Add-LpCheck -LpName 'B 每天/仅过 1h → 跳过' -LpPassed ($null -ne $LpB.Matched) `
        -LpDetail ("日志：{0}" -f $(if ($LpB.Matched) { $LpB.Matched } else { '（超时未见跳过行）' }))
    Add-LpCheck -LpName 'B 跳过时不改写 lastUpdateCheck' -LpPassed ($LpB.BeforeCheck -eq $LpB.AfterCheck) `
        -LpDetail ("before={0} after={1}" -f $LpB.BeforeCheck, $LpB.AfterCheck)

    # C 每周 + 距上次 30h：按 168h 判定，应当跳过（若恒用 24h 会误触发）。
    $LpC = Invoke-LpStartupCase -LpConfigValues @{
        autoCheckUpdates = $true
        updateCheckHours = 168
        lastUpdateCheck  = $LpNow.AddHours(-30).ToString('O')
    } -LpLogPattern '距上次检查更新未满 168 小时，跳过' -LpTimeoutSec 15
    Add-LpCheck -LpName 'C 每周/过 30h → 仍跳过（按 168h 判定）' -LpPassed ($null -ne $LpC.Matched) `
        -LpDetail ("日志：{0}" -f $(if ($LpC.Matched) { $LpC.Matched } else { '（超时未见 168 小时跳过行）' }))

    # D 仅手动（hours=0，开关保持开）：应当走「已关闭」。
    $LpD = Invoke-LpStartupCase -LpConfigValues @{
        autoCheckUpdates = $true
        updateCheckHours = 0
        lastUpdateCheck  = $LpNow.AddHours(-30).ToString('O')
    } -LpLogPattern '自动检查更新已关闭' -LpTimeoutSec 15
    Add-LpCheck -LpName 'D 仅手动（hours=0）→ 已关闭' -LpPassed ($null -ne $LpD.Matched) `
        -LpDetail ("日志：{0}" -f $(if ($LpD.Matched) { $LpD.Matched } else { '（超时未见已关闭行）' }))

    # E 开关关闭：应当走「已关闭」，即使已过 24h。
    $LpE = Invoke-LpStartupCase -LpConfigValues @{
        autoCheckUpdates = $false
        updateCheckHours = 24
        lastUpdateCheck  = $LpNow.AddHours(-30).ToString('O')
    } -LpLogPattern '自动检查更新已关闭' -LpTimeoutSec 15
    Add-LpCheck -LpName 'E 开关关闭 → 已关闭' -LpPassed ($null -ne $LpE.Matched) `
        -LpDetail ("日志：{0}" -f $(if ($LpE.Matched) { $LpE.Matched } else { '（超时未见已关闭行）' }))
}
catch {
    Add-LpCheck -LpName '执行过程无异常' -LpPassed $false -LpDetail $_.Exception.Message
}
finally {
    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $LpConfigBackup) {
        Copy-Item -LiteralPath $LpConfigBackup -Destination $LpConfigPath -Force
        Remove-Item -LiteralPath $LpConfigBackup -Force
    }
}

$LpFailed = @($LpChecks | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("自动检查更新频率：{0}/{1} 通过" -f ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
