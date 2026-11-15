#Requires -Version 7.0
<#
.SYNOPSIS
    验证「始终以管理员身份运行」在真实用户入口（桌面快捷方式）下生效。

.DESCRIPTION
    前置：已在设置页开启开关（tools/ 之外用 UIA 开启，或手动开启），计划任务已注册。
    本脚本只建一个桌面快捷方式并用 explorer 打开它（等价双击），不调用 schtasks /Run；
    记录中转进程（标准权限）、提权进程（Full/High）与任务上次运行时间，证明触发链是：
    快捷方式 → 中转实例（explorer 启动）→ schtasks /Run → 任务计划服务（svchost）→ 提权实例。
    结束后用 schtasks /End 收尾并删除测试快捷方式。

.EXAMPLE
    pwsh -NoProfile -File tools/Test-LpElevationEntry.ps1
#>
[CmdletBinding()]
param(
    [string]$LpExe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LpExe)) {
    $LpExe = Join-Path $PSScriptRoot '..\src\Findio.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Findio.UI.exe'
}
$LpExe = (Resolve-Path -LiteralPath $LpExe).Path
$LpTaskName = "Findio-Elevated-$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
$LpLogRoot = Join-Path $env:LOCALAPPDATA 'Findio\logs'
$LpShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Findio-提权入口测试.lnk'
$LpSampleFile = Join-Path $env:TEMP 'lp-entry-samples.txt'

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LpEntryToken
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int cls, IntPtr info, int len, out int ret);
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool ConvertSidToStringSid(IntPtr sid, out IntPtr str);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr ptr);

    private static int ReadInt(IntPtr token, int cls)
    {
        IntPtr buf = Marshal.AllocHGlobal(4);
        try
        {
            if (!GetTokenInformation(token, cls, buf, 4, out _)) { return -1; }
            return Marshal.ReadInt32(buf);
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    private static string ReadSid(IntPtr token, int cls)
    {
        GetTokenInformation(token, cls, IntPtr.Zero, 0, out int size);
        IntPtr buf = Marshal.AllocHGlobal(size);
        try
        {
            if (!GetTokenInformation(token, cls, buf, size, out _)) { return "?"; }
            IntPtr sid = Marshal.ReadIntPtr(buf);
            if (!ConvertSidToStringSid(sid, out IntPtr str)) { return "?"; }
            try { return Marshal.PtrToStringUni(str) ?? "?"; }
            finally { LocalFree(str); }
        }
        finally { Marshal.FreeHGlobal(buf); }
    }

    public static string Describe(int pid)
    {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) { return "open_process_failed=" + Marshal.GetLastWin32Error(); }
        try
        {
            if (!OpenProcessToken(process, 0x0008, out IntPtr token)) { return "open_token_failed=" + Marshal.GetLastWin32Error(); }
            try
            {
                return string.Format("elevation={0};type={1};integrity={2};virtualization={3}",
                    ReadInt(token, 20), ReadInt(token, 18), ReadSid(token, 25), ReadInt(token, 24));
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@

$LpResults = [System.Collections.Generic.List[object]]::new()
function Add-LpCheck {
    param([string]$LpName, [bool]$LpPassed, [string]$LpDetail)
    $LpResults.Add([pscustomobject]@{ Name = $LpName; Passed = $LpPassed; Detail = $LpDetail })
}

function Get-LpParentName {
    param([int]$LpParentPid)
    $LpParent = Get-CimInstance Win32_Process -Filter "ProcessId = $LpParentPid" -ErrorAction SilentlyContinue
    if ($null -eq $LpParent) { return "pid=$LpParentPid(已退出)" }
    return "$($LpParent.Name)(pid=$LpParentPid)"
}

function Get-LpTaskField {
    param([string]$LpText, [string]$LpName)
    $LpMatch = [regex]::Match($LpText, "(?m)^$([regex]::Escape($LpName)):\s*(.+?)\s*$")
    if ($LpMatch.Success) { return $LpMatch.Groups[1].Value } else { return '' }
}

if (-not (Test-Path -LiteralPath $LpExe)) { throw "找不到 $LpExe" }
schtasks.exe /Query /TN $LpTaskName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw '计划任务未注册：先开启设置页「始终以管理员身份运行」再跑本脚本' }

$LpSampler = $null
try {
    Get-Process Findio.UI -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
    Start-Sleep -Milliseconds 600

    $LpShell = New-Object -ComObject WScript.Shell
    $LpLink = $LpShell.CreateShortcut($LpShortcut)
    $LpLink.TargetPath = $LpExe
    $LpLink.WorkingDirectory = Split-Path -Parent $LpExe
    $LpLink.Description = 'Findio 提权入口验证'
    $LpLink.Save()

    $LpLogFile = Get-ChildItem -LiteralPath $LpLogRoot -Filter 'ui-*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    $LpLogOffset = if ($null -ne $LpLogFile) { (Get-Item -LiteralPath $LpLogFile.FullName).Length } else { 0 }

    # 中转进程只活几百毫秒，主线程用 20ms 采样另起一个线程记录 pid/父进程/命令行。
    if (Test-Path -LiteralPath $LpSampleFile) { Remove-Item -LiteralPath $LpSampleFile -Force }
    $LpSampler = Start-ThreadJob -ArgumentList $LpSampleFile -ScriptBlock {
        param($LpFile)
        $LpSeen = @{}
        $LpEnd = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $LpEnd) {
            foreach ($LpRow in Get-CimInstance Win32_Process -Filter "Name='Findio.UI.exe'" -ErrorAction SilentlyContinue) {
                if (-not $LpSeen.ContainsKey($LpRow.ProcessId)) {
                    $LpSeen[$LpRow.ProcessId] = $true
                    "{0}`t{1}`t{2}" -f $LpRow.ProcessId, $LpRow.ParentProcessId, $LpRow.CommandLine | Add-Content -LiteralPath $LpFile
                }
            }
            Start-Sleep -Milliseconds 20
        }
    }

    $LpKnown = @(Get-Process Findio.UI -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)
    $LpLaunchAt = Get-Date
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$LpShortcut`""

    $LpElevated = $null
    $LpObserved = @{}
    $LpDeadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $LpDeadline -and $null -eq $LpElevated) {
        foreach ($LpProc in @(Get-Process Findio.UI -ErrorAction SilentlyContinue | Where-Object { $LpKnown -notcontains $_.Id })) {
            if (-not $LpObserved.ContainsKey($LpProc.Id)) {
                $LpObserved[$LpProc.Id] = [LpEntryToken]::Describe($LpProc.Id)
            }
            if ($LpObserved[$LpProc.Id] -like '*elevation=1*' -and $null -eq $LpElevated) {
                $LpElevated = [pscustomobject]@{ Pid = $LpProc.Id; Info = $LpObserved[$LpProc.Id] }
            }
        }
        if ($null -eq $LpElevated) { Start-Sleep -Milliseconds 50 }
    }
    Start-Sleep -Seconds 1

    $LpSamples = @()
    if (Test-Path -LiteralPath $LpSampleFile) {
        $LpSamples = @(Get-Content -LiteralPath $LpSampleFile | ForEach-Object {
                $LpParts = $_ -split "`t"
                [pscustomobject]@{ Pid = [int]$LpParts[0]; ParentPid = [int]$LpParts[1]; CommandLine = $LpParts[2] }
            })
    }
    $LpMedium = $LpSamples | Where-Object { $_.Pid -ne $LpElevated.Pid } | Select-Object -First 1
    $LpMediumInfo = if ($LpMedium -and $LpObserved.ContainsKey($LpMedium.Pid)) { $LpObserved[$LpMedium.Pid] } else { '未捕获' }
    $LpMediumAlive = if ($LpMedium) { $null -ne (Get-Process -Id $LpMedium.Pid -ErrorAction SilentlyContinue) } else { $false }

    $LpTaskAfter = (schtasks.exe /Query /TN $LpTaskName /FO LIST /V 2>$null | Out-String)
    $LpLogText = ''
    if ($null -ne $LpLogFile) {
        $LpStream = [System.IO.File]::Open($LpLogFile.FullName, 'Open', 'Read', 'ReadWrite')
        try {
            $LpStream.Seek($LpLogOffset, 'Begin') | Out-Null
            $LpLogText = (New-Object System.IO.StreamReader($LpStream)).ReadToEnd()
        }
        finally { $LpStream.Dispose() }
    }

    $LpLastRun = Get-LpTaskField -LpText $LpTaskAfter -LpName 'Last Run Time'
    if ($LpLastRun -eq '') { $LpLastRun = Get-LpTaskField -LpText $LpTaskAfter -LpName '上次运行时间' }
    $LpLastResult = Get-LpTaskField -LpText $LpTaskAfter -LpName 'Last Result'
    if ($LpLastResult -eq '') { $LpLastResult = Get-LpTaskField -LpText $LpTaskAfter -LpName '上次结果' }
    $LpLastRunTime = [datetime]::MinValue
    if (-not [datetime]::TryParse($LpLastRun, [ref]$LpLastRunTime)) { $LpLastRunTime = [datetime]::MinValue }
    $LpTaskRanNow = $LpLastRunTime -ne [datetime]::MinValue -and [Math]::Abs(($LpLastRunTime - $LpLaunchAt).TotalSeconds) -le 10

    $LpElevatedProc = if ($LpElevated) { Get-CimInstance Win32_Process -Filter "ProcessId = $($LpElevated.Pid)" -ErrorAction SilentlyContinue } else { $null }

    Add-LpCheck -LpName '快捷方式存在且指向当前 exe' -LpPassed ((Test-Path -LiteralPath $LpShortcut) -and ((New-Object -ComObject WScript.Shell).CreateShortcut($LpShortcut).TargetPath -eq $LpExe)) -LpDetail $LpShortcut
    Add-LpCheck -LpName '中转进程为标准权限（Medium/Limited）' -LpPassed ($null -ne $LpMedium -and $LpMediumInfo -like '*elevation=0*' -and $LpMediumInfo -like '*integrity=S-1-16-8192*') -LpDetail ($(if ($LpMedium) { "pid=$($LpMedium.Pid) $LpMediumInfo cmd=[$($LpMedium.CommandLine)]" } else { '未捕获' }))
    Add-LpCheck -LpName '中转进程由资源管理器启动' -LpPassed ($null -ne $LpMedium -and (Get-LpParentName -LpParentPid $LpMedium.ParentPid) -like 'explorer*') -LpDetail ($(if ($LpMedium) { "parent=$(Get-LpParentName -LpParentPid $LpMedium.ParentPid)" } else { '未捕获' }))
    Add-LpCheck -LpName '中转进程启动后自行退出' -LpPassed ($null -ne $LpMedium -and -not $LpMediumAlive) -LpDetail ("alive={0}" -f $LpMediumAlive)
    Add-LpCheck -LpName '出现提权实例（Full/High）' -LpPassed ($null -ne $LpElevated -and $LpElevated.Info -like '*type=2*' -and $LpElevated.Info -like '*integrity=S-1-16-12288*') -LpDetail ($(if ($LpElevated) { "pid=$($LpElevated.Pid) $($LpElevated.Info)" } else { '未捕获' }))
    Add-LpCheck -LpName '提权实例由任务计划服务拉起' -LpPassed ($null -ne $LpElevatedProc -and (Get-LpParentName -LpParentPid $LpElevatedProc.ParentProcessId) -like 'svchost*') -LpDetail ($(if ($LpElevatedProc) { "$(Get-LpParentName -LpParentPid $LpElevatedProc.ParentProcessId)（命令行跨完整性级别不可读，args 见日志）" } else { '未捕获' }))
    Add-LpCheck -LpName '中转进程日志说明走计划任务重启' -LpPassed ($LpLogText -like '*已通过计划任务以管理员身份重新启动*') -LpDetail (@($LpLogText -split "`r?`n" | Where-Object { $_ -like '*计划任务*' }) -join ' / ')
    Add-LpCheck -LpName '这次任务运行由本次启动触发' -LpPassed $LpTaskRanNow -LpDetail ("Last Run Time=$LpLastRun; 启动时间=$($LpLaunchAt.ToString('yyyy/MM/dd HH:mm:ss')); Last Result=$LpLastResult")

    Write-Host "任务=$LpTaskName"
    if ($LpMedium) { Write-Host "中转: pid=$($LpMedium.Pid) parent=$(Get-LpParentName -LpParentPid $LpMedium.ParentPid) $LpMediumInfo" }
    if ($LpElevated) { Write-Host "提权: pid=$($LpElevated.Pid) parent=$(if ($LpElevatedProc) { Get-LpParentName -LpParentPid $LpElevatedProc.ParentProcessId }) $($LpElevated.Info)" }
    Write-Host '--- 本次新增日志（节选）---'
    Write-Host (@($LpLogText -split "`r?`n" | Where-Object { $_ -match '启动，PID|计划任务|恢复提权前|单实例' }) -join "`n")
}
finally {
    if ($null -ne $LpSampler) {
        Stop-Job -Job $LpSampler -ErrorAction SilentlyContinue
        Remove-Job -Job $LpSampler -Force -ErrorAction SilentlyContinue
    }

    # 任务服务拉起的实例，普通权限 Kill 不掉，先让任务结束。
    schtasks.exe /End /TN $LpTaskName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Get-Process Findio.UI -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
    if (Test-Path -LiteralPath $LpShortcut) { Remove-Item -LiteralPath $LpShortcut -Force }
}

$LpFailed = @($LpResults | Where-Object { -not $_.Passed })
foreach ($LpResult in $LpResults) {
    $LpTag = if ($LpResult.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}  {2}" -f $LpTag, $LpResult.Name, $LpResult.Detail) -ForegroundColor $(if ($LpResult.Passed) { 'Green' } else { 'Red' })
}
if ($LpFailed.Count -gt 0) { throw "真实入口验证未通过：$($LpFailed.Count)/$($LpResults.Count)" }
Write-Host "真实入口验证通过：$($LpResults.Count)/$($LpResults.Count)" -ForegroundColor Green
