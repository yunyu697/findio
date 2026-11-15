#Requires -Version 7.0
<#
.SYNOPSIS
  实测开启「始终以管理员身份运行」后，从正常入口启动的进程是否真的处于高完整性级别。
.DESCRIPTION
  以当前构建启动 Pathleap.UI.exe，等待目标完整性级别的新进程，读取进程令牌：
  TokenElevation / TokenElevationType / TokenIntegrityLevel / TokenVirtualizationEnabled。
  -LpPhase on  期望 High（S-1-16-12288）+ Full + elevation=1；
  -LpPhase off 期望 Medium（S-1-16-8192）+ 非提权。
  前置条件：先用设置页开关切到对应状态（或已有计划任务）。本机若
  ConsentPromptBehaviorAdmin=0，提权是静默的，不弹 UAC 不代表没提权。
.EXAMPLE
  pwsh -File tools\Test-LpElevationIntegrity.ps1 -LpPhase on
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('on', 'off')]
    [string]$LpPhase,

    [string]$LpExe = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LpExe)) {
    $LpRepoRoot = Split-Path -Parent $PSScriptRoot
    $LpExe = Join-Path $LpRepoRoot 'src\Pathleap.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Pathleap.UI.exe'
}

if (-not (Test-Path -LiteralPath $LpExe)) { throw "找不到 $LpExe" }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LpTokenProbe
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
        IntPtr process = OpenProcess(0x1000, false, pid); // PROCESS_QUERY_LIMITED_INFORMATION
        if (process == IntPtr.Zero) { return "open_process_failed=" + Marshal.GetLastWin32Error(); }
        try
        {
            if (!OpenProcessToken(process, 0x0008, out IntPtr token)) { return "open_token_failed=" + Marshal.GetLastWin32Error(); }
            try
            {
                int elevation = ReadInt(token, 20);
                int elevationType = ReadInt(token, 18);
                int virtualization = ReadInt(token, 24);
                string integrity = ReadSid(token, 25);
                return string.Format("elevation={0};type={1};integrity={2};virtualization={3}", elevation, elevationType, integrity, virtualization);
            }
            finally { CloseHandle(token); }
        }
        finally { CloseHandle(process); }
    }
}
'@

$LpBefore = @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Id)

Write-Host ("UAC 策略: " + ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' |
            Select-Object EnableLUA, ConsentPromptBehaviorAdmin, PromptOnSecureDesktop) | ConvertTo-Json -Compress))

$LpStart = Get-Date
Start-Process -FilePath $LpExe

$LpWanted = if ($LpPhase -eq 'on') { 'S-1-16-12288' } else { 'S-1-16-8192' }
$LpTarget = $null
$LpDescription = ''
$LpLast = ''
for ($LpIndex = 0; $LpIndex -lt 50; $LpIndex++) {
    Start-Sleep -Milliseconds 500
    $LpCandidates = @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue |
            Where-Object { $LpBefore -notcontains $_.Id -and $_.StartTime -gt $LpStart.AddSeconds(-2) })
    foreach ($LpCandidate in $LpCandidates) {
        $LpProbe = [LpTokenProbe]::Describe($LpCandidate.Id)
        $LpLast = "pid=$($LpCandidate.Id) $LpProbe"
        if ($LpProbe -like "*integrity=$LpWanted*") {
            $LpTarget = $LpCandidate
            $LpDescription = $LpProbe
            break
        }
    }

    if ($LpTarget) { break }
}

if (-not $LpTarget) {
    Write-Host "[FAIL] 未观察到目标完整性级别，最后探针: $LpLast" -ForegroundColor Red
    Get-Process Pathleap.UI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    exit 1
}

$LpParent = (Get-CimInstance Win32_Process -Filter "ProcessId=$($LpTarget.Id)" |
        Select-Object -ExpandProperty ParentProcessId -ErrorAction SilentlyContinue)
$LpParentName = if ($LpParent) {
    (Get-Process -Id $LpParent -ErrorAction SilentlyContinue).ProcessName
}
else { '?' }

Write-Host "目标进程: pid=$($LpTarget.Id) 父进程=$LpParentName($LpParent)"
Write-Host "令牌探测: $LpDescription"

$LpOk = if ($LpPhase -eq 'on') {
    $LpDescription -like '*elevation=1*' -and $LpDescription -like '*type=2*' -and $LpDescription -like '*integrity=S-1-16-12288*'
}
else {
    $LpDescription -like '*elevation=0*' -and $LpDescription -like '*integrity=S-1-16-8192*'
}

Get-Process Pathleap.UI -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $LpOk) {
    Write-Host '[FAIL] 完整性级别/提权类型与预期不符' -ForegroundColor Red
    exit 1
}

Write-Host "[PASS] $LpPhase 阶段完整性级别符合预期" -ForegroundColor Green
exit 0
