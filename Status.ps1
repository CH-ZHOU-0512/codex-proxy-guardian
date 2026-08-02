[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$Json,
    [ValidateRange(0, 100)][int]$Tail = 8
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$statusPath = Join-Path $resolvedRoot 'status.json'
$marker = if (Test-Path -LiteralPath $markerPath) { Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json } else { $null }
$status = if (Test-Path -LiteralPath $statusPath) { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } else { $null }
$task = if ($null -eq $marker) { $null } else { Get-ScheduledTask -TaskName ([string]$marker.taskName) }
$proxySettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$guardianAlive = $false
if ($null -ne $status -and $null -ne $status.guardianPid) {
    $guardianAlive = $null -ne (Get-Process -Id ([int]$status.guardianPid))
}

$activeProxy = if ($null -eq $status) { $null } else { [string]$status.activeProxy }
if (-not [string]::IsNullOrWhiteSpace($activeProxy)) {
    $uri = $null
    if ([Uri]::TryCreate($activeProxy, [UriKind]::Absolute, [ref]$uri) -and -not [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
        $activeProxy = $uri.GetLeftPart([UriPartial]::Authority).Replace($uri.UserInfo + '@', '')
    }
}

$summary = [ordered]@{
    Installed = ($null -ne $marker -and [string]$marker.productId -eq 'CodexProxyGuardian')
    Version = if ($null -eq $marker) { $null } else { $marker.version }
    Mode = if ($null -eq $status) { $null } else { $status.mode }
    GuardianAlive = $guardianAlive
    StartupMode = if ($null -eq $marker) { $null } else { $marker.startupMode }
    ScheduledTaskState = if ($null -eq $task) { $null } else { [string]$task.State }
    ActiveProxy = $activeProxy
    ActiveProxyValid = if ($null -eq $status) { $false } else { $status.activeProxyValid }
    ProxySource = if ($null -eq $status) { $null } else { $status.activeSource }
    CodexInstalled = if ($null -eq $status) { $null } else { $status.codexInstalled }
    CodexRunning = if ($null -eq $status) { $false } else { $status.codexRunning }
    CodexRootPids = if ($null -eq $status) { @() } else { @($status.codexRootPids) }
    ProxyArgumentMatch = if ($null -eq $status) { $null } else { $status.codexProxyArgumentMatch }
    SystemProxyEnabled = ([int]$proxySettings.ProxyEnable -eq 1)
    SystemProxy = [string]$proxySettings.ProxyServer
    SystemProxyModifiedByGuardian = $false
    LastStatusUtc = if ($null -eq $status) { $null } else { $status.updatedUtc }
}

if ($Json) { [pscustomobject]$summary | ConvertTo-Json -Depth 6; return }
[pscustomobject]$summary | Format-List

$logsPath = Join-Path $resolvedRoot 'logs'
$log = Get-ChildItem -LiteralPath $logsPath -Filter 'guardian-*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -ne $log -and $Tail -gt 0) {
    "`nRecent log entries ($($log.FullName)):`n"
    Get-Content -LiteralPath $log.FullName -Tail $Tail
}
