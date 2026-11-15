#Requires -Version 7.0
<#
.SYNOPSIS
  校验截图版本台账：文档引用的带版本截图必须与当前版本一致。
.DESCRIPTION
  - 从 Directory.Build.props 读取当前 PathleapVersion；
  - 扫描 README.md 与 docs/*.md 里的 shots/*.png 引用；
  - docs/shots/manifest.json 登记过的截图，version 必须等于当前版本；
  - 当前发布说明（docs/<版本>-发布说明.md）引用的截图必须在台账里登记；
  - 其余历史截图（DPI/几何对比等）不强制登记，避免把历史证据改写成当前证据。
.EXAMPLE
  pwsh -File tools\Test-LpShotVersions.ps1
#>
[CmdletBinding()]
param(
    [string]$LpRoot = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepoRoot = if ([string]::IsNullOrWhiteSpace($LpRoot)) { Split-Path -Parent $PSScriptRoot } else { $LpRoot }
$LpManifestPath = Join-Path $LpRepoRoot 'docs\shots\manifest.json'
if (-not (Test-Path -LiteralPath $LpManifestPath)) { throw "缺少截图台账: $LpManifestPath" }

$LpProps = Get-Content -LiteralPath (Join-Path $LpRepoRoot 'Directory.Build.props') -Raw
$LpVersion = [regex]::Match($LpProps, '<PathleapVersion>\s*(?<v>[^<]+?)\s*</PathleapVersion>').Groups['v'].Value

$LpManifest = (Get-Content -LiteralPath $LpManifestPath -Raw | ConvertFrom-Json).shots
$LpManifestMap = @{}
foreach ($LpShot in $LpManifest) { $LpManifestMap[$LpShot.file] = $LpShot }

$LpDocs = @((Join-Path $LpRepoRoot 'README.md')) + @(Get-ChildItem -LiteralPath (Join-Path $LpRepoRoot 'docs') -Filter *.md -File | Select-Object -ExpandProperty FullName)
$LpReferences = @{}
foreach ($LpDoc in $LpDocs) {
    $LpText = Get-Content -LiteralPath $LpDoc -Raw
    foreach ($LpMatch in [regex]::Matches($LpText, 'shots/(?<file>[0-9A-Za-z._-]+\.png)')) {
        $LpKey = 'shots/' + $LpMatch.Groups['file'].Value
        if (-not $LpReferences.ContainsKey($LpKey)) { $LpReferences[$LpKey] = New-Object System.Collections.Generic.List[string] }
        $LpName = [System.IO.Path]::GetFileName($LpDoc)
        if (-not $LpReferences[$LpKey].Contains($LpName)) { $LpReferences[$LpKey].Add($LpName) }
    }
}

$LpFailures = New-Object System.Collections.Generic.List[string]

foreach ($LpKey in ($LpReferences.Keys | Sort-Object)) {
    if (-not $LpManifestMap.ContainsKey($LpKey)) { continue }

    $LpShot = $LpManifestMap[$LpKey]
    if ($LpShot.version -ne $LpVersion) {
        $LpFailures.Add("$LpKey 显示 $($LpShot.version)，当前版本 $LpVersion（引用: $($LpReferences[$LpKey] -join ', ')）")
        Write-Host "[FAIL] $LpKey 台账版本 $($LpShot.version) ≠ 当前 $LpVersion" -ForegroundColor Red
    }
    else {
        Write-Host "[PASS] $LpKey 与当前版本一致（$LpVersion）" -ForegroundColor Green
    }
}

$LpNotes = Join-Path $LpRepoRoot "docs\$LpVersion-发布说明.md"
if (Test-Path -LiteralPath $LpNotes) {
    $LpText = Get-Content -LiteralPath $LpNotes -Raw
    foreach ($LpMatch in [regex]::Matches($LpText, 'shots/(?<file>[0-9A-Za-z._-]+\.png)')) {
        $LpKey = 'shots/' + $LpMatch.Groups['file'].Value
        if (-not $LpManifestMap.ContainsKey($LpKey)) {
            $LpFailures.Add("当前发布说明引用了未登记截图: $LpKey")
            Write-Host "[FAIL] 当前发布说明引用了未登记截图: $LpKey" -ForegroundColor Red
        }
    }
}
else {
    Write-Host "[WARN] 当前版本没有发布说明: docs/$LpVersion-发布说明.md" -ForegroundColor Yellow
}

foreach ($LpShot in $LpManifest) {
    if (-not (Test-Path -LiteralPath (Join-Path $LpRepoRoot ('docs\' + $LpShot.file)))) {
        $LpFailures.Add("台账里的截图不存在: $($LpShot.file)")
        Write-Host "[FAIL] 台账里的截图不存在: $($LpShot.file)" -ForegroundColor Red
    }
}

if ($LpFailures.Count -gt 0) {
    Write-Host ''
    Write-Host ("截图版本校验未通过（{0} 项）：{1}" -f $LpFailures.Count, ($LpFailures -join '；')) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host ("截图版本校验通过：台账内 {0} 张均与当前版本 {1} 一致" -f @($LpManifest).Count, $LpVersion) -ForegroundColor Green
exit 0
