#Requires -Version 7.0
<#
.SYNOPSIS
  「最近访问首页」验收：用本机真实历史（%LOCALAPPDATA%\Findio\recent.json）
  显示首页，核对倒序、名称/路径与相对时间。
.DESCRIPTION
  历史结论只有空态截图，且当时本机无历史。本脚本不改任何记录、不注入任何按键：
    1. 读 recent.json 作为期望值（它是 UI 记录逻辑的产物，不是脚本伪造的）；
    2. 以 --tray 启动后走 IPC SHOW 显示主窗（等价于点托盘「搜索」/热键），
       UIA 读首页行（名称 + 路径）与右侧时间文本；
    3. 逐行与 recent.json 同序比对，并断言时间戳严格倒序；
    4. 截主窗图 docs/shots/86-home-recent.png。
  首页最多显示 6 行（ShowHome 里 Take(6)），因此只比对前 6 条。
.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpHomeRecent.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo 'src\Findio.UI\bin\x64\Debug\net8.0-windows10.0.22621.0\Findio.UI.exe'
$LpServiceExe = Join-Path $LpRepo 'src\Findio.Service\bin\x64\Debug\net8.0-windows\Findio.Service.exe'
$LpConfigPath = Join-Path $env:LOCALAPPDATA 'Findio\config.json'
$LpRecentPath = Join-Path $env:LOCALAPPDATA 'Findio\recent.json'
$LpConfigBackup = Join-Path $env:TEMP ('lp-home-config-{0}.json' -f (Get-Date -Format 'yyyyMMddHHmmss'))
$LpShot = Join-Path $LpRepo 'docs\shots\86-home-recent.png'
$LpWindowTitle = 'Findio'

Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type -AssemblyName System.Drawing

Add-Type -Namespace 'LpHome' -Name 'Native' -MemberDefinition @'
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern System.IntPtr GetForegroundWindow();
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT rect);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(System.IntPtr v);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@
[void][LpHome.Native]::SetProcessDpiAwarenessContext([IntPtr](-4))

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

# 行内第二行显示 FolderPath：浏览器项是 URL 本身，其余取父目录（LpResultRow.FromRecent）。
function Get-LpDisplayPath {
    param($LpEntry)
    $LpPath = [string]$LpEntry.path
    if ($LpPath.StartsWith('http://', [StringComparison]::OrdinalIgnoreCase) -or
        $LpPath.StartsWith('https://', [StringComparison]::OrdinalIgnoreCase)) { return $LpPath }
    return [System.IO.Path]::GetDirectoryName($LpPath)
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

# 时间文本：右侧列，与行名同处一行；实测行名 T=748 时时间 T=770（低 22px），取行名下方 8–40px 的带。
function Get-LpRowTime {
    param($LpWindow, [int]$LpNameTop)

    $LpRect = $LpWindow.Current.BoundingRectangle
    $LpTimes = @(Get-LpTextElements -LpWindow $LpWindow | Where-Object {
            $_.Left -gt ($LpRect.X + $LpRect.Width * 0.6) -and
            $_.Top -ge ($LpNameTop + 8) -and $_.Top -le ($LpNameTop + 40)
        })
    if ($LpTimes.Count -ne 1) { return '' }
    return $LpTimes[0].Name
}

function Get-LpRelativeTime {
    param([DateTimeOffset]$LpTime)
    $LpDelta = [DateTimeOffset]::Now - $LpTime
    if ($LpDelta -lt [TimeSpan]::FromMinutes(1)) { return '刚刚' }
    if ($LpDelta -lt [TimeSpan]::FromHours(1)) { return ('{0} 分钟前' -f $LpDelta.Minutes) }
    if ($LpDelta -lt [TimeSpan]::FromDays(1)) { return ('{0} 小时前' -f $LpDelta.Hours) }
    if ($LpDelta -lt [TimeSpan]::FromDays(30)) { return ('{0} 天前' -f $LpDelta.Days) }
    return $LpTime.ToString('yyyy-MM-dd')
}

function Save-LpWindowShot {
    param([IntPtr]$LpHwnd, [string]$LpPath)

    $LpRect = [LpHome.Native+RECT]::new()
    if (-not [LpHome.Native]::GetWindowRect($LpHwnd, [ref]$LpRect)) { throw 'GetWindowRect 失败' }
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

try {
    if (-not (Test-Path -LiteralPath $LpExe)) { throw "缺少构建产物：$LpExe" }

    # 期望值来自真实历史文件；少于 3 条就无法验证倒序，直接判失败而不是造数据。
    $LpRecent = @(Get-Content -LiteralPath $LpRecentPath -Raw | ConvertFrom-Json)
    Add-LpCheck -LpName '本机存在真实历史（≥3 条）' -LpPassed ($LpRecent.Count -ge 3) `
        -LpDetail ("recent.json 共 {0} 条" -f $LpRecent.Count)
    if ($LpRecent.Count -lt 3) { throw '真实历史不足 3 条，按约定不造假数据' }

    $LpDescending = $true
    for ($LpI = 1; $LpI -lt $LpRecent.Count; $LpI++) {
        if ([DateTimeOffset]$LpRecent[$LpI - 1].accessedAt -le [DateTimeOffset]$LpRecent[$LpI].accessedAt) { $LpDescending = $false }
    }
    Add-LpCheck -LpName 'recent.json 本身按访问时间严格倒序' -LpPassed $LpDescending `
        -LpDetail ((@($LpRecent | ForEach-Object { ([DateTimeOffset]$_.accessedAt).ToString('MM-dd HH:mm:ss') }) -join ' > '))

    Copy-Item -LiteralPath $LpConfigPath -Destination $LpConfigBackup -Force
    $LpConfig = Get-Content -LiteralPath $LpConfigPath -Raw | ConvertFrom-Json
    $LpConfig.onboardingDone = $true
    $LpConfig.autoCheckUpdates = $false
    $LpConfig.logLevel = 'Debug'
    $LpConfig | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $LpConfigPath -Encoding UTF8

    Get-Process Findio.UI, Findio.Service -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    Start-Process -FilePath $LpServiceExe -ArgumentList '--console' | Out-Null
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

    # 真实入口：IPC SHOW 与点托盘「搜索」/热键走同一条显示路径，不注入任何按键。
    Send-LpIpc -LpPayload @{ command = 'SHOW' } | Out-Null
    Start-Sleep -Milliseconds 1400
    $LpWindow = Get-LpWindowElement
    if ($null -eq $LpWindow) { throw '等不到主搜索窗（UIA 找不到标题）' }
    $LpHwnd = [IntPtr]$LpWindow.Current.NativeWindowHandle
    $LpFg = [LpHome.Native]::GetForegroundWindow()
    Add-LpCheck -LpName '显示后前台是本窗（截图无遮挡）' -LpPassed ($LpFg -eq $LpHwnd) `
        -LpDetail ("foreground=0x{0:X} / 本窗=0x{1:X}" -f $LpFg.ToInt64(), $LpHwnd.ToInt64())

    $LpBoxCond = New-Object System.Windows.Automation.PropertyCondition($LpAutomation::NameProperty, '搜索框')
    $LpBox = $LpWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $LpBoxCond)
    $LpBoxValue = ''
    if ($null -ne $LpBox) {
        $LpValuePattern = $null
        if ($LpBox.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$LpValuePattern)) {
            $LpBoxValue = $LpValuePattern.Current.Value
        }
    }
    Add-LpCheck -LpName '搜索框为空（处于首页态，不是结果页）' -LpPassed ($LpBoxValue -eq '') `
        -LpDetail ("UIA 搜索框='{0}'" -f $LpBoxValue)

    $LpGroupCond = New-Object System.Windows.Automation.PropertyCondition($LpAutomation::NameProperty, '最近访问')
    $LpGroup = $LpWindow.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $LpGroupCond)
    Add-LpCheck -LpName '分组标题是「最近访问」' -LpPassed ($null -ne $LpGroup) `
        -LpDetail ("找到分组标签：{0}" -f ($null -ne $LpGroup))

    $LpRows = @(Get-LpRows -LpWindow $LpWindow)
    $LpExpect = @($LpRecent | Select-Object -First 6)
    Add-LpCheck -LpName '首页行数与真实历史一致（最多 6 行）' -LpPassed ($LpRows.Count -eq $LpExpect.Count) `
        -LpDetail ("UIA 行 {0} 行，recent.json 前 {1} 条" -f $LpRows.Count, $LpExpect.Count)

    $LpOrderOk = $LpRows.Count -eq $LpExpect.Count
    $LpDiffs = @()
    $LpTimes = @()
    for ($LpI = 0; $LpI -lt [Math]::Min($LpRows.Count, $LpExpect.Count); $LpI++) {
        $LpWantName = [string]$LpExpect[$LpI].name
        $LpWantPath = Get-LpDisplayPath -LpEntry $LpExpect[$LpI]
        $LpGotTime = Get-LpRowTime -LpWindow $LpWindow -LpNameTop $LpRows[$LpI].NameTop
        $LpWantTime = Get-LpRelativeTime -LpTime ([DateTimeOffset]$LpExpect[$LpI].accessedAt)
        $LpTimes += $LpGotTime
        if ($LpRows[$LpI].Name -ne $LpWantName -or $LpRows[$LpI].Path -ne $LpWantPath -or $LpGotTime -ne $LpWantTime) {
            $LpOrderOk = $false
            $LpDiffs += ("[{0}] UI='{1}' / '{2}' / '{3}' vs JSON='{4}' / '{5}' / '{6}'" -f
                $LpI, $LpRows[$LpI].Name, $LpRows[$LpI].Path, $LpGotTime, $LpWantName, $LpWantPath, $LpWantTime)
        }
    }
    Add-LpCheck -LpName '逐行倒序 + 名称/路径/相对时间与真实历史一致' -LpPassed $LpOrderOk `
        -LpDetail ("时间列：{0}；差异：{1}" -f ($LpTimes -join ' / '), $(if ($LpDiffs.Count -gt 0) { $LpDiffs -join ' | ' } else { '无' }))

    Save-LpWindowShot -LpHwnd $LpHwnd -LpPath $LpShot
    Add-LpCheck -LpName '已截取首页（真实历史）' -LpPassed (Test-Path -LiteralPath $LpShot) `
        -LpDetail ("{0}（{1} 字节）" -f $LpShot, $(if (Test-Path -LiteralPath $LpShot) { (Get-Item -LiteralPath $LpShot).Length } else { 0 }))
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
Write-Host ("最近访问首页：{0}/{1} 通过" -f ($LpChecks.Count - $LpFailed), $LpChecks.Count)
if ($LpFailed -gt 0) { exit 1 }
exit 0
