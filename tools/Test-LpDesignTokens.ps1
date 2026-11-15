#Requires -Version 7.0
<#
.SYNOPSIS
  界面尺寸/字号/颜色令牌检查：扫描 XAML 与 C# 里散落的硬编码值，对照 DesignTokens.xaml 报偏差。
.DESCRIPTION
  规则（与 docs/界面设计规范.md 一致）：
  - 引用 {StaticResource Lp*} / {ThemeResource *Brush} 的属性视为合规；
  - 裸数字 0 视为合规（无样式风险）；描边/尺寸里的 1 视为发丝线，合规；
  - 负数视为光学补偿，合规；
  - 数值落在 DesignTokens.xaml 的阶梯内、但没有引用令牌：记为「未 token 化」（warn）；
  - 数值不在阶梯内：记为「偏离阶梯」（error）；
  - 颜色字面量（#RRGGBB / #AARRGGBB / Color.FromArgb）：记为「颜色未走画刷」（error）。
  基线 tools/design-token-baseline.json 冻结当前存量；同一 文件+属性+值 的新增出现会失败。
.PARAMETER LpUpdateBaseline
  重写基线文件（保留已有条目的 reason）。
.PARAMETER LpStrict
  忽略基线，任何 warn/error 都失败（用于后续把存量清零）。
.PARAMETER LpReport
  额外输出 Markdown 报告路径。
.EXAMPLE
  pwsh -File .\tools\Test-LpDesignTokens.ps1
.EXAMPLE
  pwsh -File .\tools\Test-LpDesignTokens.ps1 -LpUpdateBaseline
#>
[CmdletBinding()]
param(
    [string]$LpRoot = '',

    [string]$LpBaseline = '',

    [string]$LpReport = '',

    [switch]$LpUpdateBaseline,

    [switch]$LpStrict
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepoRoot = if ([string]::IsNullOrWhiteSpace($LpRoot)) { Split-Path -Parent $PSScriptRoot } else { $LpRoot }
$LpUiRoot = Join-Path $LpRepoRoot 'src\Pathleap.UI'
$LpTokenFile = Join-Path $LpUiRoot 'DesignTokens.xaml'
if ([string]::IsNullOrWhiteSpace($LpBaseline)) {
    $LpBaseline = Join-Path $PSScriptRoot 'design-token-baseline.json'
}

if (-not (Test-Path -LiteralPath $LpTokenFile)) {
    throw "令牌文件不存在: $LpTokenFile"
}

# ---------- 1. 从令牌文件读取允许值 ----------
$LpTokens = @{}
$LpTokenRaw = Get-Content -LiteralPath $LpTokenFile -Raw
foreach ($LpMatch in [regex]::Matches($LpTokenRaw, '<(?<type>x:Double|CornerRadius|Thickness)\s+x:Key="(?<key>Lp[^"]+)"\s*>(?<value>[^<]+)</')) {
    $LpKey = $LpMatch.Groups['key'].Value
    $LpValue = [double]::Parse($LpMatch.Groups['value'].Value.Trim(), [cultureinfo]::InvariantCulture)
    $LpCategory = switch -Regex ($LpKey) {
        '^LpSpace' { 'Spacing' }
        '^LpText' { 'Typography' }
        '^LpLine' { 'Typography' }
        '^LpRadius' { 'Radius' }
        '^LpStroke' { 'Stroke' }
        '^LpSize' { 'Size' }
        default { 'Other' }
    }

    if (-not $LpTokens.ContainsKey($LpCategory)) {
        $LpTokens[$LpCategory] = New-Object System.Collections.Generic.List[double]
    }

    $LpTokens[$LpCategory].Add($LpValue)
}

$LpAllowed = @{}
foreach ($LpCategory in $LpTokens.Keys) {
    $LpAllowed[$LpCategory] = [System.Collections.Generic.HashSet[double]]::new([double[]]$LpTokens[$LpCategory])
}

# ---------- 2. 扫描规则 ----------
$LpXamlProperties = @{
    'FontSize'        = 'Typography'
    'LineHeight'      = 'Typography'
    'Margin'          = 'Spacing'
    'Padding'         = 'Spacing'
    'RowSpacing'      = 'Spacing'
    'ColumnSpacing'   = 'Spacing'
    'Spacing'         = 'Spacing'
    'CornerRadius'    = 'Radius'
    'BorderThickness' = 'Stroke'
    'Height'          = 'Size'
    'MinHeight'       = 'Size'
    'MaxHeight'       = 'Size'
    'Width'           = 'Size'
    'MinWidth'        = 'Size'
    'MaxWidth'        = 'Size'
}

# 测量 / 性能 / 主题数据文件不参与界面样式扫描（不是控件样式来源）
$LpSkipFiles = @(
    'DesignTokens.xaml',
    'Themes.xaml',
    'Theme\ColorTheme.cs',
    'Platform\LayoutProbe.cs'
)

$LpHits = New-Object System.Collections.Generic.List[object]

function Add-LpHit {
    param([string]$LpFile, [int]$LpLine, [string]$LpProperty, [string]$LpValue, [string]$LpCategory, [string]$LpSeverity, [string]$LpSnippet)

    $LpHits.Add([pscustomobject]@{
            File     = $LpFile
            Line     = $LpLine
            Property = $LpProperty
            Value    = $LpValue
            Category = $LpCategory
            Severity = $LpSeverity
            Snippet  = $LpSnippet.Trim()
        })
}

function Test-LpNumericExempt {
    param([double]$LpNumber, [string]$LpCategory)

    if ($LpNumber -eq 0) { return $true }
    if ($LpNumber -lt 0) { return $true }
    # 发丝线：1 DIP 的描边、分隔线与微调，不做令牌化
    if ($LpNumber -eq 1) { return $true }
    return $false
}

function Test-LpTokenized {
    param([string]$LpValue)

    return $LpValue -match '^\{(StaticResource|ThemeResource)\s'
}

function Add-LpNumericHits {
    param([string]$LpFile, [int]$LpLine, [string]$LpProperty, [string]$LpRawValue, [string]$LpCategory, [string]$LpSnippet)

    foreach ($LpPart in ($LpRawValue -split ',')) {
        $LpText = $LpPart.Trim()
        if ([string]::IsNullOrWhiteSpace($LpText)) { continue }
        if ($LpText -notmatch '^-?\d+(\.\d+)?$') { continue }

        $LpNumber = [double]::Parse($LpText, [cultureinfo]::InvariantCulture)
        if (Test-LpNumericExempt -LpNumber $LpNumber -LpCategory $LpCategory) { continue }

        $LpSeverity = if ($LpAllowed.ContainsKey($LpCategory) -and $LpAllowed[$LpCategory].Contains($LpNumber)) { 'warn' } else { 'error' }
        Add-LpHit -LpFile $LpFile -LpLine $LpLine -LpProperty $LpProperty -LpValue $LpRawValue -LpCategory $LpCategory -LpSeverity $LpSeverity -LpSnippet $LpSnippet
    }
}

# ---------- 3. XAML 扫描 ----------
$LpXamlFiles = Get-ChildItem -LiteralPath $LpUiRoot -Recurse -Filter *.xaml -File |
    Where-Object { $_.FullName -notmatch '\\obj\\|\\bin\\' }

foreach ($LpFile in $LpXamlFiles) {
    $LpRelative = [System.IO.Path]::GetRelativePath($LpUiRoot, $LpFile.FullName)
    if ($LpSkipFiles | Where-Object { $LpRelative -like "*$_" }) { continue }

    $LpLines = Get-Content -LiteralPath $LpFile.FullName
    for ($LpIndex = 0; $LpIndex -lt $LpLines.Count; $LpIndex++) {
        $LpLineText = $LpLines[$LpIndex]
        if ($LpLineText -match '^\s*<!--') { continue }

        # Style Setter：<Setter Property="FontSize" Value="12" />
        foreach ($LpSetter in [regex]::Matches($LpLineText, '<Setter\s+Property="(?<p>[A-Za-z_][\w.]*)"\s+Value="(?<v>[^"]*)"')) {
            $LpSetterProperty = $LpSetter.Groups['p'].Value
            $LpSetterValue = $LpSetter.Groups['v'].Value

            if ($LpSetterValue -match '^#[0-9A-Fa-f]{3,8}$') {
                Add-LpHit -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpSetterProperty -LpValue $LpSetterValue.ToUpperInvariant() -LpCategory 'Color' -LpSeverity 'error' -LpSnippet $LpLineText
                continue
            }

            if (-not $LpXamlProperties.ContainsKey($LpSetterProperty)) { continue }
            if (Test-LpTokenized -LpValue $LpSetterValue) { continue }

            Add-LpNumericHits -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpSetterProperty -LpRawValue $LpSetterValue -LpCategory $LpXamlProperties[$LpSetterProperty] -LpSnippet $LpLineText
        }

        foreach ($LpAttr in [regex]::Matches($LpLineText, '(?<name>[A-Za-z_][\w.]*)="(?<value>[^"]*)"')) {
            $LpName = $LpAttr.Groups['name'].Value
            $LpValue = $LpAttr.Groups['value'].Value

            if ($LpValue -match '^#[0-9A-Fa-f]{3,8}$') {
                Add-LpHit -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpName -LpValue $LpValue.ToUpperInvariant() -LpCategory 'Color' -LpSeverity 'error' -LpSnippet $LpLineText
                continue
            }

            if (-not $LpXamlProperties.ContainsKey($LpName)) { continue }
            if (Test-LpTokenized -LpValue $LpValue) { continue }

            Add-LpNumericHits -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpName -LpRawValue $LpValue -LpCategory $LpXamlProperties[$LpName] -LpSnippet $LpLineText
        }
    }
}

# ---------- 4. C# 扫描 ----------
$LpCsFiles = Get-ChildItem -LiteralPath $LpUiRoot -Recurse -Filter *.cs -File |
    Where-Object { $_.FullName -notmatch '\\obj\\|\\bin\\|\\Perf\\' }

foreach ($LpFile in $LpCsFiles) {
    $LpRelative = [System.IO.Path]::GetRelativePath($LpUiRoot, $LpFile.FullName)
    if ($LpSkipFiles | Where-Object { $LpRelative -like "*$_" }) { continue }

    $LpLines = Get-Content -LiteralPath $LpFile.FullName
    for ($LpIndex = 0; $LpIndex -lt $LpLines.Count; $LpIndex++) {
        $LpLineText = $LpLines[$LpIndex]
        $LpTrimmed = $LpLineText.TrimStart()
        if ($LpTrimmed.StartsWith('//') -or $LpTrimmed.StartsWith('///')) { continue }

        foreach ($LpPattern in @(
                @{ Pattern = '\bFontSize\s*=\s*(?<v>-?\d+(\.\d+)?)'; Property = 'FontSize'; Category = 'Typography' }
                @{ Pattern = '\bnew Thickness\((?<v>[^)]*)\)'; Property = 'Thickness'; Category = 'Spacing' }
                @{ Pattern = '\bnew CornerRadius\((?<v>[^)]*)\)'; Property = 'CornerRadius'; Category = 'Radius' }
                @{ Pattern = '\b(?:Height|MinHeight|MaxHeight|Width|MinWidth|MaxWidth)\s*=\s*(?<v>-?\d+(\.\d+)?)'; Property = 'Size'; Category = 'Size' }
            )) {
            foreach ($LpMatch in [regex]::Matches($LpLineText, $LpPattern.Pattern)) {
                $LpValue = $LpMatch.Groups['v'].Value
                if ($LpPattern.Property -eq 'FontSize' -or $LpPattern.Property -eq 'Size') {
                    $LpNumber = [double]::Parse($LpValue, [cultureinfo]::InvariantCulture)
                    if (Test-LpNumericExempt -LpNumber $LpNumber -LpCategory $LpPattern.Category) { continue }
                    $LpSeverity = if ($LpAllowed[$LpPattern.Category].Contains($LpNumber)) { 'warn' } else { 'error' }
                    Add-LpHit -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpPattern.Property -LpValue $LpValue -LpCategory $LpPattern.Category -LpSeverity $LpSeverity -LpSnippet $LpLineText
                }
                else {
                    Add-LpNumericHits -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty $LpPattern.Property -LpRawValue $LpValue -LpCategory $LpPattern.Category -LpSnippet $LpLineText
                }
            }
        }

        foreach ($LpMatch in [regex]::Matches($LpLineText, 'Color\.FromArgb\(\s*\d+\s*,\s*\d+\s*,\s*\d+|"(?<v>#[0-9A-Fa-f]{6,8})"')) {
            $LpColorValue = if ($LpMatch.Groups['v'].Success) { $LpMatch.Groups['v'].Value.ToUpperInvariant() } else { 'Color.FromArgb' }
            Add-LpHit -LpFile $LpRelative -LpLine ($LpIndex + 1) -LpProperty 'Color' -LpValue $LpColorValue -LpCategory 'Color' -LpSeverity 'error' -LpSnippet $LpLineText
        }
    }
}

# ---------- 5. 与基线比较 ----------
$LpBaselineEntries = @()
if ((Test-Path -LiteralPath $LpBaseline) -and -not $LpUpdateBaseline) {
    $LpBaselineEntries = (Get-Content -LiteralPath $LpBaseline -Raw | ConvertFrom-Json).entries
}

$LpBaselineMap = @{}
foreach ($LpEntry in $LpBaselineEntries) {
    $LpKey = '{0}|{1}|{2}' -f $LpEntry.file, $LpEntry.property, $LpEntry.value
    $LpBaselineMap[$LpKey] = $LpEntry
}

$LpGroups = $LpHits | Group-Object { '{0}|{1}|{2}' -f $_.File, $_.Property, $_.Value }
$LpNew = New-Object System.Collections.Generic.List[object]
$LpCovered = New-Object System.Collections.Generic.List[object]

foreach ($LpGroup in $LpGroups) {
    $LpFirst = $LpGroup.Group[0]
    $LpCount = $LpGroup.Count
    $LpEntry = $LpBaselineMap[$LpGroup.Name]

    if ($LpStrict) {
        $LpNew.Add([pscustomobject]@{ File = $LpFirst.File; Property = $LpFirst.Property; Value = $LpFirst.Value; Category = $LpFirst.Category; Severity = $LpFirst.Severity; Count = $LpCount; Baseline = 0 })
        continue
    }

    if ($null -eq $LpEntry) {
        $LpNew.Add([pscustomobject]@{ File = $LpFirst.File; Property = $LpFirst.Property; Value = $LpFirst.Value; Category = $LpFirst.Category; Severity = $LpFirst.Severity; Count = $LpCount; Baseline = 0 })
    }
    elseif ($LpCount -gt [int]$LpEntry.count) {
        $LpNew.Add([pscustomobject]@{ File = $LpFirst.File; Property = $LpFirst.Property; Value = $LpFirst.Value; Category = $LpFirst.Category; Severity = $LpFirst.Severity; Count = $LpCount; Baseline = [int]$LpEntry.count })
    }
    else {
        $LpCovered.Add([pscustomobject]@{ File = $LpFirst.File; Property = $LpFirst.Property; Value = $LpFirst.Value; Category = $LpFirst.Category; Severity = $LpFirst.Severity; Count = $LpCount; Baseline = [int]$LpEntry.count })
    }
}

# ---------- 6. 输出 ----------
$LpByCategory = $LpHits | Group-Object Category | Sort-Object Name
Write-Host ''
Write-Host '==== 界面令牌扫描 ====' -ForegroundColor Cyan
Write-Host ("扫描文件: XAML {0} 个 / C# {1} 个；命中 {2} 处，分组 {3} 组" -f @($LpXamlFiles).Count, @($LpCsFiles).Count, $LpHits.Count, $LpGroups.Count)

foreach ($LpCategory in $LpByCategory) {
    $LpError = @($LpCategory.Group | Where-Object Severity -eq 'error').Count
    $LpWarn = @($LpCategory.Group | Where-Object Severity -eq 'warn').Count
    Write-Host ("  {0,-10} 共 {1,4} 处  error {2,4} / warn {3,4}" -f $LpCategory.Name, $LpCategory.Count, $LpError, $LpWarn)
}

if ($LpNew.Count -gt 0) {
    Write-Host ''
    Write-Host ("新增偏差 {0} 组（基线未覆盖）:" -f $LpNew.Count) -ForegroundColor Yellow
    foreach ($LpItem in ($LpNew | Sort-Object File, Property, Value | Select-Object -First 40)) {
        Write-Host ("  [{0}] {1}: {2}=""{3}""（{4} 处，基线 {5}）" -f $LpItem.Severity, $LpItem.File, $LpItem.Property, $LpItem.Value, $LpItem.Count, $LpItem.Baseline)
    }
}

if ($LpReport) {
    $LpReportLines = New-Object System.Collections.Generic.List[string]
    $LpReportLines.Add('# 界面令牌扫描报告')
    $LpReportLines.Add('')
    $LpReportLines.Add(('生成时间：{0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
    $LpReportLines.Add('')
    $LpReportLines.Add(('命中 {0} 处，分组 {1} 组；新增偏差 {2} 组。' -f $LpHits.Count, $LpGroups.Count, $LpNew.Count))
    $LpReportLines.Add('')
    foreach ($LpCategory in $LpByCategory) {
        $LpReportLines.Add(('## {0}' -f $LpCategory.Name))
        $LpReportLines.Add('')
        $LpReportLines.Add('| 文件 | 属性 | 值 | 级别 | 次数 | 理由 / 处置 |')
        $LpReportLines.Add('| --- | --- | --- | --- | --- | --- |')
        foreach ($LpGroup in ($LpCategory.Group | Group-Object File, Property, Value | Sort-Object Name)) {
            $LpFirst = $LpGroup.Group[0]
            $LpKey = '{0}|{1}|{2}' -f $LpFirst.File, $LpFirst.Property, $LpFirst.Value
            $LpReason = if ($LpBaselineMap.ContainsKey($LpKey)) { $LpBaselineMap[$LpKey].reason } else { '新增偏差，未登记' }
            $LpReportLines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} |' -f $LpFirst.File, $LpFirst.Property, $LpFirst.Value, $LpFirst.Severity, $LpGroup.Count, $LpReason))
        }

        $LpReportLines.Add('')
    }

    $LpReportLines | Set-Content -LiteralPath $LpReport -Encoding utf8
    Write-Host ("报告已写入: {0}" -f $LpReport) -ForegroundColor DarkGray
}

if ($LpUpdateBaseline) {
    $LpEntries = foreach ($LpGroup in $LpGroups) {
        $LpFirst = $LpGroup.Group[0]
        $LpKey = '{0}|{1}|{2}' -f $LpFirst.File, $LpFirst.Property, $LpFirst.Value
        $LpOld = $LpBaselineMap[$LpKey]
        $LpReason = if ($null -ne $LpOld -and $LpOld.reason) {
            $LpOld.reason
        }
        elseif ($LpFirst.Severity -eq 'warn') {
            '值在阶梯内但内联，待改为令牌引用'
        }
        else {
            switch ($LpFirst.Category) {
                'Color' {
                    if ($LpFirst.File -like 'Theme\ThemeService.cs') { '主题服务默认画刷初值，运行期被配色方案覆盖；待改为读取主题令牌' }
                    else { '颜色字面量，应改用 Themes.xaml 画刷' }
                }
                'Typography' { '字号偏离阶梯，待归并' }
                'Spacing' { '间距偏离阶梯，待归并' }
                'Radius' { '圆角偏离阶梯，待归并' }
                'Stroke' { '复合描边（四边不同），待拆为单边描边' }
                default { '结构尺寸（列宽/图标/窗口/分隔线），不属控件高度令牌；新增控件高度须走 LpSize*' }
            }
        }

        [pscustomobject]@{
            file     = $LpFirst.File
            property = $LpFirst.Property
            value    = $LpFirst.Value
            category = $LpFirst.Category
            severity = $LpFirst.Severity
            count    = $LpGroup.Count
            reason   = $LpReason
        }
    }

    $LpDoc = [pscustomobject]@{
        schemaVersion = 1
        note          = '界面令牌基线：冻结首轮存量偏差。新增出现会失败；改完存量后请重跑 -LpUpdateBaseline。理由规则见 docs/界面设计规范.md §5。'
        generatedAt   = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        entries       = @($LpEntries | Sort-Object file, property, value)
    }
    $LpDoc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $LpBaseline -Encoding utf8
    Write-Host ("基线已更新: {0}（{1} 组）" -f $LpBaseline, @($LpEntries).Count) -ForegroundColor Green
    exit 0
}

if ($LpNew.Count -gt 0) {
    Write-Host ''
    Write-Host ("界面令牌检查未通过：{0} 组新增偏差。修复后重试，或按规范评估是否登记为例外。" -f $LpNew.Count) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host '界面令牌检查通过：无新增偏差。' -ForegroundColor Green
exit 0
