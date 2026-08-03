[CmdletBinding()]
param(
    [string]$InstallRoot = (Join-Path $env:LOCALAPPDATA 'CodexProxyGuardian'),
    [switch]$Json,
    [ValidateRange(0, 100)][int]$Tail = 8
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'SilentlyContinue'

function Get-StatusValue {
    param($Object, [string]$Name, $Default)
    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    return $property.Value
}

$resolvedRoot = [System.IO.Path]::GetFullPath($InstallRoot).TrimEnd('\')
$markerPath = Join-Path $resolvedRoot '.cpg-install.json'
$statusPath = Join-Path $resolvedRoot 'status.json'
$marker = if (Test-Path -LiteralPath $markerPath) { Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json } else { $null }
$status = if (Test-Path -LiteralPath $statusPath) { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } else { $null }
$task = if ($null -eq $marker) { $null } else { Get-ScheduledTask -TaskName ([string]$marker.taskName) }
$proxySettings = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
$guardianAlive = $false
$guardianPid = [int](Get-StatusValue $status 'guardianPid' 0)
if ($guardianPid -gt 0) {
    $guardianProcess = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $guardianPid)
    $expectedWatcher = Join-Path $resolvedRoot 'Watch-CodexProxy.ps1'
    $guardianAlive = $null -ne $guardianProcess -and ([string]$guardianProcess.CommandLine).IndexOf($expectedWatcher, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
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
    Mode = Get-StatusValue $status 'mode' $null
    ExternalLaunchPolicy = Get-StatusValue $status 'externalLaunchPolicy' $null
    ExternalLaunchState = Get-StatusValue $status 'externalLaunchState' $null
    GuardianAlive = $guardianAlive
    GuardianState = Get-StatusValue $status 'guardianState' $null
    StartupMode = if ($null -eq $marker) { $null } else { $marker.startupMode }
    ScheduledTaskState = if ($null -eq $task) { $null } else { [string]$task.State }
    ActiveProxy = $activeProxy
    ActiveProxyValid = [bool](Get-StatusValue $status 'activeProxyValid' $false)
    EffectivenessEvidence = Get-StatusValue $status 'effectivenessEvidence' $null
    ProxyTestsPassed = [int](Get-StatusValue $status 'proxyTestSuccessCount' 0)
    ProxyTestsRequired = [int](Get-StatusValue $status 'proxyTestRequiredCount' 0)
    ProxyTestsTotal = [int](Get-StatusValue $status 'proxyTestTargetCount' 0)
    ProxyTestsAttempted = [int](Get-StatusValue $status 'proxyTestAttemptedCount' 0)
    ProxySource = Get-StatusValue $status 'activeSource' $null
    CodexInstalled = Get-StatusValue $status 'codexInstalled' $null
    CodexVersion = Get-StatusValue $status 'codexPackageVersion' $null
    CodexArchitecture = Get-StatusValue $status 'codexPackageArchitecture' $null
    CodexApplicationId = Get-StatusValue $status 'codexApplicationId' $null
    CodexExecutable = Get-StatusValue $status 'codexExecutableName' $null
    CodexResolutionMethod = Get-StatusValue $status 'codexResolutionMethod' $null
    CodexRunning = [bool](Get-StatusValue $status 'codexRunning' $false)
    CodexRootPids = @(Get-StatusValue $status 'codexRootPids' @())
    ProxyArgumentMatch = Get-StatusValue $status 'codexProxyArgumentMatch' $null
    ProxyTrafficObservedRecently = Get-StatusValue $status 'codexProxyConnectionObservedRecently' $null
    LastProxyConnectionUtc = Get-StatusValue $status 'lastProxyConnectionUtc' $null
    RecentRestartCount = [int](Get-StatusValue $status 'recentRestartCount' 0)
    RestartCircuitOpen = [bool](Get-StatusValue $status 'restartCircuitOpen' $false)
    CircuitBreakerUntilUtc = Get-StatusValue $status 'circuitBreakerUntilUtc' $null
    RecoveryLaunchRequired = [bool](Get-StatusValue $status 'recoveryLaunchRequired' $false)
    SystemProxyEnabled = ([int]$proxySettings.ProxyEnable -eq 1)
    SystemProxy = [string]$proxySettings.ProxyServer
    SystemProxyModifiedByGuardian = $false
    LastStatusUtc = Get-StatusValue $status 'updatedUtc' $null
}

if ($Json) { [pscustomobject]$summary | ConvertTo-Json -Depth 6; return }
[pscustomobject]$summary | Format-List

$logsPath = Join-Path $resolvedRoot 'logs'
$log = Get-ChildItem -LiteralPath $logsPath -Filter 'guardian-*.jsonl' -File | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($null -ne $log -and $Tail -gt 0) {
    "`nRecent log entries ($($log.FullName)):`n"
    Get-Content -LiteralPath $log.FullName -Tail $Tail
}
