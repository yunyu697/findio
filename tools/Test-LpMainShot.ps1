#Requires -Version 7.0
<#
.SYNOPSIS
  主搜索窗单发实拍：在当前已切好的缩放下拉起主窗，抓物理像素，核对「宽度=工作区 1/3、顶边=工作区 1/4、水平居中」。
  探针读数与期望缩放不符则直接中止，不做任何拍摄。
.EXAMPLE
  pwsh -NoProfile -File tools\Test-LpMainShot.ps1 -LpScale 2.0 -LpNum 44 -LpTag 200 -LpMode recent
  pwsh -NoProfile -File tools\Test-LpMainShot.ps1 -LpScale 2.0 -LpNum 45 -LpTag 200 -LpMode results -LpQuery lp
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][double]$LpScale,
    [Parameter(Mandatory)][int]$LpNum,
    [Parameter(Mandatory)][string]$LpTag,
    [ValidateSet('recent', 'results')][string]$LpMode = 'recent',
    [string]$LpQuery = '',
    [ValidateSet('Debug', 'Release')][string]$LpConfiguration = 'Debug'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepo = Split-Path -Parent $PSScriptRoot
$LpExe = Join-Path $LpRepo ("src\Pathleap.UI\bin\x64\{0}\net8.0-windows10.0.22621.0\Pathleap.UI.exe" -f $LpConfiguration)
$LpShotsDir = Join-Path $LpRepo 'docs\shots'
$LpWork = Join-Path $env:TEMP 'pathleap-scaling'
$LpCaptureExe = Join-Path $LpWork 'CaptureLp.exe'
$LpWindowTitle = 'Pathleap · 跃径'
New-Item -ItemType Directory -Force -Path $LpShotsDir | Out-Null
if (-not (Test-Path -LiteralPath $LpCaptureExe)) { throw '缺少抓取助手 CaptureLp.exe，请先运行 Test-LpShotOnce.ps1' }

Add-Type -Namespace 'LpMainNative' -Name 'Win32' -MemberDefinition @'
    public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool EnumWindows(LpMainNative.Win32.EnumProc cb, System.IntPtr lParam);
    [System.Runtime.InteropServices.DllImport("user32.dll")]
    public static extern bool IsWindowVisible(System.IntPtr hWnd);
    [System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    public static extern int GetWindowTextW(System.IntPtr hWnd, System.Text.StringBuilder sb, int n);

    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    // DWMWA_EXTENDED_FRAME_BOUNDS = 9：窗口可见边框的物理像素矩形，用来核对「实际看到的窗宽」。
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(System.IntPtr hWnd, int attr, out RECT rect, int size);
'@

function Find-LpWindowByTitle {
    param([string]$LpTitle)
    $script:LpFoundHwnd = [IntPtr]::Zero
    $LpProc = [LpMainNative.Win32+EnumProc]{
        param($LpH, $LpL)
        if (-not [LpMainNative.Win32]::IsWindowVisible($LpH)) { return $true }
        $LpSb = New-Object System.Text.StringBuilder 512
        [void][LpMainNative.Win32]::GetWindowTextW($LpH, $LpSb, $LpSb.Capacity)
        if ($LpSb.ToString() -eq $LpTitle) { $script:LpFoundHwnd = $LpH; return $false }
        return $true
    }
    [LpMainNative.Win32]::EnumWindows($LpProc, [IntPtr]::Zero) | Out-Null
    return $script:LpFoundHwnd
}

# ---------- 探针闸门：缩放 + 工作区 ----------
$LpFile = Join-Path $LpWork ("probe-main-{0}.json" -f (Get-Date -Format 'HHmmssfff'))
& $LpExe "--layout-probe=$LpFile" | Out-Null
$LpJson = Get-Content -LiteralPath $LpFile -Raw | ConvertFrom-Json
Remove-Item -LiteralPath $LpFile -Force
$LpProbed = [double]$LpJson.realScale
Write-Host ("探针 realScale={0}，期望 {1}" -f $LpProbed, $LpScale)
if ([Math]::Abs($LpProbed - $LpScale) -gt 0.02) {
    throw ("当前缩放 {0} 与期望 {1} 不符，未拍摄" -f $LpProbed, $LpScale)
}
$LpWorkRect = $LpJson.realWork
# 与 MainWindowLayout.Compute 同一套取整：宽度直接对物理像素取整，X 用整数除法保持左右留白对称。
$LpExpectWidth = [int][Math]::Round($LpWorkRect.width * 1.0 / 3.0)
$LpExpectTop = [int][Math]::Round($LpWorkRect.top + $LpWorkRect.height * 0.25)
$LpExpectHeight = [int][Math]::Round(436 * $LpScale)
$LpExpectLeft = [int]$LpWorkRect.left + [int][Math]::Floor(($LpWorkRect.width - $LpExpectWidth) / 2.0)

# ---------- 拉主窗 → 抓 → 核对 → 杀 ----------
Get-Process | Where-Object { $_.ProcessName -eq 'Pathleap.UI' } | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 600
$LpArgs = @("--screen=$LpMode")
if (-not [string]::IsNullOrWhiteSpace($LpQuery)) { $LpArgs += "--query=$LpQuery" }
$LpProc = Start-Process -FilePath $LpExe -ArgumentList $LpArgs -PassThru
$LpHwnd = [IntPtr]::Zero
$LpDeadline = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $LpDeadline) {
    $LpHwnd = Find-LpWindowByTitle -LpTitle $LpWindowTitle
    if ($LpHwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 400
}
if ($LpHwnd -eq [IntPtr]::Zero) {
    Get-Process -Id $LpProc.Id -ErrorAction SilentlyContinue | Stop-Process -Force
    throw '等不到主搜索窗'
}
Start-Sleep -Milliseconds 2000

$LpShot = Join-Path $LpShotsDir ("{0}-main-scale{1}-{2}.png" -f $LpNum, $LpTag, $LpMode)
$LpRaw = Join-Path $LpWork ("raw-main-{0}-{1}.png" -f $LpTag, $LpMode)
$LpBounds = & $LpCaptureExe ([int64]$LpHwnd) $LpRaw
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $LpRaw)) { throw ("抓取失败 exit={0}" -f $LASTEXITCODE) }
$LpParts = $LpBounds.Trim() -split ' '
$LpL = [int]$LpParts[0]; $LpT = [int]$LpParts[1]; $LpW = [int]$LpParts[2]; $LpH = [int]$LpParts[3]

# 可见边框（DWM 扩展边框）物理像素：这是用户实际看到的窗口矩形。
$LpDwm = New-Object LpMainNative.Win32+RECT
$LpDwmOk = ([LpMainNative.Win32]::DwmGetWindowAttribute($LpHwnd, 9, [ref]$LpDwm, 16) -eq 0)
$LpDwmW = if ($LpDwmOk) { $LpDwm.Right - $LpDwm.Left } else { 0 }
$LpDwmH = if ($LpDwmOk) { $LpDwm.Bottom - $LpDwm.Top } else { 0 }

Copy-Item -LiteralPath $LpRaw -Destination $LpShot -Force
Get-Process -Id $LpProc.Id -ErrorAction SilentlyContinue | Stop-Process -Force

$LpWorkW = [int]$LpWorkRect.width
$LpWorkH = [int]$LpWorkRect.height
$LpCenterOffset = ($LpL + $LpW / 2.0) - ($LpWorkRect.left + $LpWorkW / 2.0)
[pscustomobject]@{
    Mode          = $LpMode
    Scale         = $LpProbed
    WindowPx      = ('L={0} T={1} {2}x{3}' -f $LpL, $LpT, $LpW, $LpH)
    DwmFramePx    = if ($LpDwmOk) { ('L={0} T={1} {2}x{3}' -f $LpDwm.Left, $LpDwm.Top, $LpDwmW, $LpDwmH) } else { '不可用' }
    ExpectPx      = ('L={0} T={1} {2}x{3}' -f $LpExpectLeft, $LpExpectTop, $LpExpectWidth, $LpExpectHeight)
    SizeMatch     = ($LpW -eq $LpExpectWidth -and $LpH -eq $LpExpectHeight)
    TopMatch      = ([Math]::Abs($LpT - $LpExpectTop) -le 1)
    CenterOffsetPx = $LpCenterOffset
    DwmWidthVsWork = if ($LpDwmOk) { ('{0}/{1} = {2}（与 1/3 差 {3}px）' -f $LpDwmW, $LpWorkW, [Math]::Round($LpDwmW / $LpWorkW, 5), [Math]::Round($LpDwmW - $LpWorkW / 3.0, 2)) } else { '不可用' }
    WidthVsWork   = ('{0}/{1} = {2}（与 1/3 差 {3}px）' -f $LpW, $LpWorkW, [Math]::Round($LpW / $LpWorkW, 5), [Math]::Round($LpW - $LpWorkW / 3.0, 2))
    TopVsWork     = ('{0}-{1} / {2} = {3}' -f $LpT, $LpWorkRect.top, $LpWorkH, [Math]::Round(($LpT - $LpWorkRect.top) / $LpWorkH, 4))
    Shot          = (Split-Path $LpShot -Leaf)
} | Format-List | Out-String -Width 200 | Write-Host
Write-Host '完成'
