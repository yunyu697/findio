#Requires -Version 7.0
<#
.SYNOPSIS
  §3 #7 拖放 UIPI 验收：用真实鼠标从资源管理器把文件夹拖到主搜索窗。

.DESCRIPTION
  先做标准权限对照（应被接受），再用产品自身的提权路径启动提权实例，同一手势再拖一次。
  - 对照：日志出现「拖放打开目录: <路径>」，并真的多出一个指向该目录的资源管理器窗口，
    主窗随即收起。证明这套鼠标手势本身是有效的拖放。
  - 提权：悬停时拖拽游标为 IDC_NO（系统拒绝光标），无「拖放打开」日志、无新窗口、
    主窗没有收起。三项同时成立才判「被 UIPI 拒绝」。

  注入前断言（任一不成立立即退出，且不发送任何鼠标按键）：
    1. 前台是本窗；
    2. 按下点命中本次打开的资源管理器窗口（不是别的窗口）；
    3. 落点命中本窗。

  提权实例的启动方式：config.alwaysRunAsAdmin + 计划任务（与设置页开关同一条命令）。
  计划任务注册需要一次 UAC；本机 ConsentPromptBehaviorAdmin=0，静默完成。

.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpUipiDrop.ps1
  pwsh -NoProfile -File tools\Test-LpUipiDrop.ps1 -Phase Control
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Control', 'Elevated')]
    [string]$LpPhase = 'All'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Pathleap.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Pathleap.UI.exe'
$LpServiceExe = Join-Path $LpRepo 'src\Pathleap.Service\bin\x64\Debug\net8.0-windows\Pathleap.Service.exe'
$LpLogDir = Join-Path $env:LOCALAPPDATA 'Pathleap\logs'
$LpShots = Join-Path $LpRepo 'docs\shots'
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Pathleap\config.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-uipi-config-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$LpRunTag = Get-Date -Format 'HHmmss'
$LpRoot = Join-Path $env:TEMP ("lp-uipi-{0}" -f $LpRunTag)
$LpDropFolder = Join-Path $LpRoot 'target-drop'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace 'LpUipi' -Name 'Native' -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern int GetSystemMetrics(int index);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr WindowFromPoint(POINT p);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetAncestor(System.IntPtr h, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr h, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool GetWindowRect(System.IntPtr h, out RECT r);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindowVisible(System.IntPtr h);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern System.IntPtr FindWindowW(string cls, string title);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool MoveWindow(System.IntPtr h, int x, int y, int w, int ht, bool repaint);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetWindowPos(System.IntPtr h, System.IntPtr after, int x, int y, int cx, int cy, uint flags);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool GetCursorInfo(ref CURSORINFO ci);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr LoadCursorW(System.IntPtr inst, System.IntPtr name);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct POINT { public int x; public int y; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct CURSORINFO { public int cbSize; public int flags; public System.IntPtr hCursor; public POINT ptScreenPos; }
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

    private const uint MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004;
    private const uint ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;

    public static uint MoveTo(int x, int y)
    {
        int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
        int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
        var a = new INPUT[1];
        a[0].type = 0;
        a[0].U.mi.dx = (int)System.Math.Round((x - vx) * 65535.0 / (vw - 1));
        a[0].U.mi.dy = (int)System.Math.Round((y - vy) * 65535.0 / (vh - 1));
        a[0].U.mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
        return SendInput(1, a, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint LeftDown()
    {
        var a = new INPUT[1];
        a[0].type = 0;
        a[0].U.mi.dwFlags = LEFTDOWN;
        return SendInput(1, a, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    }

    public static uint LeftUp()
    {
        var a = new INPUT[1];
        a[0].type = 0;
        a[0].U.mi.dwFlags = LEFTUP;
        return SendInput(1, a, System.Runtime.InteropServices.Marshal.SizeOf(typeof(INPUT)));
    }

    public static System.IntPtr CursorAt(int x, int y)
    {
        var ci = new CURSORINFO();
        ci.cbSize = System.Runtime.InteropServices.Marshal.SizeOf(typeof(CURSORINFO));
        if (!GetCursorInfo(ref ci)) { return System.IntPtr.Zero; }
        return ci.hCursor;
    }

    public static System.IntPtr NoCursor() { return LoadCursorW(System.IntPtr.Zero, (System.IntPtr)32648); }

    public static System.IntPtr ArrowCursor() { return LoadCursorW(System.IntPtr.Zero, (System.IntPtr)32512); }

    public static System.IntPtr RootAt(int x, int y)
    {
        var p = new POINT(); p.x = x; p.y = y;
        return GetAncestor(WindowFromPoint(p), 2);
    }

    public static int PidOf(System.IntPtr h)
    {
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return (int)pid;
    }
'@
[void][LpUipi.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LpUipiToken
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

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

// 拖拽影像窗口：OLE 拖放期间由系统创建，类名 SysDragImage、标题 Drag。
public static class LpUipiDrag
{
    private delegate bool EnumProc(IntPtr h, IntPtr p);

    [DllImport("user32.dll")]
    private static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")]
    private static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")]
    private static extern bool PostMessageW(IntPtr h, uint msg, IntPtr w, IntPtr l);

    public static bool IsSystemDim(IntPtr h)
    {
        if (h == IntPtr.Zero) { return false; }
        var sb = new StringBuilder(128);
        GetClassNameW(h, sb, 128);
        return sb.ToString() == "Shell_SystemDim";
    }

    // 系统弹窗（如「电池电量不足」）会盖一层 Shell_SystemDim，挡住按下点。关掉它再测。
    public static int CloseSystemDialogs()
    {
        int count = 0;
        EnumWindows((h, p) =>
        {
            var sb = new StringBuilder(128);
            GetClassNameW(h, sb, 128);
            if (sb.ToString() == "Shell_SystemDialogProxy")
            {
                PostMessageW(h, 0x0010, IntPtr.Zero, IntPtr.Zero);
                count++;
            }
            return true;
        }, IntPtr.Zero);
        return count;
    }

    public static string Describe(IntPtr h)
    {
        if (h == IntPtr.Zero) { return "null"; }
        var c = new StringBuilder(128);
        GetClassNameW(h, c, 128);
        var t = new StringBuilder(256);
        GetWindowTextW(h, t, 256);
        uint pid;
        GetWindowThreadProcessId(h, out pid);
        return string.Format("class={0} pid={1} title='{2}'", c, pid, t);
    }

    public static bool HasDragImage()
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((h, p) =>
        {
            if (!IsWindowVisible(h)) { return true; }
            var sb = new StringBuilder(128);
            GetClassNameW(h, sb, 128);
            if (sb.ToString() == "SysDragImage") { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found != IntPtr.Zero;
    }
}
'@

$LpSelfElevated = ([LpUipiToken]::Describe($PID) -like '*elevation=1*')
if ($LpSelfElevated -and $LpPhase -eq 'All') {
    Write-Host '验收进程已提权，只跑提权阶段（对照阶段要普通权限，已单独跑过）。'
    $LpPhase = 'Elevated'
}

$LpChecks = [System.Collections.Generic.List[object]]::new()
function Add-LpCheck {
    param([string]$LpName, [bool]$LpPassed, [string]$LpDetail)
    $LpChecks.Add([pscustomobject]@{ Name = $LpName; Passed = $LpPassed; Detail = $LpDetail })
    $LpTag = if ($LpPassed) { 'PASS' } else { 'FAIL' }
    $LpColor = if ($LpPassed) { 'Green' } else { 'Red' }
    Write-Host ("[{0}] {1} — {2}" -f $LpTag, $LpName, $LpDetail) -ForegroundColor $LpColor
}

function Send-LpIpc {
    param([Parameter(Mandatory)][hashtable]$LpPayload, [int]$LpTimeoutMs = 8000)

    $LpClient = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'Pathleap.UI', [System.IO.Pipes.PipeDirection]::InOut)
    try {
        $LpClient.Connect($LpTimeoutMs)
        $LpWriter = [System.IO.StreamWriter]::new($LpClient, [System.Text.Encoding]::UTF8, 1024, $true)
        $LpWriter.WriteLine(($LpPayload | ConvertTo-Json -Compress))
        $LpWriter.Flush()
        $LpReader = [System.IO.StreamReader]::new($LpClient, [System.Text.Encoding]::UTF8, $false, 1024, $true)
        return ($LpReader.ReadLine() | ConvertFrom-Json)
    }
    finally {
        $LpClient.Dispose()
    }
}

function Get-LpLogPath { Join-Path $LpLogDir ('ui-{0}.log' -f (Get-Date -Format 'yyyyMMdd')) }

function Get-LpLogOffset {
    $LpPath = Get-LpLogPath
    if (-not (Test-Path -LiteralPath $LpPath)) { return 0 }
    return (Get-Item -LiteralPath $LpPath).Length
}

function Read-LpLogSince {
    param([long]$LpOffset)

    $LpPath = Get-LpLogPath
    if (-not (Test-Path -LiteralPath $LpPath)) { return @() }
    $LpStream = [System.IO.File]::Open($LpPath, 'Open', 'Read', 'ReadWrite')
    try {
        if ($LpOffset -gt $LpStream.Length) { $LpOffset = 0 }
        $LpStream.Seek($LpOffset, 'Begin') | Out-Null
        $LpText = (New-Object System.IO.StreamReader($LpStream)).ReadToEnd()
        return @($LpText -split "`r?`n" | Where-Object { $_ -ne '' })
    }
    finally {
        $LpStream.Dispose()
    }
}

function Get-LpWindow {
    # FindWindowW 按标题匹配在本机拿不到 WinUI 窗口（返回 0），改用进程主窗口句柄。
    foreach ($LpProc in @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue)) {
        $LpHwnd = $LpProc.MainWindowHandle
        if ($LpHwnd -ne [IntPtr]::Zero -and [LpUipi.Native]::IsWindowVisible($LpHwnd)) { return $LpHwnd }
    }
    return $null
}

function Wait-LpWindow {
    param([int]$LpSeconds = 12)

    $LpDeadline = (Get-Date).AddSeconds($LpSeconds)
    while ((Get-Date) -lt $LpDeadline) {
        $LpHwnd = Get-LpWindow
        if ($null -ne $LpHwnd -and [LpUipi.Native]::IsWindowVisible($LpHwnd)) { return $LpHwnd }
        Start-Sleep -Milliseconds 200
    }
    return $null
}

function Get-LpRect {
    param([IntPtr]$LpHwnd)

    $LpRect = New-Object LpUipi.Native+RECT
    if (-not [LpUipi.Native]::GetWindowRect($LpHwnd, [ref]$LpRect)) { throw 'GetWindowRect 失败' }
    return $LpRect
}

function Test-LpPointInRect {
    param([int]$LpX, [int]$LpY, [object]$LpRect)

    return ($LpX -ge $LpRect.Left -and $LpX -le $LpRect.Right -and $LpY -ge $LpRect.Top -and $LpY -le $LpRect.Bottom)
}

function Save-LpShotWithCursor {
    param([IntPtr]$LpHwnd, [string]$LpPath)

    $LpRect = Get-LpRect -LpHwnd $LpHwnd
    $LpW = $LpRect.Right - $LpRect.Left
    $LpH = $LpRect.Bottom - $LpRect.Top
    $LpBmp = New-Object System.Drawing.Bitmap $LpW, $LpH
    $LpGfx = [System.Drawing.Graphics]::FromImage($LpBmp)
    try {
        $LpGfx.CopyFromScreen($LpRect.Left, $LpRect.Top, 0, 0, $LpBmp.Size)
        # 真实拖拽游标：从 GetCursorInfo 取当前 HCURSOR 画进图里，不手工构造。
        $LpCi = New-Object LpUipi.Native+CURSORINFO
        $LpCi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($LpCi)
        if ([LpUipi.Native]::GetCursorInfo([ref]$LpCi) -and $LpCi.hCursor -ne [IntPtr]::Zero) {
            try {
                $LpIcon = [System.Drawing.Icon]::FromHandle($LpCi.hCursor)
                $LpX = $LpCi.ptScreenPos.x - $LpRect.Left - 16
                $LpY = $LpCi.ptScreenPos.y - $LpRect.Top - 16
                $LpGfx.DrawIcon($LpIcon, $LpX, $LpY)
            }
            catch {
                Write-Host ("  游标绘制失败: {0}" -f $_.Exception.Message) -ForegroundColor Yellow
            }
        }
        $LpBmp.Save($LpPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $LpGfx.Dispose()
        $LpBmp.Dispose()
    }
}

function Confirm-LpPointHits {
    param([IntPtr]$LpHwnd, [int]$LpX, [int]$LpY, [string]$LpWhat)

    $LpRoot = [LpUipi.Native]::RootAt($LpX, $LpY)
    for ($LpI = 0; $LpI -lt 8 -and $LpRoot.ToInt64() -ne $LpHwnd.ToInt64(); $LpI++) {
        # 系统弹窗（如「电池电量不足」）会盖一层 Shell_SystemDim 全屏遮罩，把窗口提前到最前也没用。
        # 先按窗口类名关掉系统对话框，此步不发任何输入。
        if ([LpUipiDrag]::IsSystemDim($LpRoot)) {
            $LpClosed = [LpUipiDrag]::CloseSystemDialogs()
            Write-Host ("  命中 Shell_SystemDim 遮罩（{0}），已关闭系统对话框 {1} 个" -f [LpUipiDrag]::Describe($LpRoot), $LpClosed) -ForegroundColor Yellow
            Start-Sleep -Milliseconds 900
        }
        # 被别的窗口压住了就先把目标窗口提到最前再重测（此步不发任何按键）。
        [void][LpUipi.Native]::SetWindowPos($LpHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010)
        Start-Sleep -Milliseconds 500
        $LpRoot = [LpUipi.Native]::RootAt($LpX, $LpY)
    }

    return [pscustomobject]@{
        Ok     = ($LpRoot.ToInt64() -eq $LpHwnd.ToInt64())
        Detail = ("{0} 点({1},{2}) 命中 {3}" -f $LpWhat, $LpX, $LpY, [LpUipiDrag]::Describe($LpRoot))
    }
}

function Move-LpMouse {
    param([int]$LpX, [int]$LpY)

    if ([LpUipi.Native]::MoveTo($LpX, $LpY) -ne 1) { throw 'SendInput 移动光标失败' }
}

function Invoke-LpDrag {
    param(
        [int]$LpFromX, [int]$LpFromY, [int]$LpToX, [int]$LpToY,
        [int]$LpProbeX = -1, [int]$LpProbeY = -1,
        [int]$LpHoverMs = 0, [string]$LpShotPath = ''
    )

    Move-LpMouse -LpX $LpFromX -LpY $LpFromY
    Start-Sleep -Milliseconds 260

    if ([LpUipi.Native]::LeftDown() -ne 1) { throw 'SendInput 左键按下失败' }
    $LpNoCursor = [LpUipi.Native]::NoCursor()
    $LpNoSeen = 0
    $LpHoverCursor = [IntPtr]::Zero
    $LpProbeCursor = [IntPtr]::Zero
    $LpProbeDrag = $false
    $LpHoverDrag = $false
    try {
        # 先原地小幅移动，越过系统拖拽阈值（SM_CXDRAG 默认 4px），再走曲线到落点。
        Move-LpMouse -LpX ($LpFromX + 6) -LpY ($LpFromY + 4)
        Start-Sleep -Milliseconds 60

        # 途中取样：在还没进入目标窗口的位置确认拖拽真的在跑（系统拖拽影像窗口存在）。
        if ($LpProbeX -ge 0) {
            Move-LpMouse -LpX $LpProbeX -LpY $LpProbeY
            Start-Sleep -Milliseconds 300
            $LpProbeCursor = [LpUipi.Native]::CursorAt($LpProbeX, $LpProbeY)
            $LpProbeDrag = [LpUipiDrag]::HasDragImage()
        }

        $LpSteps = 26
        for ($LpI = 1; $LpI -le $LpSteps; $LpI++) {
            $LpT = $LpI / $LpSteps
            # ease-out：起步快、接近落点慢，像人手拖。
            $LpEase = 1 - [Math]::Pow(1 - $LpT, 2)
            if ($LpProbeX -ge 0) {
                # 从探针点起算，避免回跳。
                $LpX = [int]($LpProbeX + ($LpToX - $LpProbeX) * $LpEase)
                $LpY = [int]($LpProbeY + ($LpToY - $LpProbeY) * $LpEase)
            }
            else {
                $LpX = [int]($LpFromX + ($LpToX - $LpFromX) * $LpEase)
                $LpY = [int]($LpFromY + ($LpToY - $LpFromY) * $LpEase)
            }
            Move-LpMouse -LpX $LpX -LpY $LpY
            Start-Sleep -Milliseconds 40
        }

        Move-LpMouse -LpX $LpToX -LpY $LpToY
        for ($LpI = 0; $LpI -lt 6; $LpI++) {
            Start-Sleep -Milliseconds 40
            $LpHoverCursor = [LpUipi.Native]::CursorAt($LpToX, $LpToY)
            if ($LpHoverCursor -eq $LpNoCursor) { $LpNoSeen++ }
        }
        $LpHoverDrag = [LpUipiDrag]::HasDragImage()

        if ($LpHoverMs -gt 0) { Start-Sleep -Milliseconds $LpHoverMs }
        if ($LpShotPath -ne '') {
            $LpMain = Get-LpWindow
            if ($null -ne $LpMain) { Save-LpShotWithCursor -LpHwnd $LpMain -LpPath $LpShotPath }
        }
    }
    finally {
        if ([LpUipi.Native]::LeftUp() -ne 1) { throw 'SendInput 左键抬起失败' }
    }

    return [pscustomobject]@{
        NoCursorSeen = $LpNoSeen
        HoverCursor  = $LpHoverCursor
        NoCursor     = $LpNoCursor
        ProbeCursor  = $LpProbeCursor
        ProbeDrag    = $LpProbeDrag
        HoverDrag    = $LpHoverDrag
    }
}

function Get-LpFolderUri {
    param([string]$LpPath)
    return ([System.Uri]$LpPath).AbsoluteUri.TrimEnd('/')
}

# $env:TEMP 在本机是 8.3 短路径（TYLERZ~1），资源管理器给的 LocationURL 是长路径，
# 直接比 URL 永远不相等；只比末尾几级目录名。
function Test-LpUrlLeaf {
    param([string]$LpUrl, [string[]]$LpLeaves)

    try { $LpPath = ([System.Uri]$LpUrl).LocalPath.Replace('\', '/').TrimEnd('/') }
    catch { return $false }
    $LpParts = $LpPath -split '/'
    if ($LpParts.Count -lt $LpLeaves.Count) { return $false }
    for ($LpI = 0; $LpI -lt $LpLeaves.Count; $LpI++) {
        if ($LpParts[$LpParts.Count - 1 - $LpI] -ne $LpLeaves[$LpI]) { return $false }
    }
    return $true
}

function Get-LpPathLeaves {
    param([string]$LpPath)

    $LpLeaf = [System.IO.Path]::GetFileName($LpPath)
    $LpParentLeaf = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($LpPath))
    return @($LpLeaf, $LpParentLeaf)
}

function Get-LpShellWindows {
    $LpShell = New-Object -ComObject Shell.Application
    $LpList = @()
    foreach ($LpWin in $LpShell.Windows()) {
        try {
            $LpList += [pscustomobject]@{ Hwnd = [IntPtr][int64]$LpWin.HWND; Url = ([string]$LpWin.LocationURL).TrimEnd('/') }
        }
        catch { }
    }
    return $LpList
}

function Close-LpShellWindow {
    param([string]$LpPath)

    $LpLeaves = Get-LpPathLeaves -LpPath $LpPath
    $LpShell = New-Object -ComObject Shell.Application
    foreach ($LpWin in $LpShell.Windows()) {
        try {
            if (Test-LpUrlLeaf -LpUrl ([string]$LpWin.LocationURL) -LpLeaves $LpLeaves) { $LpWin.Quit() }
        }
        catch { }
    }
}

function Open-LpSourceWindow {
    param([string]$LpFolder)

    $LpParent = Split-Path -Parent $LpFolder
    $LpParentName = Split-Path -Leaf $LpParent
    $LpLeaf = Split-Path -Leaf $LpFolder
    $LpParentLeaves = @($LpParentName)

    Start-Process -FilePath 'explorer.exe' -ArgumentList "/select,`"$LpFolder`""

    # 标题带「- 文件资源管理器」等本地化后缀，按 Shell 窗口的 LocationURL 找更稳。
    $LpHwnd = [IntPtr]::Zero
    $LpDeadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $LpDeadline -and $LpHwnd.ToInt64() -eq 0) {
        $LpMatch = @(Get-LpShellWindows | Where-Object { Test-LpUrlLeaf -LpUrl $_.Url -LpLeaves $LpParentLeaves })
        if ($LpMatch.Count -gt 0) { $LpHwnd = $LpMatch[0].Hwnd }
        else { Start-Sleep -Milliseconds 300 }
    }
    if ($LpHwnd.ToInt64() -eq 0) { throw "等不到资源管理器窗口（$LpParent）" }

    [void][LpUipi.Native]::SetWindowPos($LpHwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010)
    Start-Sleep -Milliseconds 600

    $LpPoint = Get-LpItemPoint -LpHwnd $LpHwnd -LpLeaf $LpLeaf
    return [pscustomobject]@{
        Hwnd  = $LpHwnd
        Pid   = [LpUipi.Native]::PidOf($LpHwnd)
        Title = $LpParentName
        Leaf  = $LpLeaf
        ItemX = $LpPoint.X
        ItemY = $LpPoint.Y
    }
}

# UIA 读条目矩形：不靠猜测视图布局。
function Get-LpItemPoint {
    param([IntPtr]$LpHwnd, [string]$LpLeaf)

    $LpWinEl = [System.Windows.Automation.AutomationElement]::FromHandle($LpHwnd)
    if ($null -eq $LpWinEl) { throw "UIA 取不到资源管理器窗口（$LpHwnd）" }

    $LpItemCond = New-Object System.Windows.Automation.PropertyCondition(
        [System.Windows.Automation.AutomationElement]::NameProperty, $LpLeaf)
    $LpItems = $LpWinEl.FindAll([System.Windows.Automation.TreeScope]::Descendants, $LpItemCond)
    $LpRect = $null
    for ($LpI = 0; $LpI -lt $LpItems.Count; $LpI++) {
        try { $LpR = $LpItems[$LpI].Current.BoundingRectangle }
        catch { continue }
        if ($LpR.IsEmpty -or $LpR.Width -lt 40 -or $LpR.Height -lt 12) { continue }
        if ([double]::IsInfinity($LpR.X) -or [double]::IsInfinity($LpR.Y)) { continue }
        $LpRect = $LpR
        break
    }
    if ($null -eq $LpRect) { throw "UIA 读不到条目矩形（$LpLeaf）" }

    return [pscustomobject]@{
        X = [int]($LpRect.X + [Math]::Min(160, $LpRect.Width / 2))
        Y = [int]($LpRect.Y + $LpRect.Height / 2)
    }
}

# 按下点必须在资源管理器上、落点必须在主窗上；两者一旦重叠，先确认的那个必然被另一个挡住。
# 所以把资源管理器摆到主窗左侧（不重叠），再重新读条目坐标。
function Set-LpSourceLayout {
    param([pscustomobject]$LpSource, [IntPtr]$LpMain)

    $LpMainRect = Get-LpRect -LpHwnd $LpMain
    $LpWidth = [Math]::Max(360, $LpMainRect.Left - 60)
    [void][LpUipi.Native]::MoveWindow($LpSource.Hwnd, 20, 40, $LpWidth, 900, $true)
    [void][LpUipi.Native]::SetWindowPos($LpSource.Hwnd, [IntPtr]::Zero, 0, 0, 0, 0, 0x0002 -bor 0x0001 -bor 0x0010)
    Start-Sleep -Milliseconds 800

    $LpPoint = Get-LpItemPoint -LpHwnd $LpSource.Hwnd -LpLeaf $LpSource.Leaf
    return [pscustomobject]@{
        Hwnd   = $LpSource.Hwnd
        Pid    = $LpSource.Pid
        Title  = $LpSource.Title
        Leaf   = $LpSource.Leaf
        ItemX  = $LpPoint.X
        ItemY  = $LpPoint.Y
        Rect   = $LpMainRect
    }
}

function Start-LpStack {
    param([string]$LpArgs = '--tray')

    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 600

    $LpService = Start-Process -FilePath $LpServiceExe -ArgumentList '--console' -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 400
    $LpApp = Start-Process -FilePath $LpExe -ArgumentList $LpArgs -PassThru

    $LpDeadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $LpDeadline) {
        try {
            $LpStatus = Send-LpIpc -LpPayload @{ command = 'STATUS' } -LpTimeoutMs 500
            if ($LpStatus.ok) { return }
        }
        catch { }
        Start-Sleep -Milliseconds 300
    }
    throw 'UI 控制管道 30 秒内未就绪'
}

function Get-LpUiProcessInfo {
    $LpList = @()
    foreach ($LpProc in @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue)) {
        $LpList += [pscustomobject]@{ Pid = $LpProc.Id; Info = [LpUipiToken]::Describe($LpProc.Id) }
    }
    return $LpList
}

$LpElevatedMode = ''

try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }

    New-Item -ItemType Directory -Path $LpDropFolder -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $LpDropFolder 'marker.txt') -Value 'lp-uipi-drop' -Encoding UTF8

    # 清掉上一轮遗留的临时资源管理器窗口：同名目录的旧窗口会压住本次的按下点。
    $LpShell = New-Object -ComObject Shell.Application
    foreach ($LpWin in $LpShell.Windows()) {
        try { if (([string]$LpWin.LocationURL) -match 'lp-uipi-|lp-probe-|lp-diag-') { $LpWin.Quit() } } catch { }
    }
    Start-Sleep -Milliseconds 600

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force
    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    $LpConfig.onboardingDone = $true
    $LpConfig.autoCheckUpdates = $false
    $LpConfig.logLevel = 'Debug'
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

    # ---------- 对照：标准权限 ----------
    if ($LpPhase -in @('All', 'Control')) {
        Start-LpStack
        $LpInfo = @(Get-LpUiProcessInfo)
        Add-LpCheck -LpName '对照实例为标准权限（Medium/Limited）' -LpPassed ($LpInfo.Count -eq 1 -and $LpInfo[0].Info -like '*elevation=0*' -and $LpInfo[0].Info -like '*integrity=S-1-16-8192*') `
            -LpDetail ($(if ($LpInfo.Count -gt 0) { "pid=$($LpInfo[0].Pid) $($LpInfo[0].Info)" } else { '未找到 UI 进程' }))

        $LpSource = Open-LpSourceWindow -LpFolder $LpDropFolder
        Add-LpCheck -LpName '资源管理器窗口就绪且条目可见' -LpPassed ($LpSource.Hwnd -ne [IntPtr]::Zero) `
            -LpDetail ("标题='{0}' pid={1} 条目点=({2},{3})" -f $LpSource.Title, $LpSource.Pid, $LpSource.ItemX, $LpSource.ItemY)

        Send-LpIpc -LpPayload @{ command = 'SHOW' } | Out-Null
        Start-Sleep -Milliseconds 1200
        $LpMain = Wait-LpWindow
        if ($null -eq $LpMain) { throw '等不到主搜索窗' }
        $LpSource = Set-LpSourceLayout -LpSource $LpSource -LpMain $LpMain
        $LpMainRect = $LpSource.Rect
        Add-LpCheck -LpName '拖放源摆到主窗左侧、与落点不重叠' `
            -LpPassed (-not (Test-LpPointInRect -LpX $LpSource.ItemX -LpY $LpSource.ItemY -LpRect $LpMainRect)) `
            -LpDetail ("条目点=({0},{1})，主窗=({2},{3})-({4},{5})" -f $LpSource.ItemX, $LpSource.ItemY, $LpMainRect.Left, $LpMainRect.Top, $LpMainRect.Right, $LpMainRect.Bottom)
        $LpTargetX = [int](($LpMainRect.Left + $LpMainRect.Right) / 2)
        $LpTargetY = [int]($LpMainRect.Top + ($LpMainRect.Bottom - $LpMainRect.Top) * 0.7)

        $LpFg = [LpUipi.Native]::GetForegroundWindow()
        Add-LpCheck -LpName '注入前前台是本窗' -LpPassed ($LpFg.ToInt64() -eq $LpMain.ToInt64()) `
            -LpDetail ("foreground=0x{0:X} / 本窗=0x{1:X}" -f $LpFg.ToInt64(), $LpMain.ToInt64())
        if ($LpFg.ToInt64() -ne $LpMain.ToInt64()) { throw '前台不是本窗，按约定退出且未发送任何鼠标按键' }

        $LpSrcHit = Confirm-LpPointHits -LpHwnd $LpSource.Hwnd -LpX $LpSource.ItemX -LpY $LpSource.ItemY -LpWhat '按下点'
        Add-LpCheck -LpName '按下点命中本次打开的资源管理器窗口' -LpPassed $LpSrcHit.Ok -LpDetail $LpSrcHit.Detail
        if (-not $LpSrcHit.Ok) { throw '按下点不在资源管理器窗口上，按约定退出且未发送任何鼠标按键' }

        $LpDstHit = Confirm-LpPointHits -LpHwnd $LpMain -LpX $LpTargetX -LpY $LpTargetY -LpWhat '落点'
        Add-LpCheck -LpName '落点命中主窗' -LpPassed $LpDstHit.Ok -LpDetail $LpDstHit.Detail
        if (-not $LpDstHit.Ok) { throw '落点不在主窗上，按约定退出且未发送任何鼠标按键' }

        $LpLogOffset = Get-LpLogOffset
        $LpShot = Join-Path $LpShots '87-uipi-control-drop.png'
        $LpSrcRect = Get-LpRect -LpHwnd $LpSource.Hwnd
        $LpProbeX = [int](($LpSrcRect.Left + $LpSrcRect.Right) / 2)
        $LpProbeY = [int]($LpSrcRect.Bottom - 120)
        $LpDrag = Invoke-LpDrag -LpFromX $LpSource.ItemX -LpFromY $LpSource.ItemY -LpToX $LpTargetX -LpToY $LpTargetY `
            -LpProbeX $LpProbeX -LpProbeY $LpProbeY -LpHoverMs 500 -LpShotPath $LpShot
        Start-Sleep -Milliseconds 1800

        Add-LpCheck -LpName '对照：拖拽手势有效（途中拖拽影像存在）' -LpPassed $LpDrag.ProbeDrag `
            -LpDetail ("途中({0},{1}) 拖拽影像={2}；落点({3},{4}) 拖拽影像={5}（进目标窗后系统会收掉影像，不作判据）" -f $LpProbeX, $LpProbeY, $LpDrag.ProbeDrag, $LpTargetX, $LpTargetY, $LpDrag.HoverDrag)

        $LpNewLines = @(Read-LpLogSince -LpOffset $LpLogOffset)
        $LpDropLogs = @($LpNewLines | Where-Object { $_ -match '拖放打开' })
        $LpDropOk = $LpDropLogs.Count -eq 1 -and $LpDropLogs[0] -match '拖放打开目录: .*\\target-drop$'
        Add-LpCheck -LpName '对照：日志记录「拖放打开目录」' -LpPassed $LpDropOk `
            -LpDetail ($(if ($LpDropLogs.Count -gt 0) { $LpDropLogs[-1].Trim() } else { '未出现（新增日志 ' + $LpNewLines.Count + ' 行）' }))

        $LpOpenedLeaves = @('target-drop', (Split-Path -Leaf $LpRoot))
        $LpOpened = @(Get-LpShellWindows | Where-Object { Test-LpUrlLeaf -LpUrl $_.Url -LpLeaves $LpOpenedLeaves })
        Add-LpCheck -LpName '对照：目标目录真的被资源管理器打开' -LpPassed ($LpOpened.Count -ge 1) `
            -LpDetail ("指向该目录的窗口 {0} 个（{1}）" -f $LpOpened.Count, $LpDropFolder)
        Add-LpCheck -LpName '对照：拖放后主窗收起' -LpPassed (-not [LpUipi.Native]::IsWindowVisible($LpMain)) `
            -LpDetail ("IsWindowVisible={0}；悬停游标为拒绝光标 {1} 次" -f [LpUipi.Native]::IsWindowVisible($LpMain), $LpDrag.NoCursorSeen)
        Write-Host ("  截图: {0}" -f $LpShot)

        Close-LpShellWindow -LpPath $LpDropFolder
        Close-LpShellWindow -LpPath $LpRoot
        Start-Sleep -Milliseconds 600
    }

    # ---------- 提权：由已提权的验收进程执行 ----------
    if ($LpPhase -in @('All', 'Elevated')) {
        if (-not $LpSelfElevated) {
            throw '提权阶段必须由提权后的验收进程执行：Windows 不允许普通权限进程向提权前台窗口注入输入，拖拽根本起不来'
        }

        Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 600

        # 先摆好拖放源（资源管理器仍是标准权限），再启动提权实例——它启动即显示主窗并抢回前台。
        $LpSource = Open-LpSourceWindow -LpFolder $LpDropFolder
        $LpSourceInfo = [LpUipiToken]::Describe($LpSource.Pid)
        Add-LpCheck -LpName '拖放源（资源管理器）为标准权限' -LpPassed ($LpSourceInfo -like '*elevation=0*' -and $LpSourceInfo -like '*integrity=S-1-16-8192*') `
            -LpDetail ("pid=$($LpSource.Pid) $LpSourceInfo")

        $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
        $LpConfig.alwaysRunAsAdmin = $true
        $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

        Start-Process -FilePath $LpServiceExe -ArgumentList '--console' -WindowStyle Hidden | Out-Null
        Start-Sleep -Milliseconds 500
        $LpElevatedMode = 'config.alwaysRunAsAdmin=true；验收进程已提权，直接启动提权实例'
        Start-Process -FilePath $LpExe | Out-Null

        # 等提权实例出现并显示主窗。
        $LpHigh = $null
        $LpMain = $null
        $LpDeadline = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $LpDeadline) {
            foreach ($LpItem in @(Get-LpUiProcessInfo)) {
                if ($LpItem.Info -notlike '*elevation=1*' -or $LpItem.Info -notlike '*integrity=S-1-16-12288*') { continue }
                $LpProc = Get-Process -Id $LpItem.Pid -ErrorAction SilentlyContinue
                $LpHwnd = if ($null -ne $LpProc) { $LpProc.MainWindowHandle } else { [IntPtr]::Zero }
                if ($LpHwnd.ToInt64() -ne 0 -and [LpUipi.Native]::IsWindowVisible($LpHwnd)) {
                    $LpHigh = $LpItem
                    $LpMain = $LpHwnd
                    break
                }
            }
            if ($null -ne $LpMain) { break }
            Start-Sleep -Milliseconds 400
        }
        Add-LpCheck -LpName '提权实例（High 完整性）已显示主窗' -LpPassed ($null -ne $LpMain) `
            -LpDetail ($(if ($null -ne $LpMain) { "pid=$($LpHigh.Pid) $($LpHigh.Info)（启动方式: $LpElevatedMode）" } else { "未出现，启动方式: $LpElevatedMode" }))
        if ($null -eq $LpMain) { throw '没有提权窗口，无法验证 UIPI' }

        # 等它抢回前台；抢不回来就放弃，不注入任何鼠标按键。
        $LpFg = [LpUipi.Native]::GetForegroundWindow()
        $LpDeadline = (Get-Date).AddSeconds(8)
        while ((Get-Date) -lt $LpDeadline -and $LpFg.ToInt64() -ne $LpMain.ToInt64()) {
            Start-Sleep -Milliseconds 250
            $LpFg = [LpUipi.Native]::GetForegroundWindow()
        }
        Add-LpCheck -LpName '注入前前台是本窗' -LpPassed ($LpFg.ToInt64() -eq $LpMain.ToInt64()) `
            -LpDetail ("foreground=0x{0:X} / 本窗=0x{1:X}" -f $LpFg.ToInt64(), $LpMain.ToInt64())
        if ($LpFg.ToInt64() -ne $LpMain.ToInt64()) { throw '前台不是本窗，按约定退出且未发送任何鼠标按键' }

        $LpMainPid = [LpUipi.Native]::PidOf($LpMain)
        Add-LpCheck -LpName '主窗属于提权进程' -LpPassed ($LpMainPid -eq $LpHigh.Pid) `
            -LpDetail ("主窗 pid=$LpMainPid，提权进程=$($LpHigh.Pid)")

        $LpSource = Set-LpSourceLayout -LpSource $LpSource -LpMain $LpMain
        $LpMainRect = $LpSource.Rect
        Add-LpCheck -LpName '拖放源摆到提权主窗左侧、与落点不重叠' `
            -LpPassed (-not (Test-LpPointInRect -LpX $LpSource.ItemX -LpY $LpSource.ItemY -LpRect $LpMainRect)) `
            -LpDetail ("条目点=({0},{1})，主窗=({2},{3})-({4},{5})" -f $LpSource.ItemX, $LpSource.ItemY, $LpMainRect.Left, $LpMainRect.Top, $LpMainRect.Right, $LpMainRect.Bottom)
        $LpTargetX = [int](($LpMainRect.Left + $LpMainRect.Right) / 2)
        $LpTargetY = [int]($LpMainRect.Top + ($LpMainRect.Bottom - $LpMainRect.Top) * 0.7)

        # 摆窗口不激活，这里再断言一次：前台必须仍是提权主窗，否则退出且不发任何按键。
        $LpFg = [LpUipi.Native]::GetForegroundWindow()
        Add-LpCheck -LpName '注入前前台仍是提权主窗' -LpPassed ($LpFg.ToInt64() -eq $LpMain.ToInt64()) `
            -LpDetail ("foreground=0x{0:X} / 本窗=0x{1:X}" -f $LpFg.ToInt64(), $LpMain.ToInt64())
        if ($LpFg.ToInt64() -ne $LpMain.ToInt64()) { throw '前台不是本窗，按约定退出且未发送任何鼠标按键' }

        $LpSrcHit = Confirm-LpPointHits -LpHwnd $LpSource.Hwnd -LpX $LpSource.ItemX -LpY $LpSource.ItemY -LpWhat '按下点'
        Add-LpCheck -LpName '按下点命中本次打开的资源管理器窗口' -LpPassed $LpSrcHit.Ok -LpDetail $LpSrcHit.Detail
        if (-not $LpSrcHit.Ok) { throw '按下点不在资源管理器窗口上，按约定退出且未发送任何鼠标按键' }

        $LpDstHit = Confirm-LpPointHits -LpHwnd $LpMain -LpX $LpTargetX -LpY $LpTargetY -LpWhat '落点'
        Add-LpCheck -LpName '落点命中提权主窗' -LpPassed $LpDstHit.Ok -LpDetail $LpDstHit.Detail
        if (-not $LpDstHit.Ok) { throw '落点不在主窗上，按约定退出且未发送任何鼠标按键' }

        $LpLogOffset = Get-LpLogOffset
        $LpShot = Join-Path $LpShots '88-uipi-elevated-blocked.png'
        $LpSrcRect = Get-LpRect -LpHwnd $LpSource.Hwnd
        $LpProbeX = [int](($LpSrcRect.Left + $LpSrcRect.Right) / 2)
        $LpProbeY = [int]($LpSrcRect.Bottom - 120)
        $LpDrag = Invoke-LpDrag -LpFromX $LpSource.ItemX -LpFromY $LpSource.ItemY -LpToX $LpTargetX -LpToY $LpTargetY `
            -LpProbeX $LpProbeX -LpProbeY $LpProbeY -LpHoverMs 400 -LpShotPath $LpShot
        Start-Sleep -Milliseconds 1800

        # 探针点在资源管理器窗口内、主窗左边界之外：拖拽影像还在，才说明手势真的在跑。
        Add-LpCheck -LpName '提权：拖拽手势确实启动（途中拖拽影像存在）' -LpPassed $LpDrag.ProbeDrag `
            -LpDetail ("途中({0},{1}) 拖拽影像={2}，探针游标=0x{3:X}" -f $LpProbeX, $LpProbeY, $LpDrag.ProbeDrag, $LpDrag.ProbeCursor.ToInt64())

        $LpNewLines = @(Read-LpLogSince -LpOffset $LpLogOffset)
        $LpDropLogs = @($LpNewLines | Where-Object { $_ -match '拖放打开' })
        Add-LpCheck -LpName '提权：没有「拖放打开」日志' -LpPassed ($LpDropLogs.Count -eq 0) `
            -LpDetail ($(if ($LpDropLogs.Count -gt 0) { $LpDropLogs -join ' | ' } else { "新增日志 $($LpNewLines.Count) 行，无拖放记录" }))

        $LpOpenedLeaves = @('target-drop', (Split-Path -Leaf $LpRoot))
        $LpOpened = @(Get-LpShellWindows | Where-Object { Test-LpUrlLeaf -LpUrl $_.Url -LpLeaves $LpOpenedLeaves })
        Add-LpCheck -LpName '提权：目标目录没有被打开' -LpPassed ($LpOpened.Count -eq 0) `
            -LpDetail ("指向该目录的窗口 {0} 个" -f $LpOpened.Count)

        $LpStillVisible = [LpUipi.Native]::IsWindowVisible($LpMain)
        Add-LpCheck -LpName '提权：主窗没有因 Drop 收起' -LpPassed $LpStillVisible `
            -LpDetail ("IsWindowVisible={0}" -f $LpStillVisible)

        # 越过主窗左边界后系统给出拒绝光标，说明拖放在提权窗上不成立。
        $LpHoverNo = ($LpDrag.HoverCursor.ToInt64() -ne 0 -and $LpDrag.HoverCursor.ToInt64() -eq $LpDrag.NoCursor.ToInt64())
        Add-LpCheck -LpName '提权：悬停提权主窗时游标为拒绝光标（IDC_NO）' -LpPassed $LpHoverNo `
            -LpDetail ("落点光标=0x{0:X}（IDC_NO=0x{1:X}，命中 {2}/6）；落点拖拽影像={3}" -f $LpDrag.HoverCursor.ToInt64(), $LpDrag.NoCursor.ToInt64(), $LpDrag.NoCursorSeen, $LpDrag.HoverDrag)

        Write-Host ("  截图: {0}" -f $LpShot)

        Close-LpShellWindow -LpPath $LpDropFolder
        Close-LpShellWindow -LpPath $LpRoot
        Start-Sleep -Milliseconds 600
    }
}
catch {
    Add-LpCheck -LpName '执行过程无异常' -LpPassed $false -LpDetail $_.Exception.Message
}
finally {
    Get-Process Pathleap.UI, Pathleap.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
    $LpLeftover = @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue)
    if ($LpLeftover.Count -gt 0) {
        Write-Host ("  注意：仍有 {0} 个 UI 进程未结束（{1}）" -f $LpLeftover.Count, (($LpLeftover | ForEach-Object { $_.Id }) -join ',')) -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $LpConfigBackup) {
        Copy-Item -LiteralPath $LpConfigBackup -Destination $LpConfigPath -Force
        Remove-Item -LiteralPath $LpConfigBackup -Force
    }

    foreach ($LpDir in @($LpRoot)) {
        if (Test-Path -LiteralPath $LpDir) { Remove-Item -LiteralPath $LpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$LpFailed = @($LpChecks | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("拖放 UIPI 验收（{0}）：{1}/{2} 通过" -f $LpPhase, ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
