#Requires -Version 7.0
<#
.SYNOPSIS
    用真实窗口枚举采样验证「启动全程不闪窗、不留控制台窗口」。

.DESCRIPTION
    前置：已在设置页开启「始终以管理员身份运行」（计划任务已注册）。
    本脚本建桌面快捷方式并用 explorer 打开（等价双击），在启动前开始高频枚举顶层窗口
    （约 1–2ms 一轮，winmm 1ms 定时器），逐窗口记录：
      - 所属进程、窗口类、标题、矩形；
      - IsWindowVisible 与 DWM cloaked 状态，以及每个状态的首末时刻；
      - 是否存在「已绘制（可见且未被 DWM 遮蔽、非零尺寸）→ 不可见/被遮蔽」的回退。
    几何口径：矩形统一取 DWMWA_EXTENDED_FRAME_BOUNDS（DWM 可视外框，物理像素），
    同时记录窗口 DPI 与 DIP 尺寸。不要用 GetWindowRect 与历史数字直接比：在 DPI 不感知
    的宿主里 GetWindowRect 会被虚拟化（本机 200% 下 1470×872 会读成 735×436）。
    采样结束后断言：
      1. 中转进程（标准权限实例）在整个生命周期内没有创建任何顶层窗口；
      2. 没有任何控制台窗口属于本次启动链（窗口 owner 是中转/提权实例，或祖先链里出现它们）。
         其它后台程序（例如别的会话拉起 Windows Terminal）造成的控制台窗口按祖先进程链
         判定为外部干扰，单独列出、不计入本项；无法追溯到祖先链的按「无法归属」判失败；
      3. 提权实例有且只有一个已绘制窗口（主窗口），首次绘制后不再回到不可见/被遮蔽，
         且不存在第二个已绘制的 Pathleap 窗口、不存在零尺寸已绘制窗口。若回退时前台已被
         其它进程拿走，按「失焦即隐藏」的既有设计记为外部干扰并列出；读不到前台或前台仍
         在本进程/启动链内，仍判失败。

    只读枚举，不注入键鼠、不抢前台；结束后 schtasks /End 收尾并删除测试快捷方式。

.EXAMPLE
    pwsh -NoProfile -File tools/Test-LpLaunchWindows.ps1
#>
[CmdletBinding()]
param(
    [string]$LpExe = '',
    [int]$LpTailMs = 3000,
    [int]$LpTimeoutSeconds = 40
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($LpExe)) {
    $LpExe = Join-Path $PSScriptRoot '..\src\Pathleap.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Pathleap.UI.exe'
}
$LpExe = (Resolve-Path -LiteralPath $LpExe).Path
$LpTaskName = "Pathleap-Elevated-$([System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value)"
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Pathleap\config.json'
$LpShortcut = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Pathleap-提权入口测试.lnk'
$LpEvidence = Join-Path $env:TEMP 'lp-launch-windows.json'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

namespace LpLaunchWatch
{
    public sealed class LpWinReport
    {
        public long Hwnd;
        public uint Pid;
        public string Exe = "";
        public string ClassName = "";
        public string Title = "";
        public string Rect = "";
        public string RectDip = "";
        public string RectSource = "";
        public int Dpi;
        public bool Baseline;
        public long FirstSeenMs;
        public long LastSeenMs;
        public long FirstVisibleMs = -1;
        public long LastVisibleMs = -1;
        public long FirstPaintedMs = -1;
        public long LastPaintedMs = -1;
        public int VisibleSamples;
        public int PaintedSamples;
        public int StateChanges;
        public int RectChangesPainted;
        public string FirstPaintedRect = "";
        public string PaintTitle = "";
        public bool EverCloaked;
        public string FinalState = "";
        public string Timeline = "";
        public string Ancestors = "";
        public string Hides = "";
        public int LastHideFgPid;
    }

    public static class LpWindowWatch
    {
        private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

        [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
        [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
        [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr hwnd, StringBuilder sb, int max);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr hwnd, StringBuilder sb, int max);
        [DllImport("user32.dll")] private static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out int val, int size);
        [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr hwnd, int attr, out RECT val, int size);
        [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr hwnd);
        [DllImport("user32.dll")] private static extern IntPtr GetForegroundWindow();
        [DllImport("ntdll.dll")] private static extern int NtQueryInformationProcess(IntPtr process, int cls, ref PBI info, int len, out int ret);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr OpenProcess(int access, bool inherit, uint pid);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool QueryFullProcessImageNameW(IntPtr proc, int flags, StringBuilder sb, ref int size);
        [DllImport("kernel32.dll")] private static extern bool CloseHandle(IntPtr h);
        [DllImport("winmm.dll")] private static extern uint timeBeginPeriod(uint ms);
        [DllImport("winmm.dll")] private static extern uint timeEndPeriod(uint ms);

        [StructLayout(LayoutKind.Sequential)]
        private struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        [StructLayout(LayoutKind.Sequential)]
        private struct PBI
        {
            public IntPtr ExitStatus;
            public IntPtr PebBaseAddress;
            public IntPtr AffinityMask;
            public IntPtr BasePriority;
            public IntPtr UniqueProcessId;
            public IntPtr InheritedFromUniqueProcessId;
        }

        private sealed class LpRec
        {
            public long Hwnd;
            public uint Pid;
            public string Exe;
            public string ClassName;
            public string Title;
            public int L, T, R, B;
            public int Dpi;
            public string RectSource;
            public bool Baseline;
            public long FirstSeen;
            public long LastSeen;
            public long FirstVisible = -1;
            public long LastVisible = -1;
            public long FirstPainted = -1;
            public long LastPainted = -1;
            public int VisibleSamples;
            public int PaintedSamples;
            public int StateChanges;
            public int RectChangesPainted;
            public string FirstPaintedRect = "";
            public string PaintTitle = "";
            public bool EverCloaked;
            public string State;
            public string Ancestors = "";
            public int LastHideFgPid;
            public List<string> Hides = new List<string>();
            public List<string> Transitions = new List<string>();
        }

        private static readonly object Gate = new object();
        private static Dictionary<long, LpRec> _records = new Dictionary<long, LpRec>();
        private static HashSet<long> _baseline = new HashSet<long>();
        private static Dictionary<uint, string> _exeCache = new Dictionary<uint, string>();
        private static Stopwatch _clock = new Stopwatch();
        private static EnumWindowsProc _callback;
        private static Thread _thread;
        private static volatile bool _stop;
        private static int _samples;

        public static int SampleCount { get { return _samples; } }
        public static long ElapsedMs { get { return _clock.ElapsedMilliseconds; } }

        public static void Start()
        {
            lock (Gate)
            {
                _records = new Dictionary<long, LpRec>();
                _baseline = new HashSet<long>();
                _exeCache = new Dictionary<uint, string>();
            }

            _callback = new EnumWindowsProc(OnWindow);
            _clock = Stopwatch.StartNew();
            EnumWindows(_callback, IntPtr.Zero);

            lock (Gate)
            {
                _baseline = new HashSet<long>(_records.Keys);
                _records = new Dictionary<long, LpRec>();
            }

            _clock.Restart();
            _samples = 0;
            _stop = false;
            _thread = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.Highest };
            _thread.Start();
        }

        public static void Stop()
        {
            _stop = true;
            if (_thread != null)
            {
                _thread.Join(3000);
            }

            timeEndPeriod(1);
        }

        public static LpWinReport[] Reports()
        {
            lock (Gate)
            {
                return Build();
            }
        }

        private static LpWinReport[] Build()
        {
            var list = new List<LpWinReport>(_records.Count);
            foreach (var rec in _records.Values)
            {
                list.Add(new LpWinReport
                {
                    Hwnd = rec.Hwnd,
                    Pid = rec.Pid,
                    Exe = rec.Exe,
                    ClassName = rec.ClassName,
                    Title = rec.Title,
                    Rect = string.Format("{0},{1},{2}x{3}", rec.L, rec.T, rec.R - rec.L, rec.B - rec.T),
                    RectDip = rec.Dpi > 0
                        ? string.Format("{0:0.#}x{1:0.#}", (rec.R - rec.L) * 96.0 / rec.Dpi, (rec.B - rec.T) * 96.0 / rec.Dpi)
                        : "",
                    RectSource = rec.RectSource,
                    Dpi = rec.Dpi,
                    Baseline = rec.Baseline,
                    FirstSeenMs = rec.FirstSeen,
                    LastSeenMs = rec.LastSeen,
                    FirstVisibleMs = rec.FirstVisible,
                    LastVisibleMs = rec.LastVisible,
                    FirstPaintedMs = rec.FirstPainted,
                    LastPaintedMs = rec.LastPainted,
                    VisibleSamples = rec.VisibleSamples,
                    PaintedSamples = rec.PaintedSamples,
                    StateChanges = rec.StateChanges,
                    RectChangesPainted = rec.RectChangesPainted,
                    FirstPaintedRect = rec.FirstPaintedRect,
                    PaintTitle = rec.PaintTitle,
                    EverCloaked = rec.EverCloaked,
                    FinalState = rec.State ?? "",
                    Timeline = string.Join(";", rec.Transitions),
                    Ancestors = rec.Ancestors,
                    Hides = string.Join(";", rec.Hides),
                    LastHideFgPid = rec.LastHideFgPid
                });
            }

            return list.ToArray();
        }

        private static void Loop()
        {
            timeBeginPeriod(1);
            try
            {
                while (!_stop)
                {
                    EnumWindows(_callback, IntPtr.Zero);
                    _samples++;
                    Thread.Sleep(1);
                }
            }
            finally
            {
                timeEndPeriod(1);
            }
        }

        private static bool OnWindow(IntPtr hwnd, IntPtr lparam)
        {
            long h = hwnd.ToInt64();
            long t = _clock.ElapsedMilliseconds;

            bool inBaseline;
            lock (Gate) { inBaseline = _baseline.Contains(h); }

            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            string exe = ExeOf(pid);
            string cls = ClassOf(hwnd);

            bool isTarget = exe.EndsWith("Pathleap.UI.exe", StringComparison.OrdinalIgnoreCase);
            bool isConsole = cls.Equals("ConsoleWindowClass", StringComparison.OrdinalIgnoreCase)
                          || cls.Equals("CASCADIA_HOSTING_WINDOW_CLASS", StringComparison.OrdinalIgnoreCase)
                          || exe.EndsWith("conhost.exe", StringComparison.OrdinalIgnoreCase)
                          || exe.EndsWith("OpenConsole.exe", StringComparison.OrdinalIgnoreCase)
                          || exe.EndsWith("WindowsTerminal.exe", StringComparison.OrdinalIgnoreCase);

            if (inBaseline && !isTarget && !isConsole)
            {
                return true;
            }

            bool visible = IsWindowVisible(hwnd);
            int cloaked = 0;
            if (DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) != 0)
            {
                cloaked = 0;
            }

            RECT r;
            string rectSource = "extended";
            if (DwmGetWindowAttribute(hwnd, 9, out r, Marshal.SizeOf<RECT>()) != 0)
            {
                GetWindowRect(hwnd, out r);
                rectSource = "window";
            }
            uint dpi = GetDpiForWindow(hwnd);
            int w = r.Right - r.Left;
            int ht = r.Bottom - r.Top;
            string state = !visible ? "H" : (cloaked != 0 ? "C" : ((w <= 0 || ht <= 0) ? "Z" : "V"));
            string rectText = string.Format("{0},{1},{2}x{3}", r.Left, r.Top, w, ht);

            lock (Gate)
            {
                LpRec rec;
                if (!_records.TryGetValue(h, out rec))
                {
                    rec = new LpRec
                    {
                        Hwnd = h,
                        Pid = pid,
                        Exe = exe,
                        ClassName = cls,
                        Title = TitleOf(hwnd),
                        Dpi = (int)dpi,
                        RectSource = rectSource,
                        Baseline = inBaseline,
                        FirstSeen = t,
                        State = state,
                        Ancestors = isConsole ? AncestorsOf(pid) : ""
                    };
                    rec.Transitions.Add(t + ":" + state);
                    _records[h] = rec;
                }
                else
                {
                    // 标题可能在窗口创建后才设置（WinUI 默认先叫 WinUI Desktop），每轮刷新。
                    string latestTitle = TitleOf(hwnd);
                    if (latestTitle.Length > 0) { rec.Title = latestTitle; }
                }

                rec.LastSeen = t;
                rec.L = r.Left;
                rec.T = r.Top;
                rec.R = r.Right;
                rec.B = r.Bottom;
                rec.Dpi = (int)dpi;
                rec.RectSource = rectSource;

                if (visible)
                {
                    rec.VisibleSamples++;
                    if (rec.FirstVisible < 0) { rec.FirstVisible = t; }
                    rec.LastVisible = t;
                }

                if (state == "V")
                {
                    rec.PaintedSamples++;
                    if (rec.FirstPainted < 0)
                    {
                        rec.FirstPainted = t;
                        rec.FirstPaintedRect = rectText;
                        rec.PaintTitle = rec.Title;
                    }
                    else if (rec.FirstPaintedRect.Length > 0)
                    {
                        string[] prev = rec.FirstPaintedRect.Split(new[] { ',', 'x' });
                        if (prev.Length == 4)
                        {
                            int pl = int.Parse(prev[0]);
                            int pt = int.Parse(prev[1]);
                            int pw = int.Parse(prev[2]);
                            int ph = int.Parse(prev[3]);
                            if (pl != r.Left || pt != r.Top || pw != w || ph != ht)
                            {
                                rec.RectChangesPainted++;
                                rec.FirstPaintedRect = rectText;
                            }
                        }
                    }

                    rec.LastPainted = t;
                }

                if (cloaked != 0)
                {
                    rec.EverCloaked = true;
                }

                if (rec.State != state)
                {
                    // 从已绘制退回不可见/被遮蔽时，记下当时的前台进程与它的祖先链：
                    // 据此区分「本进程自己闪了一下」和「别的程序抢了前台，主窗口按设计隐藏」。
                    if (rec.State == "V" && state != "V")
                    {
                        int fgPid = ForegroundPid();
                        rec.LastHideFgPid = fgPid;
                        rec.Hides.Add(string.Format("{0}:{1}:fg={2}:{3}", t, state, fgPid, fgPid > 0 ? AncestorsOf((uint)fgPid) : ""));
                    }

                    rec.State = state;
                    rec.StateChanges++;
                    rec.Transitions.Add(t + ":" + state);
                }
            }

            return true;
        }

        private static int ForegroundPid()
        {
            IntPtr fg = GetForegroundWindow();
            if (fg == IntPtr.Zero) { return 0; }
            uint pid;
            GetWindowThreadProcessId(fg, out pid);
            return (int)pid;
        }

        private static int ParentOf(int pid)
        {
            IntPtr proc = OpenProcess(0x1400, false, (uint)pid);
            if (proc == IntPtr.Zero) { return -1; }
            try
            {
                PBI info = new PBI();
                int ret;
                if (NtQueryInformationProcess(proc, 0, ref info, Marshal.SizeOf<PBI>(), out ret) != 0) { return -1; }
                long parent = info.InheritedFromUniqueProcessId.ToInt64();
                return parent > 0 && parent <= int.MaxValue ? (int)parent : -1;
            }
            finally
            {
                CloseHandle(proc);
            }
        }

        // 返回「自己;父;祖父;…」的 pid 链，用于事后判定窗口归属（本次启动链 vs 外部程序）。
        private static string AncestorsOf(uint pid)
        {
            var sb = new StringBuilder();
            int cur = (int)pid;
            for (int i = 0; i < 12 && cur > 0; i++)
            {
                if (sb.Length > 0) { sb.Append(';'); }
                sb.Append(cur);
                int parent = ParentOf(cur);
                if (parent <= 0 || parent == cur) { break; }
                cur = parent;
            }

            return sb.ToString();
        }

        private static string ExeOf(uint pid)
        {
            lock (Gate)
            {
                string cached;
                if (_exeCache.TryGetValue(pid, out cached)) { return cached; }
            }

            string result = "";
            IntPtr proc = OpenProcess(0x1000, false, pid);
            if (proc != IntPtr.Zero)
            {
                try
                {
                    var sb = new StringBuilder(1024);
                    int size = sb.Capacity;
                    if (QueryFullProcessImageNameW(proc, 0, sb, ref size))
                    {
                        result = sb.ToString(0, size);
                    }
                }
                finally
                {
                    CloseHandle(proc);
                }
            }

            lock (Gate) { _exeCache[pid] = result; }
            return result;
        }

        private static string ClassOf(IntPtr hwnd)
        {
            var sb = new StringBuilder(256);
            int n = GetClassNameW(hwnd, sb, sb.Capacity);
            return n > 0 ? sb.ToString(0, n) : "";
        }

        private static string TitleOf(IntPtr hwnd)
        {
            var sb = new StringBuilder(512);
            int n = GetWindowTextW(hwnd, sb, sb.Capacity);
            return n > 0 ? sb.ToString(0, n) : "";
        }
    }
}
'@

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LpLaunchToken
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr OpenProcess(int access, bool inherit, int pid);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool OpenProcessToken(IntPtr process, int access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern bool GetTokenInformation(IntPtr token, int cls, out int info, int len, out int ret);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    public static int Elevation(int pid)
    {
        IntPtr process = OpenProcess(0x1000, false, pid);
        if (process == IntPtr.Zero) { return -1; }
        try
        {
            IntPtr token;
            if (!OpenProcessToken(process, 0x0008, out token)) { return -1; }
            try
            {
                int info;
                return GetTokenInformation(token, 20, out info, 4, out _) ? info : -1;
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

if (-not (Test-Path -LiteralPath $LpExe)) { throw "找不到 $LpExe" }
schtasks.exe /Query /TN $LpTaskName 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { throw '计划任务未注册：先开启设置页「始终以管理员身份运行」再跑本脚本' }
if (-not (Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json).AlwaysRunAsAdmin) {
    throw '配置里 alwaysRunAsAdmin 不是 true，快捷方式不会走提权链'
}

$LpSampler = $true
$LpProcessJob = $true
$LpMediumPid = 0
$LpElevatedPid = 0
try {
    Get-Process Pathleap.UI -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
    Start-Sleep -Milliseconds 600

    $LpShell = New-Object -ComObject WScript.Shell
    $LpLink = $LpShell.CreateShortcut($LpShortcut)
    $LpLink.TargetPath = $LpExe
    $LpLink.WorkingDirectory = Split-Path -Parent $LpExe
    $LpLink.Description = 'Pathleap 启动可见性验证'
    $LpLink.Save()

    $LpSampleFile = Join-Path $env:TEMP 'lp-launch-procs.txt'
    if (Test-Path -LiteralPath $LpSampleFile) { Remove-Item -LiteralPath $LpSampleFile -Force }
    $LpProcessJob = Start-ThreadJob -ArgumentList $LpSampleFile -ScriptBlock {
        param($LpFile)
        $LpSeen = @{}
        $LpEnd = (Get-Date).AddSeconds(45)
        while ((Get-Date) -lt $LpEnd) {
            foreach ($LpRow in Get-CimInstance Win32_Process -Filter "Name='Pathleap.UI.exe'" -ErrorAction SilentlyContinue) {
                if (-not $LpSeen.ContainsKey($LpRow.ProcessId)) {
                    $LpSeen[$LpRow.ProcessId] = $true
                    "{0}`t{1}" -f $LpRow.ProcessId, $LpRow.CommandLine | Add-Content -LiteralPath $LpFile
                }
            }
            Start-Sleep -Milliseconds 20
        }
    }

    $LpLaunchAt = Get-Date
    [LpLaunchWatch.LpWindowWatch]::Start()
    Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$LpShortcut`""

    $LpPaintedAt = [datetime]::MinValue
    $LpDeadline = (Get-Date).AddSeconds($LpTimeoutSeconds)
    while ((Get-Date) -lt $LpDeadline) {
        foreach ($LpProc in @(Get-Process Pathleap.UI -ErrorAction SilentlyContinue)) {
            $LpElevated = [LpLaunchToken]::Elevation($LpProc.Id)
            if ($LpElevated -eq 1 -and $LpElevatedPid -eq 0) {
                $LpElevatedPid = $LpProc.Id
            }
        }

        if ($LpElevatedPid -ne 0) {
            $LpLive = @([LpLaunchWatch.LpWindowWatch]::Reports() | Where-Object {
                    $_.Pid -eq $LpElevatedPid -and $_.PaintedSamples -gt 0
                })
            if ($LpLive.Count -gt 0 -and $LpPaintedAt -eq [datetime]::MinValue) {
                $LpPaintedAt = Get-Date
            }
        }

        if ($LpPaintedAt -ne [datetime]::MinValue -and ((Get-Date) - $LpPaintedAt).TotalMilliseconds -ge $LpTailMs) {
            break
        }

        Start-Sleep -Milliseconds 100
    }

    [LpLaunchWatch.LpWindowWatch]::Stop()
    $LpSamplesTaken = [LpLaunchWatch.LpWindowWatch]::SampleCount
    $LpWindowMs = [LpLaunchWatch.LpWindowWatch]::ElapsedMs
    $LpRecords = @([LpLaunchWatch.LpWindowWatch]::Reports())

    $LpProcSamples = @()
    if (Test-Path -LiteralPath $LpSampleFile) {
        $LpProcSamples = @(Get-Content -LiteralPath $LpSampleFile | ForEach-Object {
                $LpParts = $_ -split "`t"
                [pscustomobject]@{ Pid = [int]$LpParts[0]; CommandLine = $LpParts[1] }
            })
    }

    if ($LpElevatedPid -eq 0) {
        $LpElevatedHint = $LpProcSamples | Where-Object { $_.CommandLine -like '*--elevated-launch*' } | Select-Object -First 1
        if ($null -ne $LpElevatedHint) { $LpElevatedPid = $LpElevatedHint.Pid }
    }
    if ($LpElevatedPid -eq 0) {
        $LpKnownPids = @($LpRecords | Where-Object { $_.Exe -like '*Pathleap.UI.exe' } | Select-Object -ExpandProperty Pid -Unique)
        foreach ($LpPid in $LpKnownPids) {
            if ([LpLaunchToken]::Elevation([int]$LpPid) -eq 1) { $LpElevatedPid = [int]$LpPid }
        }
    }

    $LpMediumPids = @($LpProcSamples | Where-Object { $_.Pid -ne $LpElevatedPid } | Select-Object -ExpandProperty Pid)
    if ($LpMediumPids.Count -gt 0) { $LpMediumPid = $LpMediumPids[0] }

    $LpKnownProcessPids = @($LpProcSamples | Select-Object -ExpandProperty Pid)
    if ($LpElevatedPid -ne 0) { $LpKnownProcessPids = @($LpKnownProcessPids + $LpElevatedPid | Select-Object -Unique) }
    $LpPathleapRecords = @($LpRecords | Where-Object {
            $_.Exe -like '*Pathleap.UI.exe' -or $LpKnownProcessPids -contains [int]$_.Pid
        })
    $LpNonElevatedPathleap = @($LpPathleapRecords | Where-Object { $_.Pid -ne $LpElevatedPid })
    $LpElevatedRecords = @($LpPathleapRecords | Where-Object { $_.Pid -eq $LpElevatedPid })
    $LpElevatedPainted = @($LpElevatedRecords | Where-Object { $_.PaintedSamples -gt 0 })
    $LpPathleapPainted = @($LpPathleapRecords | Where-Object { $_.PaintedSamples -gt 0 })

    $LpConsoleClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')
    $LpConsoleRecords = @($LpRecords | Where-Object {
            $LpConsoleClasses -contains $_.ClassName -or
            $_.Exe -like '*conhost.exe' -or
            $_.Exe -like '*OpenConsole.exe' -or
            $_.Exe -like '*WindowsTerminal.exe'
        })
    $LpConsoleNew = @($LpConsoleRecords | Where-Object { -not $_.Baseline })
    $LpConsoleFlash = @($LpConsoleRecords | Where-Object {
            $_.PaintedSamples -gt 0 -and (-not $_.Baseline -or $_.FirstPaintedMs -gt 100)
        })

    # 归属判定：窗口 owner 的祖先进程链里是否出现本次启动链的进程（中转/提权实例）。
    # 启动链若有控制台，owner 会是 conhost/OpenConsole，其父即 schtasks/Pathleap.UI，能向上追到中转 pid。
    # 外部后台程序（例如其它会话拉起 Windows Terminal）同样会被枚举到，按归属排除，但不能算通过。
    $LpChainPids = @(@($LpMediumPid, $LpElevatedPid) | Where-Object { $_ -ne 0 })
    $LpAttributed = @($LpConsoleFlash | ForEach-Object {
            $LpChain = @(([string]$_.Ancestors) -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
            $LpInChain = @($LpChain | Where-Object { $LpChainPids -contains $_ }).Count -gt 0
            [pscustomobject]@{
                Record   = $_
                InChain  = $LpInChain
                Known    = $LpChain.Count -gt 0
                FgPid    = 0
            }
        })
    $LpConsoleOurs = @($LpAttributed | Where-Object { $_.InChain })
    $LpConsoleUnknown = @($LpAttributed | Where-Object { -not $_.InChain -and -not $_.Known })
    $LpConsoleExternal = @($LpAttributed | Where-Object { -not $_.InChain -and $_.Known })

    $LpMain = $LpElevatedPainted | Select-Object -First 1
    $LpMainFlash = $false
    $LpMainHides = @()
    if ($null -ne $LpMain) {
        $LpMainHides = @(([string]$LpMain.Hides) -split ';' | Where-Object { $_ -ne '' } | ForEach-Object {
                $LpPart = $_ -split ':'
                $LpFgPid = [int]($LpPart[2] -replace '^fg=', '')
                $LpFgChain = @(([string]$LpPart[3]) -split ';' | Where-Object { $_ -ne '' } | ForEach-Object { [int]$_ })
                $LpFgInChain = ($LpFgPid -ne 0) -and (
                    $LpChainPids -contains $LpFgPid -or
                    @($LpFgChain | Where-Object { $LpChainPids -contains $_ }).Count -gt 0)
                # 前台被外部程序拿走 → 主窗口按「失焦即隐藏」设计隐藏，不算启动闪窗；
                # 前台仍是自己/启动链，或根本读不到前台进程 → 视为自身回退。
                [pscustomobject]@{
                    Ms        = [int]$LpPart[0]
                    State     = $LpPart[1]
                    FgPid     = $LpFgPid
                    External  = ($LpFgPid -ne 0) -and (-not $LpFgInChain)
                    Suspicious = ($LpFgPid -eq 0) -or $LpFgInChain
                }
            })

        $LpMainFlash = @($LpMainHides | Where-Object { $_.Suspicious }).Count -gt 0
    }

    $LpMediumDetail = if ($LpMediumPid -ne 0) {
        $LpMediumRecords = @($LpRecords | Where-Object { $_.Pid -eq $LpMediumPid })
        "pid=$LpMediumPid，顶层窗口 $($LpMediumRecords.Count) 个：$((@($LpMediumRecords | ForEach-Object { "$($_.ClassName)/$($_.FinalState)" })) -join ', ')"
    }
    else {
        "未捕获中转 pid；非提权 Pathleap 进程窗口 $($LpNonElevatedPathleap.Count) 个"
    }

    $LpFgNames = @{}
    foreach ($LpRec in $LpRecords) {
        $LpPidKey = [int]$LpRec.Pid
        if (-not $LpFgNames.ContainsKey($LpPidKey) -and $LpRec.Exe -ne '') { $LpFgNames[$LpPidKey] = $LpRec.Exe }
    }

    $LpConsoleOursText = @($LpConsoleOurs | ForEach-Object { "$($_.Record.ClassName)[$($_.Record.Exe)] 祖先进程 $($_.Record.Ancestors)" }) -join ' | '
    $LpConsoleUnknownText = @($LpConsoleUnknown | ForEach-Object { "$($_.Record.ClassName)[$($_.Record.Exe)] pid=$($_.Record.Pid)" }) -join ' | '
    $LpConsoleExternalText = @($LpConsoleExternal | ForEach-Object {
            "$($_.Record.ClassName)[$($_.Record.Exe)] pid=$($_.Record.Pid) 祖先进程 $($_.Record.Ancestors)"
        }) -join ' | '
    $LpMainHideText = @($LpMainHides | ForEach-Object {
            $LpFgLabel = if ($_.FgPid -eq 0) { '读不到前台' } elseif ($LpFgNames.ContainsKey($_.FgPid)) { $LpFgNames[$_.FgPid] } else { 'pid=' + $_.FgPid }
            "{0}ms {1}（前台 {2} {3}）" -f $_.Ms, $_.State, $_.FgPid, $LpFgLabel
        }) -join '；'

    Add-LpCheck -LpName '中转进程没有创建任何顶层窗口' -LpPassed ($LpNonElevatedPathleap.Count -eq 0) -LpDetail $LpMediumDetail
    Add-LpCheck -LpName '启动链没有控制台窗口变为可见' -LpPassed ($LpConsoleOurs.Count -eq 0 -and $LpConsoleUnknown.Count -eq 0) -LpDetail ("启动链内的控制台窗口 {0} 个{1}；无法归属 {2} 个{3}；外部程序本次新增并变为可见 {4} 个{5}；本次新增控制台类窗口共 {6} 个" -f $LpConsoleOurs.Count, ($(if ($LpConsoleOursText -ne '') { "：$LpConsoleOursText" } else { '' })), $LpConsoleUnknown.Count, ($(if ($LpConsoleUnknownText -ne '') { "：$LpConsoleUnknownText" } else { '' })), $LpConsoleExternal.Count, ($(if ($LpConsoleExternalText -ne '') { "（不计入本项，按外部干扰记录）：$LpConsoleExternalText" } else { '' })), $LpConsoleNew.Count)
    Add-LpCheck -LpName '提权实例只有主窗口这一扇已绘制窗口' -LpPassed ($LpElevatedPainted.Count -eq 1) -LpDetail ("已绘制 {0} 个：{1}" -f $LpElevatedPainted.Count, ((@($LpElevatedPainted | ForEach-Object { "$($_.ClassName)'$($_.Title)' $($_.Rect)" })) -join ' | '))
    Add-LpCheck -LpName '主窗口首次绘制后未再隐藏或被遮蔽' -LpPassed ($null -ne $LpMain -and -not $LpMainFlash) -LpDetail ($(if ($null -ne $LpMain) { "首次绘制 {0}ms；回退 {1} 次{2}；状态序列 {3}" -f $LpMain.FirstPaintedMs, $LpMainHides.Count, ($(if ($LpMainHideText -ne '') { "（$LpMainHideText）" } else { '' })), $LpMain.Timeline } else { '未出现已绘制窗口' }))
    Add-LpCheck -LpName '不存在第二个已绘制的 Pathleap 窗口' -LpPassed ($LpPathleapPainted.Count -eq 1) -LpDetail ("已绘制 Pathleap 窗口 {0} 个" -f $LpPathleapPainted.Count)
    Add-LpCheck -LpName '已绘制窗口均为非零尺寸' -LpPassed (@($LpPathleapPainted | Where-Object { $_.FirstPaintedRect -match ',0x0$' }).Count -eq 0) -LpDetail ((@($LpPathleapPainted | ForEach-Object { $_.FirstPaintedRect })) -join ', ')
    Add-LpCheck -LpName '主窗口首次绘制后未改变几何' -LpPassed ($null -ne $LpMain -and $LpMain.RectChangesPainted -eq 0) -LpDetail ($(if ($null -ne $LpMain) { "几何变化 {0} 次；首绘 {1}；最终 {2}；DPI={3}；DIP={4}；口径={5}" -f $LpMain.RectChangesPainted, $LpMain.FirstPaintedRect, $LpMain.Rect, $LpMain.Dpi, $LpMain.RectDip, $LpMain.RectSource } else { '无主窗口' }))
    Add-LpCheck -LpName '主窗口类名与标题可核对' -LpPassed ($null -ne $LpMain -and $LpMain.ClassName -eq 'WinUIDesktopWin32WindowClass' -and $LpMain.Title -like '*Pathleap*') -LpDetail ($(if ($null -ne $LpMain) { "class=$($LpMain.ClassName) title='$($LpMain.Title)' 首绘标题='$($LpMain.PaintTitle)'" } else { '无主窗口' }))

    [pscustomobject]@{
        GeneratedAt   = (Get-Date).ToString('o')
        Exe           = $LpExe
        Shortcut      = $LpShortcut
        LaunchAt      = $LpLaunchAt.ToString('o')
        Samples       = $LpSamplesTaken
        WindowMs      = $LpWindowMs
        SampleHz      = if ($LpWindowMs -gt 0) { [Math]::Round($LpSamplesTaken * 1000.0 / $LpWindowMs, 1) } else { 0 }
        MediumPid     = $LpMediumPid
        ElevatedPid   = $LpElevatedPid
        ConsoleOurs   = $LpConsoleOurs.Count
        ConsoleUnknown = $LpConsoleUnknown.Count
        ConsoleExternal = $LpConsoleExternal.Count
        ConsoleFlash  = $LpConsoleOurs.Count
        MainHides     = $LpMainHides.Count
        MainHideExternal = @($LpMainHides | Where-Object { $_.External }).Count
        Records       = $LpRecords
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $LpEvidence -Encoding utf8

    Write-Host "采样: $LpSamplesTaken 轮 / $LpWindowMs ms（约 $(if ($LpWindowMs -gt 0) { [Math]::Round($LpSamplesTaken * 1000.0 / $LpWindowMs, 1) } else { 0 }) 轮/秒）"
    Write-Host "中转 pid=$LpMediumPid；提权 pid=$LpElevatedPid"
    Write-Host "证据: $LpEvidence"
}
finally {
    if ($LpProcessJob -isnot [bool] -and $null -ne $LpProcessJob) {
        Stop-Job -Job $LpProcessJob -ErrorAction SilentlyContinue
        Remove-Job -Job $LpProcessJob -Force -ErrorAction SilentlyContinue
    }

    if ($LpSampler) {
        try { [LpLaunchWatch.LpWindowWatch]::Stop() } catch { }
    }

    schtasks.exe /End /TN $LpTaskName 2>&1 | Out-Null
    Start-Sleep -Milliseconds 800
    Get-Process Pathleap.UI -ErrorAction SilentlyContinue | ForEach-Object { try { $_.Kill() } catch { } }
    if (Test-Path -LiteralPath $LpShortcut) { Remove-Item -LiteralPath $LpShortcut -Force }
}

$LpFailed = @($LpResults | Where-Object { -not $_.Passed })
foreach ($LpResult in $LpResults) {
    $LpTag = if ($LpResult.Passed) { 'PASS' } else { 'FAIL' }
    Write-Host ("[{0}] {1}  {2}" -f $LpTag, $LpResult.Name, $LpResult.Detail) -ForegroundColor $(if ($LpResult.Passed) { 'Green' } else { 'Red' })
}
if ($LpFailed.Count -gt 0) { throw "启动可见性验证未通过：$($LpFailed.Count)/$($LpResults.Count)" }
Write-Host "启动可见性验证通过：$($LpResults.Count)/$($LpResults.Count)" -ForegroundColor Green
