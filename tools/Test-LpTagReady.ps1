#Requires -Version 7.0
<#
.SYNOPSIS
  tag 发布前后的强制校验：确保 tag 打在干净、与远端一致的 HEAD 上，并在推送后回读远端指向。
.DESCRIPTION
  打 tag 前（-LpPhase pre）：
    1. tag 名符合版本规则，且与 Directory.Build.props 的 PathleapVersion 一致；
    2. 工作区干净（含未跟踪文件）；
    3. 本地 HEAD 与 origin/main 一致；
    4. tag 在本地与远端都不存在。
  打 tag 并推送后（-LpPhase post）：
    1. 本地 tag 解引用后等于当前 HEAD；
    2. 远端 tag 解引用后等于当前 HEAD；
    3. 工作区干净、HEAD 与 origin/main 一致。
.EXAMPLE
  pwsh -File tools\Test-LpTagReady.ps1 -LpPhase pre -LpTag v1.1.4
.EXAMPLE
  pwsh -File tools\Test-LpTagReady.ps1 -LpPhase post -LpTag v1.1.4
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('pre', 'post')]
    [string]$LpPhase,

    [Parameter(Mandatory)]
    [string]$LpTag
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LpRepoRoot = Split-Path -Parent $PSScriptRoot
$LpFailures = New-Object System.Collections.Generic.List[string]

function Add-LpResult {
    param([bool]$LpPass, [string]$LpMessage)

    if ($LpPass) {
        Write-Host "[PASS] $LpMessage" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $LpMessage" -ForegroundColor Red
        $LpFailures.Add($LpMessage)
    }
}

function Invoke-LpGit {
    param([string[]]$LpGitArgs)

    $LpOutput = & git -C $LpRepoRoot @LpGitArgs 2>&1
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = ($LpOutput | Out-String).Trim() }
}

if ($LpTag -notmatch '^v\d+\.\d+\.\d+(-alpha\d+)?$') {
    Add-LpResult $false "tag 名不符合规则: $LpTag"
}
else {
    Add-LpResult $true "tag 名符合版本规则: $LpTag"
}

$LpVersion = $LpTag.Substring(1)
$LpProps = Get-Content -LiteralPath (Join-Path $LpRepoRoot 'Directory.Build.props') -Raw
$LpVersionMatch = [regex]::Match($LpProps, '<PathleapVersion>\s*(?<v>[^<]+?)\s*</PathleapVersion>')
if (-not $LpVersionMatch.Success) {
    Add-LpResult $false 'Directory.Build.props 缺少 PathleapVersion'
}
else {
    Add-LpResult ($LpVersionMatch.Groups['v'].Value -eq $LpVersion) "PathleapVersion 与 tag 一致（$LpVersion）"
}

$LpStatus = Invoke-LpGit @('status', '--porcelain')
Add-LpResult ([string]::IsNullOrWhiteSpace($LpStatus.Output)) '工作区干净（无未提交/未跟踪文件）'

$LpFetch = Invoke-LpGit @('fetch', 'origin', 'main', '--quiet')
if ($LpFetch.ExitCode -ne 0) {
    Add-LpResult $false "git fetch 失败: $($LpFetch.Output)"
}

$LpHead = (Invoke-LpGit @('rev-parse', 'HEAD')).Output
$LpRemote = (Invoke-LpGit @('rev-parse', 'origin/main')).Output
Add-LpResult ($LpHead -eq $LpRemote) "HEAD 与 origin/main 一致（$LpHead）"

if ($LpPhase -eq 'pre') {
    $LpLocalTag = Invoke-LpGit @('rev-parse', '-q', '--verify', "refs/tags/$LpTag")
    Add-LpResult ($LpLocalTag.ExitCode -ne 0) "本地尚不存在 tag: $LpTag"

    $LpRemoteTag = Invoke-LpGit @('ls-remote', '--tags', 'origin', "refs/tags/$LpTag")
    Add-LpResult ([string]::IsNullOrWhiteSpace($LpRemoteTag.Output)) "远端尚不存在 tag: $LpTag"

    if ($LpFailures.Count -eq 0) {
        Write-Host ''
        Write-Host "可以打 tag：git tag $LpTag && git push origin main && git push origin $LpTag" -ForegroundColor Cyan
    }
}
else {
    $LpLocalTag = Invoke-LpGit @('rev-parse', "$LpTag^{commit}")
    Add-LpResult ($LpLocalTag.ExitCode -eq 0 -and $LpLocalTag.Output -eq $LpHead) "本地 tag 指向当前 HEAD（$LpHead）"

    $LpRemoteTag = Invoke-LpGit @('ls-remote', '--tags', 'origin', "refs/tags/$LpTag")
    $LpRemoteLines = @($LpRemoteTag.Output -split "`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $LpPeeled = $LpRemoteLines | Where-Object { $_ -match '\^\{\}$' } | Select-Object -First 1
    $LpRemoteCommit = if ($LpPeeled) {
        ($LpPeeled -split "`t")[0].Trim()
    }
    elseif ($LpRemoteLines.Count -gt 0) {
        ($LpRemoteLines[0] -split "`t")[0].Trim()
    }
    else { '' }

    Add-LpResult ($LpRemoteCommit -eq $LpHead) "远端 tag 回读指向当前 HEAD（$LpRemoteCommit）"
}

if ($LpFailures.Count -gt 0) {
    Write-Host ''
    Write-Host ("tag 校验未通过（{0} 项）：{1}" -f $LpFailures.Count, ($LpFailures -join '；')) -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host "tag 校验通过（$LpPhase）: $LpTag" -ForegroundColor Green
exit 0
