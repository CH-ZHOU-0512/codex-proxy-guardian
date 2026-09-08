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
$configPath = Join-Path $resolvedRoot 'config.json'
$updateStatusPath = Join-Path $resolvedRoot 'update-status.json'
$marker = if (Test-Path -LiteralPath $markerPath) { Get-Content -Raw -LiteralPath $markerPath | ConvertFrom-Json } else { $null }
$status = if (Test-Path -LiteralPath $statusPath) { Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } else { $null }
$config = if (Test-Path -LiteralPath $configPath) { Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json } else { $null }
$updateStatus = if (Test-Path -LiteralPath $updateStatusPath) { Get-Content -Raw -LiteralPath $updateStatusPath | ConvertFrom-Json } else { $null }
$task = if ($null -eq $marker) { $null } else { Get-ScheduledTask -TaskName ([string]$marker.taskName) }
$updateTaskProperty = if ($null -eq $marker) { $null } else { $marker.PSObject.Properties['updateTaskName'] }
$updateTaskName = if ($null -eq $updateTaskProperty) { 'Codex Proxy Guardian Update' } else { [string]$updateTaskProperty.Value }
$updateTask = if ($null -eq $marker) { $null } else { Get-ScheduledTask -TaskName $updateTaskName }
$updateTaskInfo = if ($null -eq $updateTask) { $null } else { Get-ScheduledTaskInfo -TaskName $updateTaskName }
$updateTaskHasRun = $null -ne $updateTaskInfo -and $updateTaskInfo.LastRunTime.Year -ge 2001
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
    Mode = Get-StatusValue $config 'Mode' (Get-StatusValue $status 'mode' $null)
    ActiveMode = Get-StatusValue $status 'mode' $null
    ModeProfile = if ([string](Get-StatusValue $config 'Mode' 'Safe') -eq 'Enforce' -or [bool](Get-StatusValue $config 'ManageExternalCodexLaunches' $false)) { 'Strict (Enforce)' } else { 'Automatic (Safe)' }
    ModeSwitchCommand = '.\Control.ps1 -Action SetMode -Mode Auto|Strict'
    AutomaticUpdates = [bool](Get-StatusValue $config 'AutomaticUpdates' $true)
    UpdateChannel = Get-StatusValue $config 'UpdateChannel' 'Stable'
    UpdateTaskState = if ($null -eq $updateTask) { $null } else { [string]$updateTask.State }
    LastUpdateCheck = if ($null -ne $updateStatus) { Get-StatusValue $updateStatus 'time' $null } elseif ($updateTaskHasRun) { $updateTaskInfo.LastRunTime } else { $null }
    LastUpdateResult = if ($null -ne $updateStatus) { Get-StatusValue $updateStatus 'event' $null } elseif ($updateTaskHasRun) { $updateTaskInfo.LastTaskResult } else { 'NeverRun' }
    LastUpdateNetworkRoute = if ($null -ne $updateStatus) { Get-StatusValue $updateStatus 'network_route' (Get-StatusValue $updateStatus 'preferred_route' $null) } else { $null }
    GuardianUpdateHeartbeatState = Get-StatusValue $status 'guardianUpdateHeartbeatState' $null
    GuardianUpdateCheckIntervalMinutes = Get-StatusValue $status 'guardianUpdateCheckIntervalMinutes' (Get-StatusValue $config 'GuardianUpdateCheckIntervalMinutes' 60)
    GuardianUpdateResultEvent = Get-StatusValue $status 'guardianUpdateResultEvent' $null
    UpdateTaskLastResult = if ($updateTaskHasRun) { $updateTaskInfo.LastTaskResult } else { $null }
    ExternalLaunchPolicy = Get-StatusValue $status 'externalLaunchPolicy' $null
    ExternalLaunchState = Get-StatusValue $status 'externalLaunchState' $null
    GuardianAlive = $guardianAlive
    GuardianState = Get-StatusValue $status 'guardianState' $null
    StartupMode = if ($null -eq $marker) { $null } else { $marker.startupMode }
    ScheduledTaskState = if ($null -eq $task) { $null } else { [string]$task.State }
    ActiveProxy = $activeProxy
    ActiveProxyValid = [bool](Get-StatusValue $status 'activeProxyValid' $false)
    EffectivenessEvidence = Get-StatusValue $status 'effectivenessEvidence' $null
    ProxyReachability = Get-StatusValue $status 'proxyReachability' $null
    ProxyEndpointReachable = Get-StatusValue $status 'proxyEndpointReachable' $null
    StreamStability = Get-StatusValue $status 'streamStability' $null
    StreamStabilityLimitation = Get-StatusValue $status 'streamStabilityLimitation' $null
    EventListenerState = Get-StatusValue $status 'eventListenerState' 'PeriodicFallback'
    EventListenerComponents = @(Get-StatusValue $status 'eventListenerComponents' @())
    ReconnectSignalsDetected = [int](Get-StatusValue $status 'reconnectSignalsDetected' 0)
    ReconnectBurstCount = [int](Get-StatusValue $status 'reconnectBurstCount' 0)
    LastReconnectSignalUtc = Get-StatusValue $status 'lastReconnectSignalUtc' $null
    ReconnectListenerAction = Get-StatusValue $status 'reconnectListenerAction' 'Monitoring'
    StreamingProxyGuaranteeRequired = [bool](Get-StatusValue $status 'streamingProxyGuaranteeRequired' $true)
    StreamingProxyGuaranteed = [bool](Get-StatusValue $status 'streamingProxyGuaranteed' $false)
    StreamingProxyEvidence = Get-StatusValue $status 'streamingProxyEvidence' $null
    StreamingRepairRequired = [bool](Get-StatusValue $status 'streamingRepairRequired' $false)
    UpstreamSuspected = [bool](Get-StatusValue $status 'upstreamSuspected' $false)
    UpstreamSuspectedSinceUtc = Get-StatusValue $status 'upstreamSuspectedSinceUtc' $null
    UpstreamRecommendedAction = Get-StatusValue $status 'upstreamRecommendedAction' $null
    SafeTrafficEvidenceAccepted = [bool](Get-StatusValue $status 'safeTrafficEvidenceAccepted' $false)
    PostUpdateObservationState = Get-StatusValue $status 'postUpdateObservationState' $null
    PostUpdateObservationActive = [bool](Get-StatusValue $status 'postUpdateObservationActive' $false)
    PostUpdateVersion = Get-StatusValue $status 'postUpdateVersion' $null
    PostUpdateSamples = ('{0}/{1}' -f [int](Get-StatusValue $status 'postUpdateSuccessfulSamples' 0), [int](Get-StatusValue $status 'postUpdateRequiredSamples' 0))
    PostUpdateObservationStartedUtc = Get-StatusValue $status 'postUpdateObservationStartedUtc' $null
    CodexCompatibilityState = Get-StatusValue $status 'codexCompatibilityState' $null
    CodexCompatibilityEvidence = Get-StatusValue $status 'codexCompatibilityEvidence' $null
    CodexCompatibilityFingerprint = Get-StatusValue $status 'codexCompatibilityFingerprint' $null
    CodexCompatibilitySafeHold = [bool](Get-StatusValue $status 'codexCompatibilitySafeHold' $false)
    CompatibilityUpdateCheckState = Get-StatusValue $status 'compatibilityUpdateCheckState' $null
    CompatibilityUpdateRequestedVersion = Get-StatusValue $status 'compatibilityUpdateRequestedVersion' $null
    CompatibilityUpdateResultEvent = Get-StatusValue $status 'compatibilityUpdateResultEvent' $null
    CompatibilityUpdateRetryAfterUtc = Get-StatusValue $status 'compatibilityUpdateRetryAfterUtc' $null
    CompatibilityAutomation = Get-StatusValue $status 'compatibilityAutomation' $null
    ProxyTestsPassed = [int](Get-StatusValue $status 'proxyTestSuccessCount' 0)
    ProxyTestsRequired = [int](Get-StatusValue $status 'proxyTestRequiredCount' 0)
    ProxyTestsTotal = [int](Get-StatusValue $status 'proxyTestTargetCount' 0)
    ProxyTestsAttempted = [int](Get-StatusValue $status 'proxyTestAttemptedCount' 0)
    ProxyCriticalTargetsPassed = [bool](Get-StatusValue $status 'proxyCriticalTargetsPassed' $false)
    ProxyCriticalFailures = @((Get-StatusValue $status 'proxyCriticalFailures' @()))
    ReconnectMeaning = 'CodexStreamRetryNotProofOfGuardianRestartOrEndpointFailure'
    ReconnectEvidenceEvents = @('codex_restart', 'proxy_changed')
    CommonUpstreamSignals = @('TLS EOF', 'WebSocket reset', 'Windows 10054', 'request timeout')
    ProviderNodeManagedByGuardian = $false
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
    RestartApprovalRequired = [bool](Get-StatusValue $status 'restartApprovalRequired' $false)
    RestartNotificationEnabled = [bool](Get-StatusValue $status 'restartNotificationEnabled' $true)
    RestartDeferredUntilUtc = Get-StatusValue $status 'restartDeferredUntilUtc' $null
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
