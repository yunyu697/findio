#Requires -Version 7.0
<#
.SYNOPSIS
  快速切换栏数字键「真实按键」验收：打开 6 个真实资源管理器窗口 → 拉起 Pathleap.UI（托盘）→
  拉起真实 #32770 文件对话框 → 送 Ctrl+G 打开快速切换栏 → 用 SendInput 按数字键 1–6，
  读日志里的注入结果，核对每个数字都命中一个互不相同的文件夹，且都来自这 6 个已打开窗口。

.DESCRIPTION
  这项是「唯一降级项」的补测：以前只验证了搜索框键入与代码路径，没有走真实键盘数字键。
  判定口径：
    1. 快速切换栏挂到对话框（日志「快速切换栏已挂到对话框」），且贴边行数 folders=6；
    2. Ctrl+G 后栏取得前台（键盘焦点），6 轮都成立；
    3. 6 个数字各产生一次「文件对话框注入已发送」，且第 i 个数字注入的 path 等于栏当日志
       「快速切换栏文件夹: ...」里的第 i 项（顺序一一对应、互不重复）；
    4. 每个注入路径都是本轮已打开的资源管理器窗口之一（不是凭空造出来的路径）。
  说明：键盘拦截允许 SendInput 注入事件（代码里 isInjected 不参与判断），这是自动化能做的
  「真实按键」上限；不直接调用 Pick，也不写文件名编辑框。
  热键与数字都走 SendInput。本脚本旧版用 PowerShell 直接改 `INPUT.U.ki`，值类型字段赋值只改了副本，
  送出的全是 vk=0 的空事件（SendInput 仍返回成功），于是「数字键无反应」被误判成产品缺陷与
  「SendInput 触发不了 RegisterHotKey」；现在事件在 C# 里构造，见下方 Fill/SendKey/SendChord。
  测试期间临时把 onboardingDone 置 true：首次引导会把文件夹列表换成三步说明，而数字直选只在
  列表可见时生效。脚本结束（含异常）恢复原 config.json。

.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpQuickSwitchKeys.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Pathleap.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Pathleap.UI.exe'
$LpHost = Join-Path $env:TEMP 'pathleap-scaling\DialogHost.exe'
$LpLog = Join-Path $env:LOCALAPPDATA ('Pathleap\logs\ui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$LpRoot = Join-Path $env:TEMP ('lp-qs-keys-{0}' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$LpDialogTitle = '打开（Pathleap 验收）'
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Pathleap\config.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-qs-keys-config-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))

Add-Type -Namespace 'LpKeys' -Name 'Native' -MemberDefinition @'
    public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool EnumWindows(LpKeys.Native.EnumProc cb, System.IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindowVisible(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder sb, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern int GetClassNameW(System.IntPtr hWnd, System.Text.StringBuilder sb, int n);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool BringWindowToTop(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint code, uint mapType);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);

    [DllImport("user32.dll")]
    public static extern bool PostMessageW(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr after, int x, int y, int cx, int cy, uint flags);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct INPUT { public uint type; public InputUnion U; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit)]
    public struct InputUnion {
        [System.Runtime.InteropServices.FieldOffset(0)] public MOUSEINPUT mi;
        [System.Runtime.InteropServices.FieldOffset(0)] public KEYBDINPUT ki;
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }

    // 必须在这里（C#）构造事件：PowerShell 里 `$x.U.ki.wVk = ...` 改的是值类型字段的副本，
    // 数组里的 INPUT 仍是 vk=0 的空事件——SendInput 会返回成功，但按什么都没发生。
    private static void Fill(INPUT[] a, int i, ushort vk, uint flags)
    {
        a[i].type = 1;
        a[i].U.ki.wVk = vk;
        a[i].U.ki.wScan = (ushort)MapVirtualKeyW(vk, 0);
        a[i].U.ki.dwFlags = flags;
    }

    public static uint SendKey(ushort vk)
    {
        var lpInputs = new INPUT[2];
        Fill(lpInputs, 0, vk, 0);
        Fill(lpInputs, 1, vk, 2);
        return SendInput(2, lpInputs, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint SendChord(ushort modifier, ushort vk)
    {
        var lpInputs = new INPUT[4];
        Fill(lpInputs, 0, modifier, 0);
        Fill(lpInputs, 1, vk, 0);
        Fill(lpInputs, 2, vk, 2);
        Fill(lpInputs, 3, modifier, 2);
        return SendInput(4, lpInputs, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    }
'@
[void][LpKeys.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))

function Send-LpKey {
    param([int[]]$LpKeys)
    foreach ($LpKey in $LpKeys) {
        $LpSent = [LpKeys.Native]::SendKey([uint16]$LpKey)
        if ($LpSent -ne 2) { throw ("SendInput 只送出 {0}/2（vk=0x{1}）" -f $LpSent, $LpKey.ToString('X')) }
    }
}

function Send-LpChord {
    param([int]$LpModifier, [int]$LpKey)
    $LpSent = [LpKeys.Native]::SendChord([uint16]$LpModifier, [uint16]$LpKey)
    if ($LpSent -ne 4) { throw ("SendInput 只送出 {0}/4（vk=0x{1}）" -f $LpSent, $LpKey.ToString('X')) }
}

function Set-LpForeground {
    param([IntPtr]$LpHwnd)
    if ([LpKeys.Native]::GetForegroundWindow() -eq $LpHwnd) { return $true }
    $LpFgTid = [uint32]0
    [void][LpKeys.Native]::GetWindowThreadProcessId([LpKeys.Native]::GetForegroundWindow(), [ref]$LpFgTid)
    $LpMyThread = [LpKeys.Native]::GetCurrentThreadId()
    [void][LpKeys.Native]::AttachThreadInput($LpMyThread, $LpFgTid, $true)
    [void][LpKeys.Native]::BringWindowToTop($LpHwnd)
    [void][LpKeys.Native]::SetForegroundWindow($LpHwnd)
    [void][LpKeys.Native]::AttachThreadInput($LpMyThread, $LpFgTid, $false)
    return ([LpKeys.Native]::GetForegroundWindow() -eq $LpHwnd)
}

function Find-LpDialog {
    param([int]$LpPid)
    $script:LpDialogHwnd = [IntPtr]::Zero
    $LpCb = [LpKeys.Native+EnumProc]{
        param($LpH, $LpL)
        if (-not [LpKeys.Native]::IsWindowVisible($LpH)) { return $true }
        $LpOwner = [uint32]0
        [void][LpKeys.Native]::GetWindowThreadProcessId($LpH, [ref]$LpOwner)
        if ($LpOwner -ne $LpPid) { return $true }
        $LpCls = [System.Text.StringBuilder]::new(64)
        [void][LpKeys.Native]::GetClassNameW($LpH, $LpCls, 64)
        if ($LpCls.ToString() -ne '#32770') { return $true }
        $LpT = [System.Text.StringBuilder]::new(256)
        [void][LpKeys.Native]::GetWindowTextW($LpH, $LpT, 256)
        if ($LpT.ToString() -like "*$LpDialogTitle*") { $script:LpDialogHwnd = $LpH; return $false }
        return $true
    }
    [void][LpKeys.Native]::EnumWindows($LpCb, [IntPtr]::Zero)
    return $script:LpDialogHwnd
}

function Get-LpWindowDesc {
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return '0x0' }
    $LpClass = New-Object System.Text.StringBuilder 256
    [void][LpKeys.Native]::GetClassNameW($Hwnd, $LpClass, 256)
    $LpTitle = New-Object System.Text.StringBuilder 256
    [void][LpKeys.Native]::GetWindowTextW($Hwnd, $LpTitle, 256)
    $LpOwnerPid = [uint32]0
    [void][LpKeys.Native]::GetWindowThreadProcessId($Hwnd, [ref]$LpOwnerPid)
    return ("0x{0:X} [{1}] '{2}' pid={3}" -f $Hwnd.ToInt64(), $LpClass.ToString(), $LpTitle.ToString(), $LpOwnerPid)
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

$LpChecks = [System.Collections.Generic.List[object]]::new()
function Add-LpCheck {
    param([string]$LpName, [bool]$LpPassed, [string]$LpDetail)
    $LpChecks.Add([pscustomobject]@{ Name = $LpName; Passed = $LpPassed; Detail = $LpDetail })
    $LpTag = if ($LpPassed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1} — {2}" -f $LpTag, $LpName, $LpDetail)
}

$LpDirs = @()
for ($LpI = 1; $LpI -le 6; $LpI++) { $LpDirs += (Join-Path $LpRoot ("d{0}" -f $LpI)) }
$LpApp = $null
$LpLogSeen = 0
$LpPicked = @{}

try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }
    if (-not (Test-Path -LiteralPath $LpHost)) { throw "缺少对话框宿主：$LpHost" }

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force
    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    $LpConfig.onboardingDone = $true
    $LpConfig.autoCheckUpdates = $false
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process DialogHost -ErrorAction SilentlyContinue | Stop-Process -Force

    foreach ($LpDir in $LpDirs) { New-Item -ItemType Directory -Force -Path $LpDir | Out-Null }
    # 先关掉历史运行遗留的 lp-* 资源管理器窗口：它们会留在快速切换栏的文件夹列表里，
    # 还会在中途把前台抢回去（实测每轮 Ctrl+G 后 ~0.5s 被旧窗口顶掉）。
    $LpShell = New-Object -ComObject Shell.Application
    foreach ($LpOld in @($LpShell.Windows())) {
        if ($LpOld.LocationURL -like '*lp-qs-keys-*' -or $LpOld.LocationURL -like '*lp-explore-probe*') {
            [void][LpKeys.Native]::PostMessageW([IntPtr]([int]$LpOld.HWND), 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
        }
    }
    Start-Sleep -Milliseconds 1000

    # 用 Shell.Application.Explore 打开：explorer.exe <dir> 在 Win11 上会并成标签页，
    # Shell.Application 只看到一个窗口（其余变成空白「此电脑」），栏里就只剩最近文件夹。
    foreach ($LpDir in $LpDirs) { $LpShell.Explore($LpDir) }

    $LpDeadline = (Get-Date).AddSeconds(20)
    $LpOpen = 0
    while ((Get-Date) -lt $LpDeadline) {
        $LpOpen = @($LpShell.Windows() | Where-Object { $_.LocationURL -like "*$([uri]::EscapeDataString((Split-Path $LpRoot -Leaf)))*" }).Count
        if ($LpOpen -ge 6) { break }
        Start-Sleep -Milliseconds 500
    }
    Add-LpCheck -LpName '打开 6 个真实资源管理器窗口' -LpPassed ($LpOpen -ge 6) -LpDetail ("Shell.Application 可见窗口 {0} 个（根目录 {1}）" -f $LpOpen, $LpRoot)
    # 栏取的是 Shell.Application 窗口列表的前 6 个（不是 z 序，置顶也改不了顺序），用户本来就有别的
    # 资源管理器窗口，所以不断言「命中的是本轮目录」，改为与栏自己记录的文件夹顺序逐项比对。
    # 刚开的资源管理器窗口还在初始化，一两秒后会自己抢一次前台，期间会把栏顶掉。
    Start-Sleep -Seconds 4

    $LpApp = Start-Process -FilePath $LpExe -ArgumentList '--tray' -PassThru
    Start-Sleep -Milliseconds 2500
    $LpLogSeen = (Read-LpLogLines).Count

    $LpDialogLogged = $false
    $LpFoldersSeen = -1
    $LpBarActiveRounds = 0
    $LpFolderOrder = @()
    $LpOpenPathsAtStart = @($LpShell.Windows() | ForEach-Object {
            try { ([uri]$_.LocationURL).LocalPath } catch { $null }
        } | Where-Object { $_ })
    for ($LpDigit = 1; $LpDigit -le 6; $LpDigit++) {
        $LpHostProc = Start-Process -FilePath $LpHost -PassThru
        $LpDlg = [IntPtr]::Zero
        $LpDeadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $LpDeadline) {
            $LpDlg = Find-LpDialog -LpPid $LpHostProc.Id
            if ($LpDlg -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 250
        }
        if ($LpDlg -eq [IntPtr]::Zero) { throw "第 $LpDigit 轮等不到文件对话框" }

        $LpOk = $false
        for ($LpTry = 0; $LpTry -lt 3 -and -not $LpOk; $LpTry++) {
            $LpOk = Set-LpForeground -LpHwnd $LpDlg
            if (-not $LpOk) { Start-Sleep -Milliseconds 300 }
        }
        Start-Sleep -Milliseconds 300
        $LpRoundAt = Get-Date
        Send-LpChord -LpModifier 0x11 -LpKey 0x47
        Start-Sleep -Milliseconds 700
        $LpFgBar = [LpKeys.Native]::GetForegroundWindow()
        $LpFgPid = [uint32]0
        [void][LpKeys.Native]::GetWindowThreadProcessId($LpFgBar, [ref]$LpFgPid)
        $LpBarActive = ($LpFgPid -eq $LpApp.Id)
        if ($LpBarActive) { $LpBarActiveRounds++ }

        $LpLines = @(Read-LpLogLines)
        $LpSince = $LpRoundAt.ToString('yyyy-MM-ddTHH:mm:ss')
        $LpNew = @($LpLines | Where-Object { $_.Length -ge 19 -and [string]::CompareOrdinal($_.Substring(0, 19), $LpSince) -ge 0 })
        foreach ($LpLine in $LpNew) {
            if ($LpLine -like '*快速切换栏已挂到对话框*') { $LpDialogLogged = $true }
            if ($LpLine -match 'folders=(\d+)') { $LpFoldersSeen = [int]$Matches[1] }
            if ($LpLine -match '快速切换栏文件夹: (.+)$') { $LpFolderOrder = @($Matches[1].Split(' | ')) }
        }

        $LpFgBefore = [LpKeys.Native]::GetForegroundWindow()
        $LpInjected = ''
        if ($LpFgBefore -eq $LpDlg -or $LpFgBefore -eq $LpFgBar -or $LpFgBar -eq $LpDlg) {
            Send-LpKey -LpKeys @(0x30 + $LpDigit)
        }
        else {
            $LpInjected = '跳过：前台被其它窗口占用'
        }
        # 注入成功后对话框会关闭；最多等 3 秒拿注入日志
        $LpDeadline = (Get-Date).AddSeconds(3)
        while ((Get-Date) -lt $LpDeadline -and $LpInjected -eq '') {
            Start-Sleep -Milliseconds 250
            foreach ($LpLine in @(Read-LpLogLines)) {
                if ($LpLine.Length -lt 19 -or [string]::CompareOrdinal($LpLine.Substring(0, 19), $LpSince) -lt 0) { continue }
                if ($LpLine -match '文件对话框注入已发送: kind=\S+ path=(.+?) edit=') { $LpInjected = $Matches[1].Trim() }
                if ($LpLine -match '文件对话框注入失败') { $LpInjected = '失败：' + $LpLine.Trim() }
            }
        }

        $LpPicked[$LpDigit] = $LpInjected
        $LpState = if ($LpOk) { '对话框前台' } else { "对话框未取得前台（当前 0x$($LpFgBefore.ToInt64().ToString('X'))）" }
        $LpBarState = if ($LpBarActive) { '栏已取得前台' } else { "栏未取得前台（当前 $(Get-LpWindowDesc -Hwnd $LpFgBar)）" }
        $LpKeyTarget = if ($LpFgBefore -eq $LpDlg) { '对话框' } elseif ($LpFgBefore -eq $LpFgBar) { '栏' } else { "其它：$(Get-LpWindowDesc -Hwnd $LpFgBefore)" }
        Write-Host ("  第 {0} 轮：{1}；{2}；按键目标={3}；注入={4}" -f $LpDigit, $LpState, $LpBarState, $LpKeyTarget, $(if ($LpInjected -eq '') { '（无）' } else { $LpInjected }))

        Get-Process -Id $LpHostProc.Id -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 500
    }

    Add-LpCheck -LpName '快速切换栏挂到真实文件对话框' -LpPassed $LpDialogLogged -LpDetail '日志出现「快速切换栏已挂到对话框」'
    Add-LpCheck -LpName '快速切换栏列出 6 个文件夹' -LpPassed ($LpFoldersSeen -eq 6) -LpDetail ("日志 folders={0}" -f $LpFoldersSeen)
    Add-LpCheck -LpName 'Ctrl+G 后栏取得前台（键盘焦点）' -LpPassed ($LpBarActiveRounds -eq 6) -LpDetail ("{0}/6 轮前台进程是 Pathleap.UI" -f $LpBarActiveRounds)

    $LpValues = @($LpPicked.Values | Where-Object { $_ -ne '' -and $_ -notlike '失败*' -and $_ -notlike '跳过*' })
    $LpDistinct = @($LpValues | Sort-Object -Unique)
    $LpMapped = $true
    $LpMapDetail = @()
    for ($LpI = 1; $LpI -le 6; $LpI++) {
        $LpWant = if ($LpFolderOrder.Count -ge $LpI) { $LpFolderOrder[$LpI - 1] } else { '' }
        $LpGot = [string]$LpPicked[$LpI]
        if ($LpWant -eq '' -or $LpGot -ne $LpWant) { $LpMapped = $false }
        $LpMapDetail += ("{0}:期望 {1} / 实际 {2}" -f $LpI, $(if ($LpWant -eq '') { '（无）' } else { $LpWant }), $(if ($LpGot -eq '') { '（无）' } else { $LpGot }))
    }
    $LpNotOpen = @($LpValues | Where-Object { $LpOpenPathsAtStart -notcontains $_ }).Count -eq 0
    Add-LpCheck -LpName '6 个数字键都产生了注入结果' -LpPassed ($LpValues.Count -eq 6) -LpDetail ("有效注入 {0}/6：{1}" -f $LpValues.Count, (($LpPicked.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)→$(if ($_.Value -eq '') { '无' } else { $_.Value })" }) -join '；'))
    Add-LpCheck -LpName '数字与栏列出的文件夹一一对应' -LpPassed $LpMapped -LpDetail ("去重后 {0} 个；{1}" -f $LpDistinct.Count, ($LpMapDetail -join '；'))
    Add-LpCheck -LpName '每个注入路径都来自已打开的资源管理器窗口' -LpPassed $LpNotOpen -LpDetail ("不属于本轮已打开窗口的 {0} 个" -f @($LpValues | Where-Object { $LpOpenPathsAtStart -notcontains $_ }).Count)
}
catch {
    Add-LpCheck -LpName '执行过程无异常' -LpPassed $false -LpDetail $_.Exception.Message
}
finally {
    Get-Process DialogHost -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $LpConfigBackup) {
        Copy-Item -LiteralPath $LpConfigBackup -Destination $LpConfigPath -Force
        Remove-Item -LiteralPath $LpConfigBackup -Force
    }
    try {
        $LpShellClean = New-Object -ComObject Shell.Application
        foreach ($LpWin in @($LpShellClean.Windows())) {
            try {
                if ($LpWin.LocationURL -like "*$([uri]::EscapeDataString((Split-Path $LpRoot -Leaf)))*") { $LpWin.Quit() }
            }
            catch { }
        }
    }
    catch { }
    Start-Sleep -Milliseconds 500
    Remove-Item -LiteralPath $LpRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$LpFailed = @($LpChecks | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("快速切换栏数字键验收：{0}/{1} 通过" -f ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
