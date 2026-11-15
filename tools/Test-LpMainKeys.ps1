#Requires -Version 7.0
<#
.SYNOPSIS
  主搜索窗键盘导航「真实按键」验收：SendInput 真实键入查询词，再真实按 ↑ ↓ PgUp PgDn，
  用 UIA 读当前选中行（选中行独有「↵」徽标 + 行名），与同一查询的结果顺序逐项比对。
.DESCRIPTION
  历史「键盘导航 12/12」是走 `NAV` IPC 直接调 `MoveSelection`，绕过了 KeyDown 路由（焦点、输入法、
  弹层抢键）。本脚本补真实目标：
    1. 查询词用真实按键敲进搜索框（日志「输入变化」+ UIA 搜索框 Value 双证焦点在输入框）；
    2. ↑/↓/PgUp/PgDn 用 SendInput 注入，每次都确认前台是本窗；
    3. 选中行由 UIA 读：结果区唯一的「↵」徽标所在行取最上面的文本即行名；
    4. 期望下标由 IPC `QUERY` 得到的同序结果给出（只用于对照，不驱动选择）。
  结果顺序在两次相同查询之间必须一致；若 UIA 读到的首行名与 IPC 首条不符，脚本直接判失败。
.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpMainKeys.ps1
#>
[CmdletBinding()]
param(
    [string]$LpQuery = '2026'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Findio.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Findio.UI.exe'
$LpServiceExe = Join-Path $LpRepo 'src\Findio.Service\bin\x64\Debug\net8.0-windows\Findio.Service.exe'
$LpLog = Join-Path $env:LOCALAPPDATA ('Findio\logs\ui-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
$LpShots = Join-Path $LpRepo 'docs\shots'
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Findio\config.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-main-keys-config-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$LpWindowTitle = 'Findio'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace 'LpMainKeys' -Name 'Native' -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint pid);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern uint MapVirtualKeyW(uint code, uint mapType);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
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

    // 事件必须在 C# 里构造：PowerShell 直接改 $input.U.ki 只改到副本，SendInput 会成功但什么都没按。
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
[void][LpMainKeys.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))

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

    $LpClient = [System.IO.Pipes.NamedPipeClientStream]::new('.', 'Findio.UI', [System.IO.Pipes.PipeDirection]::InOut)
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

function Send-LpKey {
    param([int]$LpKey)
    $LpSent = [LpMainKeys.Native]::SendKey([uint16]$LpKey)
    if ($LpSent -ne 2) { throw ("SendInput 只送出 {0}/2（vk=0x{1}）" -f $LpSent, $LpKey.ToString('X')) }
}

function Send-LpChord {
    param([int]$LpModifier, [int]$LpKey)
    $LpSent = [LpMainKeys.Native]::SendChord([uint16]$LpModifier, [uint16]$LpKey)
    if ($LpSent -ne 4) { throw ("SendInput 只送出 {0}/4（vk=0x{1}）" -f $LpSent, $LpKey.ToString('X')) }
}

function Get-LpVk {
    param([char]$LpChar)
    if ($LpChar -cmatch '^[a-z]$') { return [int][char]::ToUpperInvariant($LpChar) }
    if ($LpChar -cmatch '^[0-9]$') { return 0x30 + [int][char]::GetNumericValue($LpChar) }
    if ($LpChar -eq '-') { return 0xBD }
    throw ("测试词含未映射字符: '{0}'" -f $LpChar)
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

$LpAutomation = [System.Windows.Automation.AutomationElement]
function Get-LpWindowElement {
    $LpCond = New-Object System.Windows.Automation.PropertyCondition($LpAutomation::NameProperty, $LpWindowTitle)
    return $LpAutomation::RootElement.FindFirst([System.Windows.Automation.TreeScope]::Children, $LpCond)
}

function Get-LpTextElements {
    param($LpWindow)
    $LpCond = New-Object System.Windows.Automation.PropertyCondition(
        $LpAutomation::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
    $LpAll = $LpWindow.FindAll([System.Windows.Automation.TreeScope]::Descendants, $LpCond)
    $LpList = @()
    for ($LpI = 0; $LpI -lt $LpAll.Count; $LpI++) {
        $LpRect = $LpAll[$LpI].Current.BoundingRectangle
        if ($LpRect.IsEmpty) { continue }
        if ([double]::IsInfinity($LpRect.X) -or [double]::IsInfinity($LpRect.Y) -or
            [double]::IsInfinity($LpRect.Width) -or [double]::IsInfinity($LpRect.Height)) { continue }
        if ($LpRect.Width -le 0 -or $LpRect.Height -le 0) { continue }
        $LpList += [pscustomobject]@{
            Name = $LpAll[$LpI].Current.Name
            Left = [int]$LpRect.X
            Top  = [int]$LpRect.Y
            W    = [int]$LpRect.Width
            H    = [int]$LpRect.Height
        }
    }
    return $LpList
}

# 选中行读数：结果区只有一个「↵」徽标，它与行名、路径同处一行；行名 = 该行带内最上面的文本。
function Read-LpSelection {
    param($LpWindow)

    $LpRect = $LpWindow.Current.BoundingRectangle
    $LpTexts = @(Get-LpTextElements -LpWindow $LpWindow)
    $LpBadges = @($LpTexts | Where-Object {
            $_.Name -eq '↵' -and $_.Top -gt ($LpRect.Y + 120) -and $_.Top -lt ($LpRect.Bottom - 60) -and $_.Left -gt ($LpRect.X + $LpRect.Width / 2)
        })
    if ($LpBadges.Count -ne 1) {
        return [pscustomobject]@{ Ok = $false; Name = ''; Path = ''; BadgeCount = $LpBadges.Count }
    }

    # 名称固定在徽标上方约 22px、路径在下方约 18px，各自取窄带，避免跨到相邻行。
    $LpBadge = $LpBadges[0]
    $LpNames = @($LpTexts | Where-Object {
            $_.Left -ge ($LpRect.X + 90) -and $_.Left -le ($LpRect.X + 380) -and
            $_.Top -ge ($LpBadge.Top - 34) -and $_.Top -le ($LpBadge.Top - 6)
        })
    $LpPaths = @($LpTexts | Where-Object {
            $_.Left -ge ($LpRect.X + 90) -and $_.Left -le ($LpRect.X + 380) -and
            $_.Top -ge ($LpBadge.Top + 8) -and $_.Top -le ($LpBadge.Top + 46)
        })
    if ($LpNames.Count -ne 1 -or $LpPaths.Count -ne 1) {
        return [pscustomobject]@{ Ok = $false; Name = ''; Path = ''; BadgeCount = 1 }
    }

    return [pscustomobject]@{ Ok = $true; Name = $LpNames[0].Name; Path = $LpPaths[0].Name; BadgeCount = 1; BadgeTop = $LpBadge.Top }
}

# 结果区行的还原：名称/路径都在 x≈左+110 起，同一行内路径比名称低约 40px，行距约 94px。
# 行内第二行显示的是 FolderPath：非浏览器项取父目录（MainWindow.LpResultRow.FromDto），浏览器项是 URL 本身。
function Get-LpDisplayPath {
    param($LpHit)
    if ($LpHit.isBrowser) { return [string]$LpHit.path }
    return [System.IO.Path]::GetDirectoryName([string]$LpHit.path)
}

function Get-LpRows {
    param($LpWindow)

    $LpRect = $LpWindow.Current.BoundingRectangle
    $LpTexts = @(Get-LpTextElements -LpWindow $LpWindow | Where-Object {
            $_.Left -ge ($LpRect.X + 90) -and $_.Left -le ($LpRect.X + 380) -and
            $_.Top -gt ($LpRect.Y + 120) -and $_.Top -lt ($LpRect.Bottom - 55)
        } | Sort-Object Top)

    $LpRows = @()
    $LpI = 0
    while ($LpI -lt ($LpTexts.Count - 1)) {
        $LpGap = $LpTexts[$LpI + 1].Top - $LpTexts[$LpI].Top
        if ($LpGap -ge 38 -and $LpGap -le 42) {
            $LpRows += [pscustomobject]@{ Name = $LpTexts[$LpI].Name; Path = $LpTexts[$LpI + 1].Name; NameTop = $LpTexts[$LpI].Top }
            $LpI += 2
        }
        else {
            $LpI += 1
        }
    }
    return $LpRows
}

function Save-LpWindowShot {
    param([IntPtr]$LpHwnd, [string]$LpPath)

    $LpRect = [LpMainKeys.Native+RECT]::new()
    if (-not [LpMainKeys.Native]::GetWindowRect($LpHwnd, [ref]$LpRect)) { throw 'GetWindowRect 失败' }
    $LpW = $LpRect.Right - $LpRect.Left
    $LpH = $LpRect.Bottom - $LpRect.Top
    $LpBmp = New-Object System.Drawing.Bitmap $LpW, $LpH
    $LpGfx = [System.Drawing.Graphics]::FromImage($LpBmp)
    try {
        $LpGfx.CopyFromScreen($LpRect.Left, $LpRect.Top, 0, 0, $LpBmp.Size)
        $LpBmp.Save($LpPath, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $LpGfx.Dispose()
        $LpBmp.Dispose()
    }
}

$LpHits = @()
try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force
    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    $LpConfig.onboardingDone = $true
    $LpConfig.autoCheckUpdates = $false
    $LpConfig.logLevel = 'Debug'
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

    Get-Process Findio.UI, Findio.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    $LpService = Start-Process -FilePath $LpServiceExe -ArgumentList '--console' -PassThru
    $LpApp = Start-Process -FilePath $LpExe -ArgumentList '--tray' -PassThru
    $LpDeadline = (Get-Date).AddSeconds(25)
    $LpStatus = $null
    while ((Get-Date) -lt $LpDeadline) {
        try {
            $LpStatus = Send-LpIpc -LpPayload @{ command = 'STATUS' } -LpTimeoutMs 500
            if ($LpStatus.ok) { break }
        }
        catch { }
        Start-Sleep -Milliseconds 300
    }
    if ($null -eq $LpStatus -or -not $LpStatus.ok) { throw 'UI 控制管道 25 秒内未就绪' }

    # 1. 结果顺序只作对照：IPC QUERY 不注入输入，也不移动选择。
    $LpQueryReply = Send-LpIpc -LpPayload @{ command = 'QUERY'; query = $LpQuery } -LpTimeoutMs 15000
    $LpHits = @($LpQueryReply.hits)
    Add-LpCheck -LpName "对照查询 '$LpQuery' 有足够结果" -LpPassed ($LpQueryReply.ok -and $LpHits.Count -ge 8) `
        -LpDetail ("hits={0}，去重路径 {1} 个" -f $LpHits.Count, @($LpHits | ForEach-Object { $_.path } | Sort-Object -Unique).Count)
    $LpDuplicatePaths = @($LpHits | Group-Object path | Where-Object { $_.Count -gt 1 })
    Add-LpCheck -LpName '结果路径互不重复（便于按行读选中项）' -LpPassed ($LpDuplicatePaths.Count -eq 0) `
        -LpDetail ("重复路径 {0} 组" -f $LpDuplicatePaths.Count)

    # 2. 真实入口：托盘实例通过 IPC SHOW 显示主窗（等价于点托盘「搜索」/双击 Ctrl），随后全部按键真实注入。
    Send-LpIpc -LpPayload @{ command = 'SHOW' } | Out-Null
    Start-Sleep -Milliseconds 1200
    $LpWindow = Get-LpWindowElement
    if ($null -eq $LpWindow) { throw '等不到主搜索窗（UIA 找不到标题）' }
    $LpHwnd = [IntPtr]$LpWindow.Current.NativeWindowHandle

    $LpBoxCond = New-Object System.Windows.Automation.PropertyCondition($LpAutomation::NameProperty, '搜索框')
    $LpBox = $LpWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $LpBoxCond)
    if ($null -eq $LpBox) { throw 'UIA 找不到搜索框元素' }

    # 2a. 零注入对照：UIA 还原的可见行必须与 IPC 查询结果同序同值（名称+路径成对来自同一行）。
    $LpRows = @(Get-LpRows -LpWindow $LpWindow)
    $LpControlCount = [Math]::Min($LpRows.Count, [Math]::Min(6, $LpHits.Count))
    $LpControlOk = $LpControlCount -ge 3
    $LpControlDiff = @()
    for ($LpI = 0; $LpI -lt $LpControlCount; $LpI++) {
        $LpWantPath = Get-LpDisplayPath -LpHit $LpHits[$LpI]
        if ($LpRows[$LpI].Name -ne $LpHits[$LpI].name -or $LpRows[$LpI].Path -ne $LpWantPath) {
            $LpControlOk = $false
            $LpControlDiff += ("[{0}] UIA='{1}' / '{2}' vs IPC='{3}' / '{4}'" -f $LpI, $LpRows[$LpI].Name, $LpRows[$LpI].Path, $LpHits[$LpI].name, $LpWantPath)
        }
    }
    Add-LpCheck -LpName '注入前零注入对照：UIA 行与 IPC 结果同序同值' -LpPassed $LpControlOk `
        -LpDetail ("对比 {0} 行；差异：{1}" -f $LpControlCount, $(if ($LpControlDiff.Count -gt 0) { $LpControlDiff -join ' | ' } else { '无' }))
    if (-not $LpControlOk) { throw '零注入对照不成立，按约定停在读数修正，不注入任何按键' }

    # 2b. 激活窗口：UIA 对搜索框 SetFocus；注入前断言前台就是本窗，否则立即退出且不发送任何按键。
    $LpBox.SetFocus()
    Start-Sleep -Milliseconds 500
    $LpFg = [LpMainKeys.Native]::GetForegroundWindow()
    Add-LpCheck -LpName '注入前前台是本窗' -LpPassed ($LpFg -eq $LpHwnd) `
        -LpDetail ("foreground=0x{0:X} / 本窗=0x{1:X}" -f $LpFg.ToInt64(), $LpHwnd.ToInt64())
    if ($LpFg -ne $LpHwnd) { throw '前台不是本窗，按约定退出且未注入任何按键' }

    $LpStartSel = Read-LpSelection -LpWindow $LpWindow
    $LpFirstPath = Get-LpDisplayPath -LpHit $LpHits[0]
    Add-LpCheck -LpName '注入前默认选中第 0 行' -LpPassed ($LpStartSel.Ok -and $LpStartSel.Name -eq $LpHits[0].name -and $LpStartSel.Path -eq $LpFirstPath) `
        -LpDetail ("UIA 选中='{0}' / '{1}'，期望='{2}' / '{3}'" -f $LpStartSel.Name, $LpStartSel.Path, $LpHits[0].name, $LpFirstPath)

    $LpLogSeen = @(Read-LpLogLines).Count

    # 3. 真实键入：Ctrl+A 选中旧文本，再逐字符 SendInput 覆盖成查询词。
    Send-LpChord -LpModifier 0x11 -LpKey 0x41
    Start-Sleep -Milliseconds 150
    foreach ($LpChar in $LpQuery.ToCharArray()) {
        Send-LpKey -LpKey (Get-LpVk -LpChar $LpChar)
        Start-Sleep -Milliseconds 40
    }
    Start-Sleep -Milliseconds 1800

    $LpNewLines = @(Read-LpLogLines | Select-Object -Skip $LpLogSeen)
    $LpInputLogs = @($LpNewLines | Where-Object { $_ -match '输入变化:' })
    $LpApplied = @($LpNewLines | Where-Object { $_ -match ('结果已应用: q=' + [regex]::Escape($LpQuery) + ' hits=(\d+)') })
    $LpTypedHits = if ($LpApplied.Count -gt 0 -and $LpApplied[-1] -match 'hits=(\d+)') { [int]$Matches[1] } else { -1 }
    # 四次 TextChanged 可能被 UI 线程合并成 3 条，最终文本与结果数单独校验。
    Add-LpCheck -LpName '真实键入到达搜索框（日志「输入变化」）' -LpPassed ($LpInputLogs.Count -ge 2) `
        -LpDetail ("输入变化日志 {0} 条，最后一条：{1}" -f $LpInputLogs.Count, $(if ($LpInputLogs.Count -gt 0) { $LpInputLogs[-1].Trim() } else { '（无）' }))
    Add-LpCheck -LpName '键入后按查询词出结果' -LpPassed ($LpTypedHits -eq $LpHits.Count) `
        -LpDetail ("日志 hits={0}，对照 hits={1}" -f $LpTypedHits, $LpHits.Count)

    $LpBoxValue = ''
    $LpValuePattern = $null
    if ($LpBox.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$LpValuePattern)) {
        $LpBoxValue = $LpValuePattern.Current.Value
    }
    Add-LpCheck -LpName '搜索框内容等于注入的查询词' -LpPassed ($LpBoxValue -eq $LpQuery) `
        -LpDetail ("UIA 搜索框='{0}'" -f $LpBoxValue)

    # 4. 导航序列：Down、Down、Up、PgDn、PgUp、Up、Up（上界）、PgDn×4、PgDn（下界）。
    $LpSteps = @(
        @{ Key = 0x28; Name = '↓' },
        @{ Key = 0x28; Name = '↓' },
        @{ Key = 0x26; Name = '↑' },
        @{ Key = 0x22; Name = 'PgDn' },
        @{ Key = 0x21; Name = 'PgUp' },
        @{ Key = 0x26; Name = '↑' },
        @{ Key = 0x26; Name = '↑' },
        @{ Key = 0x22; Name = 'PgDn' },
        @{ Key = 0x22; Name = 'PgDn' },
        @{ Key = 0x22; Name = 'PgDn' },
        @{ Key = 0x22; Name = 'PgDn' },
        @{ Key = 0x22; Name = 'PgDn' }
    )
    # PageStep=6（MainWindow.xaml.cs）：从 0 起 PgDn 依次 +6，末尾按 Clamp(0, hits-1) 收住。
    $LpExpectIdx = @(1, 2, 1, 7, 1, 0, 0, 6, 12, 18, 23, 23)
    $LpLast = $LpHits.Count - 1

    $LpAfterTypeSel = Read-LpSelection -LpWindow $LpWindow
    Add-LpCheck -LpName '键入后默认选中第 0 行' -LpPassed ($LpAfterTypeSel.Ok -and $LpAfterTypeSel.Name -eq $LpHits[0].name -and $LpAfterTypeSel.Path -eq (Get-LpDisplayPath -LpHit $LpHits[0])) `
        -LpDetail ("UIA 选中='{0}' / '{1}'，期望='{2}' / '{3}'" -f $LpAfterTypeSel.Name, $LpAfterTypeSel.Path, $LpHits[0].name, (Get-LpDisplayPath -LpHit $LpHits[0]))

    $LpShotIdx = 0
    for ($LpI = 0; $LpI -lt $LpSteps.Count; $LpI++) {
        $LpStep = $LpSteps[$LpI]
        $LpFgNow = [LpMainKeys.Native]::GetForegroundWindow()
        if ($LpFgNow -ne $LpHwnd) {
            Add-LpCheck -LpName ("第 {0} 次按键（{1}）前前台仍是本窗" -f ($LpI + 1), $LpStep.Name) -LpPassed $false `
                -LpDetail ("foreground=0x{0:X}" -f $LpFgNow.ToInt64())
            break
        }

        Send-LpKey -LpKey $LpStep.Key
        Start-Sleep -Milliseconds 260

        $LpSel = Read-LpSelection -LpWindow $LpWindow
        $LpWantIdx = [Math]::Min([Math]::Max($LpExpectIdx[$LpI], 0), $LpLast)
        $LpWantName = $LpHits[$LpWantIdx].name
        $LpWantPath = Get-LpDisplayPath -LpHit $LpHits[$LpWantIdx]
        Add-LpCheck -LpName ("真实 {0} → 选中下标 {1}" -f $LpStep.Name, $LpWantIdx) `
            -LpPassed ($LpSel.Ok -and $LpSel.Name -eq $LpWantName -and $LpSel.Path -eq $LpWantPath) `
            -LpDetail ("UIA 徽标 {0} 个，选中='{1}' / '{2}'，期望='{3}' / '{4}'" -f $LpSel.BadgeCount, $LpSel.Name, $LpSel.Path, $LpWantName, $LpWantPath)

        # 视觉证据：下标 2（前两行内移动）与下标 23（滚到末尾）各存一张。
        if ($LpI -eq 1 -or $LpI -eq ($LpSteps.Count - 1)) {
            $LpShotIdx++
            $LpShotPath = Join-Path $LpShots ("84-main-keys-nav-{0}.png" -f $LpShotIdx)
            Save-LpWindowShot -LpHwnd $LpHwnd -LpPath $LpShotPath
            Write-Host ("  截图: {0}" -f $LpShotPath)
        }
    }

    $LpFgAfter = [LpMainKeys.Native]::GetForegroundWindow()
    Add-LpCheck -LpName '导航全过程窗口未失焦' -LpPassed ($LpFgAfter -eq $LpHwnd) `
        -LpDetail ("结束时 foreground=0x{0:X}" -f $LpFgAfter.ToInt64())

}
catch {
    Add-LpCheck -LpName '执行过程无异常' -LpPassed $false -LpDetail $_.Exception.Message
}
finally {
    Get-Process Findio.UI, Findio.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 300
    if (Test-Path -LiteralPath $LpConfigBackup) {
        Copy-Item -LiteralPath $LpConfigBackup -Destination $LpConfigPath -Force
        Remove-Item -LiteralPath $LpConfigBackup -Force
    }
}

$LpFailed = @($LpChecks | Where-Object { -not $_.Passed }).Count
Write-Host ''
Write-Host ("主窗键盘导航真实按键：{0}/{1} 通过" -f ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
